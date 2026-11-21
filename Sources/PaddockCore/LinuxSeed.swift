import Foundation

/// The cloud-init seed `paddock build` boots a Linux golden image with once: a NoCloud disk,
/// an ISO labeled `cidata`, that creates the account, installs the guest agent and sets the image
/// up for VMs that nobody watches (see `setupScript`). Clones never see it: once cloud-init has
/// finished, the build turns it off (`disableCloudInit`).
public enum LinuxSeed {
    /// The accounts a Debian cloud image already has, which the workload account can't be.
    public static let systemAccounts: Set<String> = [
        "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp", "proxy",
        "www-data", "backup", "list", "irc", "_apt", "nobody", "systemd-network", "systemd-timesync",
        "dhcpcd", "uuidd", "messagebus", "tcpdump", "systemd-resolve", "sshd", "polkitd",
    ]

    /// Refuses an account name Linux or the image won't take.
    public static func validate(account: String) throws {
        guard account.range(of: "^[a-z][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
            throw PaddockError("'\(account)' isn't a Linux account name: start with a lowercase letter, then use lowercase "
                + "letters, digits, '_' or '-', up to 32 in all")
        }
        guard !systemAccounts.contains(account) else {
            throw PaddockError("'\(account)' is one of the image's own accounts; give the account another name")
        }
    }

    /// The guest's host name: the VM's name, as far as a host name allows.
    public static func hostname(for name: String) -> String {
        let allowed = name.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" }
        let trimmed = String(allowed.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "paddock" : trimmed
    }

    public static func metaData(instanceID: String, hostname: String) -> String {
        "instance-id: \(instanceID)\nlocal-hostname: \(hostname)\n"
    }

    /// The account, uid 1000 as the guest agent expects, with no password and sudo needing none,
    /// and the setup script, run from the seed once cloud-init has made the account, with Rosetta
    /// set up too when the image uses it.
    public static func userData(account: String, fullName: String, rosetta: Bool = false) -> String {
        // JSON strings are YAML strings, so any full name goes in quoted and escaped.
        let gecos = String(decoding: (try? JSONEncoder().encode(fullName)) ?? Data("\"\"".utf8), as: UTF8.self)
        return """
            #cloud-config
            users:
              - name: \(account)
                gecos: \(gecos)
                uid: 1000
                shell: /bin/bash
                lock_passwd: true
                sudo: "ALL=(ALL) NOPASSWD:ALL"
            ssh_pwauth: false
            disable_root: true
            runcmd:
              - [sh, -c, "mkdir -p /run/paddock-seed && mount -o ro LABEL=cidata /run/paddock-seed && sh /run/paddock-seed/paddock-setup.sh \(account)\(rosetta ? " rosetta" : "")"]

            """
    }

    /// Sets the image up, as root, from the seed's folder, with the account's name as $1. Its
    /// output goes to the console, which the VM's console.log keeps, so a failed setup can be
    /// read on the host. The agent starts last: once it answers, everything before it worked.
    public static let setupScript = #"""
        #!/bin/sh
        # paddock's first-boot setup of a Linux golden image, run once by cloud-init from the seed.
        set -eu
        exec >/dev/hvc0 2>&1
        echo "paddock: setting up the image"
        seed=$(dirname "$0")
        account=$1
        rosetta=${2:-}

        # Every clone has a new MAC address, so match any Ethernet interface by name. DHCP identifies
        # the guest by its MAC: systemd-networkd's default, from the machine-id, isn't something
        # macOS's DHCP server records, so the host couldn't find the guest's lease.
        cat > /etc/netplan/50-cloud-init.yaml <<'EOF'
        network:
          version: 2
          ethernets:
            lan:
              match: {name: "en*"}
              dhcp4: true
              dhcp-identifier: mac
        EOF
        chmod 600 /etc/netplan/50-cloud-init.yaml

        # Nothing reaches the guest over the network. Masked, not only disabled: emptying the
        # machine-id when the image is sealed makes a clone's first boot apply presets, which would
        # turn a disabled ssh back on.
        systemctl mask --now ssh.service ssh.socket

        # paddock-net answers time.apple.com at its gateway; on NAT it is Apple's.
        mkdir -p /etc/systemd/timesyncd.conf.d
        printf '[Time]\nNTP=time.apple.com\n' > /etc/systemd/timesyncd.conf.d/paddock.conf

        # The kernel and systemd write to the console too, so console.log shows why a guest never
        # came up.
        printf 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX console=hvc0"\n' > /etc/default/grub.d/90-paddock.cfg
        update-grub

        # The console logs the account in, for paddock run: the account has no password, and only
        # paddock on the host can reach the console.
        mkdir -p /etc/systemd/system/serial-getty@hvc0.service.d
        printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin %s --noclear --keep-baud 115200,57600,38400,9600 - $TERM\n' \
          "$account" > /etc/systemd/system/serial-getty@hvc0.service.d/paddock.conf

        # Every shutdown empties the machine-id, so booting the image itself, as paddock run does,
        # doesn't leave one that every clone would then share.
        cat > /etc/systemd/system/paddock-machine-id.service <<'EOF'
        [Unit]
        Description=Empty the machine-id at shutdown, so each clone of this image makes its own
        Before=shutdown.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/bin/true
        ExecStop=/usr/bin/truncate -s 0 /etc/machine-id

        [Install]
        WantedBy=multi-user.target
        EOF

        # Rosetta, when the image uses it: the host's share mounted at /media/rosetta, registered for
        # x86-64 programs once it's mounted (the F flag opens the interpreter as it registers), and
        # rosettad, its translation cache, which the share's settings on the host point Rosetta at.
        if [ "$rosetta" = rosetta ]; then
          mkdir -p /media/rosetta
          echo 'rosetta /media/rosetta virtiofs ro,nofail 0 0' >> /etc/fstab
          printf '%s\n' ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/media/rosetta/rosetta:CF' \
            > /etc/binfmt.d/rosetta.conf
          mkdir -p /etc/systemd/system/systemd-binfmt.service.d
          printf '[Unit]\nRequiresMountsFor=/media/rosetta\n' > /etc/systemd/system/systemd-binfmt.service.d/rosetta.conf
          cat > /etc/systemd/system/rosettad.service <<'EOF'
        [Unit]
        Description=Rosetta's translation cache
        RequiresMountsFor=/media/rosetta

        [Service]
        ExecStart=/media/rosetta/rosettad daemon /var/cache/rosettad
        CacheDirectory=rosettad
        Restart=on-failure

        [Install]
        WantedBy=multi-user.target
        EOF
          systemctl daemon-reload
          mount /media/rosetta
          systemctl restart systemd-binfmt.service
          systemctl enable --now rosettad.service
        fi

        # The guest agent, answering only the host, over vsock.
        install -D -m 755 "$seed/paddock-guestd" /usr/local/libexec/paddock-guestd
        install -m 644 "$seed/paddock-guestd.service" /etc/systemd/system/paddock-guestd.service
        systemctl daemon-reload
        systemctl enable --now paddock-machine-id.service
        systemctl enable --now paddock-guestd.service
        echo "paddock: the image is set up"
        """#

    /// The last thing a Linux image's build does, as root, after its steps: emptied, the
    /// machine-id is made afresh by each slot's first boot, so slots don't share one; and what
    /// only the build needed goes. The ssh host keys go too: ssh is masked, and every clone would
    /// otherwise carry the same private keys.
    public static let sealScript = """
        set -e
        truncate -s 0 /etc/machine-id
        cloud-init clean --logs
        rm -f /etc/ssh/ssh_host_*
        apt-get clean
        """

    /// Mounts the build's shared folder at `/mnt/share`, read-only.
    public static let mountShare = "mkdir -p /mnt/share && mount -t virtiofs -o ro \(VMConfiguration.linuxShareTag) /mnt/share"

    /// Run once cloud-init has finished its first boot: it has done its one job, and in a clone it
    /// would set the image up again. Turning it off from setup itself would end its run early.
    public static let disableCloudInit = "touch /etc/cloud/cloud-init.disabled"

    /// Writes the seed ISO at `iso` with the agent from `agent`, the folder holding
    /// `paddock-guestd` and `paddock-guestd.service`.
    public static func makeISO(at iso: URL, agent: URL, account: String, fullName: String, name: String,
                               rosetta: Bool = false) throws {
        let folder = iso.deletingLastPathComponent().appendingPathComponent(".seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [
            "meta-data": metaData(instanceID: "paddock-\(UUID().uuidString.lowercased())", hostname: hostname(for: name)),
            "user-data": userData(account: account, fullName: fullName, rosetta: rosetta),
            "paddock-setup.sh": setupScript,
        ]
        for (file, text) in files {
            try Data(text.utf8).write(to: folder.appendingPathComponent(file))
        }
        for file in ["paddock-guestd", "paddock-guestd.service"] {
            try FileManager.default.copyItem(at: agent.appendingPathComponent(file), to: folder.appendingPathComponent(file))
        }
        let hdiutil = Process()
        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = ["makehybrid", "-quiet", "-iso", "-joliet", "-default-volume-name", "cidata", "-o", iso.path, folder.path]
        let errors = Pipe()
        hdiutil.standardError = errors
        try hdiutil.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        hdiutil.waitUntilExit()
        guard hdiutil.terminationStatus == 0 else {
            throw PaddockError("can't make the cloud-init seed: \(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        }
    }
}
