# Golden images

A golden image is the VM every clone starts from. Make one from an image file with
`paddock build`, with no one at the keyboard, or set one up by hand. Linux images are built from
an image file too (see [Linux images](#linux-images)). Windows images are set up outside paddock
for now (see [Windows images](#windows-images)).

## Build one from an image file

With macOS 27 on this Mac and macOS 15, 26 or 27 in the VM, `paddock build` makes a golden image
from an image file, with no one at the keyboard. `paddock init golden.yaml` writes a commented one
to start from, with `--template minimal` (the default: the latest macOS, for your own agents and for
you), `ci` (a pinned macOS plus the Command Line Tools, for `git` and the compilers) or `managed` (a pinned macOS, with a person
making the privacy grants in the image, so paddock never writes the privacy database). Templates are
starting points: any file can take any setting. None accepts Apple's license for you: its license
line ships commented out.
A file with every key looks like this:

```yaml
# golden.yaml
from: { macos: latest }              # or { ipsw: path/to/restore.ipsw }, which pins the version
vm: { cpus: 4, memory: 8, disk: 80 } # in GB; leave any out for install's defaults
account: { name: bench }             # full-name is optional
license: accept                      # optional: see below
grants: recovery                     # or managed, the default
share: installers                    # optional: a host folder, read-only in the guest
steps:
  - name: Install a package from the share
    as: root
    run: installer -pkg "/Volumes/My Shared Files/tool.pkg" -target /
  - name: Hide the Dock
    run: defaults write com.apple.dock autohide -bool true
```

```bash
paddock build golden.yaml        # asks for the account's password
paddock bench golden --runs 3
```

`build` checks the whole file before it starts: every key, so a misspelled one fails with its path
instead of being ignored, the paths it names, the account's name, and that no VM has the image's
name yet. The VM is named after the file unless `name` says otherwise, and paths are relative to
the file's folder. Only then does it ask for the account's password.

It installs macOS into a new VM and boots it once. On macOS 27, macOS creates the account, with
automatic login and Remote Login on, in place of Setup Assistant. paddock logs in over SSH once
with the password, which it keeps only in memory and hands to ssh through a socket only you can
reach. As root, it installs the guest agent from the `guest` folder `scripts/build.sh` stages,
turns off sleep, display sleep, the screen saver and automatic macOS and App Store updates, since
the image's version is pinned and its clones are wiped, and turns Remote Login off for good. From
then on nothing reaches the guest over the network.

On macOS 27, without `license: accept`, macOS still shows its license agreement and a welcome
screen at the next boot. Accepting the license then finishes Setup Assistant, which turns
automatic login off, so turn it on again in System Settings > Users & Groups in that boot. With
`license: accept`, you accept Apple's
[macOS Software License Agreement](https://www.apple.com/legal/sla/) for the image when you build
it. The build reads the guest's screen with Apple's text recognition and clicks Agree on the
license, Agree on its confirmation and Get Started on the welcome screen, so Setup Assistant
finishes on the first boot and macOS turns on automatic login itself. It clicks nothing else: any
other page, such as one asking to share analytics, stops the build and saves a screenshot of it.
It is never a default.

macOS 15 and 26 ignore provisioning, so `build` sets them up offline instead. Right after the
install, it boots the VM in macOS Recovery, opens Terminal as `grant` does, types the password into
`read -rs`, which doesn't show it, then types a script that writes the account, automatic login, the
guest agent from the `guest` folder, and the records that tell Setup Assistant, and the pages it
shows each account at its first login, that they are done. The account is an admin, and gets a
Secure Token and owns the disk at its first login, as one Setup Assistant creates does. On the first
boot the account logs in by itself; paddock checks that the desktop, not Setup Assistant, is in
front, then turns off sleep, display sleep, the screen saver and automatic updates through the guest
agent. Remote Login is never on. Setup Assistant never shows, so neither does Apple's license: a
macOS 15 or 26 image file needs `license: accept`, and you accept the license for the image when you
build it. paddock types the password and the account's full name into the guest, so they can only
use characters on a US keyboard.

With `grants: recovery`, `paddock grant` then writes the Accessibility and Full Disk Access grants
from macOS Recovery (see [What a golden image allows](#what-a-golden-image-allows)). With
`managed`, the default, they are yours to make, once in System Settings in `paddock run`, as in
step 3 below; every clone keeps them.

Last, `build` boots the image once more and runs each step through the guest agent, in order: in
a login `zsh` with `set -e -o pipefail`, as the account, or as root with `as: root`, with the
shared folder at `/Volumes/My Shared Files`. Each step's output is shown as it runs, and the first
step that fails stops the build. Then it checks the image as `serve` does, has the guest shut
itself down, and says what is left for a person, if anything. A build that stops leaves the VM in
place to look at; delete it to build again.

`paddock task`, and most CI jobs, need `git`, which comes with Apple's Command Line Tools. The
`ci` template installs them with two steps: as root, Apple's on-demand install, which asks
`softwareupdate` for the newest Command Line Tools and installs them, about 1 GB from Apple's
update servers; then, as the account, `git --version`, so a build without them fails. Installing
them accepts Apple's Xcode and SDK license for the image. The `minimal` and `managed` templates
have the same steps commented out. Tested with a macOS 27.2.1 guest, which got the Command Line
Tools for Xcode 27.2.

For a macOS 27 guest, the app paddock runs in, such as Terminal, needs Local Network access in
System Settings > Privacy & Security to reach the guest over SSH.

Which macOS `build` sets up, and the versions it has made images from end to end, then granted and
served:

| macOS in the VM | How `build` sets it up | Tested |
| --- | --- | --- |
| 27 | macOS creates the account; paddock finishes over SSH | 27.2.1 |
| 26 | Offline, from Recovery; needs `license: accept` | 26.6.2 |
| 15 | Offline, from Recovery; needs `license: accept` | 15.6.1 |
| 14 | Not by `build`: set it up by hand, below | |

Apple changes first-boot setup between point releases. `build` tries a version that isn't in the
table, and says so; if that build stops, set the image up by hand.

## Set one up by hand

```bash
paddock install golden        # download the latest supported macOS and install it
paddock run golden            # finish Setup Assistant in the window
paddock bench golden --runs 3 # clone, boot headless, time each step, delete the clone
```

While Setup Assistant is open in `paddock run`:

1. Create the user account. With macOS 27 on this Mac and in the VM, paddock can create it on
   the VM's first boot, in place of Setup Assistant, with automatic login and Remote Login on:

   ```bash
   paddock run golden --provision bench   # asks for the account's password on the terminal
   ```

   The license agreement and a welcome screen still appear once; the rest of Setup Assistant
   doesn't. macOS reads this only on the first boot after `paddock install`. paddock refuses
   this Mac's own user name, which provisioning is reported to fail on.
2. Install the guest agent. Boot with the staged `guest` folder shared, then run its installer
   in the guest's Terminal:

   ```bash
   paddock run golden --share .build/out/Products/Release/guest   # on the host
   sudo bash "/Volumes/My Shared Files/install.sh"                # in the guest
   ```

   The installer prints `paddock-guestd is running` when the agent is up, and
   `paddock-session is running` when the session helper is.
3. Give every clone a desktop that stays up and commands that never wait for a prompt. These
   are security settings, so they are yours to make (see
   [What a golden image allows](#what-a-golden-image-allows)):
   - Turn on automatic login for the user in System Settings > Users & Groups.
   - Stop sleep and the display turning off: `sudo pmset -a sleep 0 displaysleep 0`.
   - Set "Start Screen Saver when inactive" to Never in System Settings > Lock Screen. Clones
     keep the screen lock on whatever this image says (see [Limits](limits.md)), so the screen
     saver and sleep, which would set it off, must stay off.
   - Allow `paddock-session` in System Settings > Privacy & Security > Accessibility. macOS asks
     when the installer starts it.
   - Add `/usr/local/libexec/paddock-guestd` in System Settings > Privacy & Security > Full Disk
     Access. Without it, a command that touches Desktop, Documents or Downloads waits for a
     prompt that nobody answers.

   macOS keeps both grants for rebuilt binaries only if they have the same signature:
   `scripts/build.sh` signs both with the code-signing certificate named in
   `PADDOCK_SIGNING_IDENTITY`, `paddock local signing` by default, and ad hoc if there is none,
   in which case every rebuild needs granting again. `serve` checks these settings in the
   first clone it boots and warns about each one that is missing.
4. Shut down from the Apple menu. Closing the window or pressing Ctrl-C also asks the guest to
   shut down; doing it a second time forces the VM off.

## What a golden image allows

A golden image set up as above gives up some of macOS's protections so that its VMs run with
nobody watching. They are the guest's protections, not this Mac's: the VM is the boundary
between a workload and the host, and every VM is wiped when it is released.

| Setting | What it allows |
| --- | --- |
| Automatic login | macOS keeps the account's password in `/etc/kcpassword`, obfuscated but reversible, so anyone with root in the guest or a copy of the image can recover it. It is the same file however automatic login is turned on, and it doesn't work with FileVault on. |
| No screen saver or sleep | Whoever has the screen has the session: paddock's screenshots and input, by design. |
| Accessibility for `paddock-session` | It can read and drive the interface of every app in the session; `axtree` reads only the focused app's. |
| Full Disk Access for `paddock-guestd` | Commands it runs, through `exec`, `task` and `run_command`, can read and change every file in the guest, other apps' data included. |

- Give the golden image's account a password used nowhere else, and sign it in to nothing:
  every workload can read what the image holds.
- The grants are made once, in the golden image, by hand or with `paddock grant`, and SIP stays
  on either way. paddock needs no Screen Recording permission, since it reads the screen on the
  host.
- A grant belongs to a binary's signature, so a workload that replaces `paddock-session` or
  `paddock-guestd` with its own binary doesn't get it. paddock treats both as untrusted anyway.
- `serve` warns about each setting missing from the first clone it boots, with what to
  change. It doesn't change them itself.

`paddock build` adds these while it sets the image up. On macOS 27, during its first boot:

- Remote Login is on from the first boot until the build turns it off, about a minute later,
  for good. paddock uses SSH nowhere else.
- It doesn't check the guest's SSH host key: the guest was created moments earlier on this
  Mac's private network, so there is no earlier key to check against.
- The password goes from your terminal into paddock's memory, to ssh through a socket only you
  can reach, and to sudo in the guest over that SSH connection. It is never written to a file
  on this Mac, put in an environment variable or on a command line. In the guest, once you turn
  on automatic login, it is in `/etc/kcpassword`.

On macOS 15 and 26, in Recovery before its first boot:

- The password goes from your terminal into paddock's memory and, as key presses, into
  `read -rs` in Recovery's Terminal, which doesn't show it. The script typed after it passes it
  to `dscl` and the installed system's Perl as an argument, for a moment, and unsets it once the
  account's password and `/etc/kcpassword` are written. It is never on screen, in the typed
  script, or in a file or on a command line on this Mac.
- paddock writes the account into the image's directory database, and the records that Setup
  Assistant is done, itself. Apple doesn't document either, and a release could change them: if
  the first boot doesn't come up at the desktop, logged in, the build stops.

`paddock grant` writes the two grants from macOS Recovery instead of System Settings:

- It boots the image in Recovery, clicks Options and Continue at the startup screen, which it
  finds by reading the screen, opens Terminal with its shortcut and types one command. That
  command compiles each helper's code requirement from the binary in the image and writes the
  same row into the image's privacy database,
  `/Library/Application Support/com.apple.TCC/TCC.db`, that System Settings writes when you
  allow it. Then it halts the VM.
- It also removes the Full Disk Access that turning on Remote Login gives sshd ("Allow full disk
  access for remote users"). `build` turns Remote Login on for a macOS 27 image's first boot and
  off for good; without this, the grant would stay in the image, and turning Remote Login back on
  would bring back full disk access for whoever logs in remotely.
- SIP stays on in the image and every clone. Scripts that turn SIP off to write grants leave it
  off in every VM they make, where a workload could then grant itself more, such as Screen
  Recording.
- Apple doesn't document that database's format, and a macOS release could change it. paddock
  writes it as macOS 15, 26 and 27 do. If a release changes it, `grant` fails, or `serve` warns
  that a grant is missing. Allowing the two once in System Settings, in the golden image, is the
  supported way.
- Recovery asks for no password, because the VM's disk isn't encrypted with FileVault. Anyone who
  can read and write the image's files on this Mac can change the image anyway.

## MDM and monitoring agents

MDM manages the Macs that run paddock, not its VMs. Enrollment belongs to one device: a golden
image enrolled and then cloned would give every clone the same MDM identity, and unenrolling it
first removes the profiles it installed. So a golden image gets its grants from a person or from
`paddock grant`, not from an MDM privacy profile, and skips Setup Assistant through provisioning
or `build`, not through Automated Device Enrollment.

A monitoring agent that enrolls with its own server, such as osquery or fleetd, does work in
clones, and reports from each VM like any other host. Install it with a build step, and remove the
identity it saves when it enrolls before the image is finished, so that each clone enrolls as a
host of its own rather than all of them as one. Every hand-out is a new, short-lived host, so have
the server expire hosts that stop reporting.

## Linux images

`paddock build` makes a Linux golden image from an image file as well, with no password to type
and on any macOS paddock runs on. It builds Debian's and Ubuntu's arm64 cloud images, tested with
Debian 13 and Ubuntu 26.04 LTS.
A Linux VM has no screen unless its image has a desktop (see [Desktop Linux](#desktop-linux)):
commands, files and `serve`'s warm slots work, and screenshots, input, `show` and `view` refuse a
VM with no screen (see [VM bundle format](commands.md#vm-bundle-format)).
`paddock init debian.yaml --template debian` writes a file to start from and
`--template debian-desktop` one with Xfce; `--template ubuntu` and `--template ubuntu-desktop`
do the same for Ubuntu, with GNOME:

```yaml
# debian.yaml
from: { debian: 13 }                 # or { debian: 13, variant: generic }, { ubuntu: 26.04 },
                                     # { disk: <path> } or { url: <https URL>, sha512: <hash> }
vm: { cpus: 4, memory: 4, disk: 16 } # in GB; these are the defaults
account: { name: paddock }           # full-name is optional
share: installers                    # optional: a host folder, read-only in the guest at /mnt/share
rosetta: true                        # optional: run x86-64 Linux programs through Rosetta
desktop: true                        # optional: stop the build if the image has no working desktop
steps:
  - name: Install git, which paddock task needs
    as: root
    run: apt-get update && apt-get install -y git
```

| `from` | The image | Pinned |
| --- | --- | --- |
| `{ debian: 13 }` | Debian 13's latest genericcloud arm64 build, from cloud.debian.org; its kernel drives only what a cloud VM needs | No: Debian publishes new builds |
| `{ debian: 13, variant: generic }` | Debian 13's latest generic arm64 build, whose full kernel also drives a screen and USB input, for a desktop | No |
| `{ ubuntu: 26.04 }` | Ubuntu 26.04 LTS's latest arm64 server cloud image, a qcow2 disk, from cloud-images.ubuntu.com; its kernel drives a screen and USB input too | No: Ubuntu publishes new builds |
| `{ disk: <path> }` | A file you keep: a `.tar.xz` holding `disk.raw`, as Debian publishes them, a qcow2 disk, as Ubuntu does, or a raw disk | Yes |
| `{ url: <https URL>, sha256: <hash> }`, or `sha512:` | A file to download, a `.tar.xz`, `.raw`, `.qcow2` or `.img` as its URL's name says | Yes, by its hash |

- For `debian` and `ubuntu`, each build fetches the distribution's list of hashes, Debian's
  `SHA512SUMS` or Ubuntu's `SHA256SUMS`, over HTTPS and checks the image against it, downloading
  again only when the cached one no longer matches. Both also sign the list with GPG, and paddock
  doesn't check that signature, so the trust is their HTTPS servers, as it is Apple's for a macOS
  restore image.
- For `url`, the hash is required: a download that doesn't match it is deleted, and the build
  stops. Images are kept in `~/.paddock/cache/linux`, by name for Debian and Ubuntu and by hash
  for a URL.
- paddock reads a qcow2 disk itself, as it makes the VM, into a sparse raw disk, which takes a few
  seconds: Ubuntu 26.04's took 4.4 s. It reads qcow2 versions 2 and 3 with plain or
  zlib-compressed data, as cloud images are. One that needs a backing file, is encrypted, or uses
  an external data file, extended L2 entries or zstd fails with the reason: convert it to a raw
  disk first. A `.img` can be either qcow2 or raw; paddock tells them apart by what the file
  holds.
- Debian's cloud image has no `git`, which `paddock task` needs: install it with a step, as the
  file above does. Without it, `task` stops, saying the guest has no git. Ubuntu's has it.
- `license` and `grants` are for macOS images, and a Linux file with either fails the check. The
  account needs a Linux account name that the image doesn't already have, such as `root` or
  `sshd`. `vm.disk` is at least 4 GB.

`build` then:

1. Makes the VM from the image's disk, grown to `vm.disk`. Debian 13's disk takes about 2.8 GB of
   the golden image's sparse disk, and Ubuntu 26.04's about 2.6 GB.
2. Boots it once with a cloud-init seed, a small disk attached read-only, which creates the
   account, sets the image up as below and installs the guest agent from the `guest` folder's
   `linux` folder. paddock sets the guest's clock from this Mac's, since the image boots at 1970
   until its network time arrives, waits for cloud-init to finish, turns cloud-init off for good
   and has the guest shut down.
3. Boots it again without the seed, so the image must come up on its own, as every clone does.
   It sets the clock, mounts the share and runs each step in a login bash with
   `set -e -o pipefail`, as the account or, with `as: root`, as root.
4. Seals the image: it empties `/etc/machine-id`, so each of `serve`'s slots makes its own at its
   first boot, deletes cloud-init's state and logs and the ssh host keys, cleans apt's cache and
   shuts down.
5. With a display manager enabled, or `desktop: true`, boots the image once more with a screen to
   check its desktop (see [Desktop Linux](#desktop-linux)).

A build that stops leaves the VM in place to look at; delete it to build again. If the guest
agent never answers on the first boot, the build prints the end of the guest's console, which
the VM keeps in `console.log` in its folder.

To change an image by hand, `paddock run debian` boots it with this terminal as its console,
logged in as the account, in place of a window. Ctrl-C and the like go to the guest; Ctrl-] asks
it to shut down and a second Ctrl-] forces it off, as shutting down in the guest also ends `run`.
A serial console can't tell the guest the window's size, so `run` prints the `stty` command that
does. With `--share`, mount the folder in the guest with
`sudo mount -t virtiofs paddock-share /mnt/share`. The image empties its machine-id whenever it
shuts down, so booting it this way doesn't leave one for every clone to share; a VM forced off
keeps the one it had.

Every clone then has:

- The account, with uid 1000 and no password, and sudo that needs none. `exec` runs commands as
  it, so whatever a workload runs can become root in its own VM, which is wiped when it is
  released.
- A network on any Ethernet interface, matched by name since every clone has a new MAC address,
  with DHCP identifying the guest by its MAC so that paddock finds its lease. Its time comes from
  time.apple.com, which paddock-net answers on the userspace network, and `serve` sets each warm
  VM's clock from this Mac's, since a restored guest resumes at the time its state was saved.
- ssh masked: nothing reaches the guest over the network.
- No automatic updates, as in macOS images: apt's `apt-daily` and `apt-daily-upgrade` timers are
  masked at the first boot, so neither the build's steps nor a clone meet apt updating or
  upgrading packages by itself and holding its lock. Update packages in the image's steps.
- The kernel and systemd writing to the guest's console, and the console logging the account in
  without a password. Only paddock on this Mac reaches the console.

### Desktop Linux

A Linux image with a desktop gives its VMs a screen, a keyboard and a pointer, so `screenshot`,
`click`, `type`, `key`, `scroll`, `show`, `view` and MCP's screen tools work as they do for macOS,
and `paddock run` opens it in a window. `axtree` and MCP's `accessibility_tree` read the focused
app's tree through AT-SPI, which needs `at-spi2-core` in the image (see
[Linux guests](guest-agent.md#linux-guests)).

The desktop comes from the image: one you point `from:` at that has one, or one your steps
install. Its kernel must drive a virtio-gpu screen and USB input. Ubuntu's does. Debian's
genericcloud kernel drives neither, so build from its generic variant; the `debian-desktop`
template does, and installs a small Xfce, about 100 MB from Debian, with AT-SPI:

```yaml
from: { debian: 13, variant: generic }
account: { name: paddock }
desktop: true
steps:
  - name: Install Xfce
    as: root
    run: |
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xfce4 xfce4-terminal lightdm lightdm-gtk-greeter xserver-xorg-core \
        xserver-xorg-input-libinput dbus-x11 at-spi2-core
      systemctl set-default graphical.target
```

The `ubuntu-desktop` template does the same with `from: { ubuntu: 26.04 }` and GNOME on GDM:
`ubuntu-desktop-minimal`, `ptyxis`, `gnome-text-editor` and `at-spi2-core`, about 300 MB from
Ubuntu without its recommended extras.

paddock does what only it can, since it makes the account at the first boot:

- After the steps, if a display manager is enabled, it sets it to log the account in
  automatically: LightDM, GDM or SDDM. For another, the build says to do that in a step. It also
  turns off X's screen blanking, since a blank screen screenshots as black, and GNOME's idle
  blanking, lock and suspend, with system defaults in dconf, since the account has no password to
  unlock it with. GNOME without `dconf-cli` gets a note to install it in a step.
- After sealing, it boots the image once more with a screen and USB input, and waits for the
  guest agent to say the desktop is up: the screen's driver is loaded, the keyboard and pointer
  are there, the account has an active, unlocked graphical session, and the desktop has drawn and
  takes input (see [Linux guests](guest-agent.md#linux-guests)). When it is, `config.json` gets
  `"desktop": true`, and the image's VMs get a screen at its display size, 1920x1200, and a USB
  keyboard and pointer.
- When it isn't, the build names the first thing missing, such as "its kernel,
  6.12.117+deb13-cloud-arm64, doesn't drive the screen: it has no virtio-gpu driver", and the image
  stays headless. With `desktop: true` the build stops there instead. Without a display manager
  and without the key, there's no extra boot.
- With the desktop up, it looks for the account's AT-SPI bus, and notes when there's none, since
  `axtree` can't read the desktop's apps without it.

`serve` waits for the desktop before it saves a slot's state, so a restored VM is handed out with
its desktop drawn. Debian's generic kernel and Ubuntu's drive the USB devices, so slots restore
with them; Debian's cloud kernel's saved state doesn't restore with USB devices attached. Measured
with the templates: `debian-desktop` built in 2m 36s to 2m 42s, a slot booted in 4.3 s and saved
0.2 GB of state, and each refill restored in 0.8 to 1.1 s; `ubuntu-desktop` built in 3m 3s, a slot
booted to its desktop in 15 to 16 s and saved 0.3 GB of state, and refills restored in 1.0 to
1.3 s. A GNOME VM left idle for 7 minutes stayed unlocked.

- A desktop other than GNOME that locks itself when idle needs its lock turned off in a step: the
  account has no password, so a locked VM can't be unlocked from inside.
- `cmd` in `key` and MCP's `press_keys` reaches Linux as the Super key, so shortcuts there use
  `ctrl`, as `ctrl+s`.
- Tested with GTK apps under X11, as Xfce's are, and GTK 4 apps under GNOME, which runs on
  Wayland: both publish their trees to AT-SPI on their own. Under X11, frames are screen pixels.
  Under Wayland an app doesn't know where its window is on screen, so every frame's position is
  0, 0 and only its size is right; titles, values and focus are right. For frames with positions
  on Ubuntu, install Xfce and LightDM in place of GNOME, as `debian-desktop` does.
- Qt, Firefox and Chromium publish their trees only when accessibility is turned on (AT-SPI's
  `IsEnabled`), which paddock doesn't do; they haven't been tested.

### Rosetta

With `rosetta: true`, every VM of the image runs x86-64 Linux programs through Rosetta, as macOS
runs Intel apps. The Mac needs Rosetta installed: if it isn't, `build` stops, and `serve`'s slots
stay empty, with the command that installs it, which accepts Apple's license for Rosetta. The image keeps
the setting, since a slot's saved state restores only onto the same devices.

- The VM gets Rosetta's share, mounted in the guest at `/media/rosetta` and registered for x86-64
  programs, and `rosettad`, Rosetta's translation cache, with its files in `/var/cache/rosettad`.
- Rosetta translates a program each time it starts. Measured with small Go programs: 12 ms a
  launch without the cache and about 3 ms once the cache has the program, against 0.4 ms native.
  Running a program also took 2.4 to 5.4 times as long as its arm64 build.
- Steps that run your x86-64 tools put them in the golden image's cache, so every clone starts
  with it. What a handed-out VM adds to the cache goes when the VM is released, and no cache is
  shared between VMs, where one workload could leave translations for another to run.
- A dynamically linked x86-64 program needs its x86-64 libraries in the guest, from the
  distribution's amd64 packages; statically linked programs and containers bring their own. Only
  statically linked ones have been tested, on Debian.

Setup assumes the system Debian and Ubuntu share: netplan with systemd-networkd, the `ssh` unit
and apt. Images of other distributions aren't supported.

## Windows images

paddock runs and serves Windows 11 ARM VMs, but doesn't make their images yet: there's no image
file or `install` for Windows. A Windows golden image is installed and set up outside paddock,
then placed in `~/.paddock/vms` as a bundle (see [VM bundle format](commands.md#vm-bundle-format)).
You bring Microsoft's ISO and the license (see [Limits](limits.md)). Tested on macOS 27, with
Windows 11 24H2 (build 26100) and virtio-win 0.1.302.

The bundle has `disk.img`, `efi-vars` and a `config.json` with `"kind": "windows"`, an empty
hardware model, a generic machine identifier and a display of 1024x768. The image needs:

- A UEFI driver that gives Windows Boot Manager a linear framebuffer, without which the VM doesn't
  boot, since the firmware's virtio-gpu output has none. It goes on the EFI system partition and
  registers itself in `efi-vars`, so the firmware loads it at every boot. The tested image used
  `framebuffer.efi` from [mustafaakin/tart](https://github.com/mustafaakin/tart), a fork of Tart
  under Tart's Fair Source License.
- Windows installed without Windows Setup's checks for a TPM and Secure Boot, which the VM
  doesn't have: the tested image was applied with DISM from Windows PE.
- virtio-win's drivers, from its ISO: viostor for the disk, NetKVM for the network, and viosock
  with its Winsock provider for vsock.
- The display at a fixed 1024x768: virtio-win's signed viogpudo, with no test signing; 1024x768
  saved for Windows' one display; virtio-win's resolution service, vgpusrv, off; and the basic
  display driver off (the `BasicDisplay` service's `Start` set to 4), or its monitor on the boot
  framebuffer becomes a second, invisible display that windows and the pointer can wander onto.
  Don't change the resolution: on Virtualization.framework, viogpudo garbles the screen at any
  mode change (see [Limits](limits.md)).
- The guest's clock read as UTC (`RealTimeIsUniversal` set to 1 under
  `HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation`), and this Mac's time zone.
- An administrator account that signs in by itself at boot, with no screen lock, screen saver,
  sleep or display sleep, and a US keyboard layout for `type` and `key`.
- The guest agent: copy the `guest` folder's `windows` folder, which `scripts/build.sh` makes,
  into the guest, and run `powershell -ExecutionPolicy Bypass -File install.ps1` in it as an
  administrator. It installs the agent as a service that starts at boot, and replaces an older
  agent's scheduled task (see [Windows guests](guest-agent.md#windows-guests)).
- For `paddock task`, Git for Windows: the tested image has MinGit 2.56.1 for ARM64 in
  `C:\Program Files\MinGit`, with its `cmd` folder on the machine's `PATH`. Check it with
  `paddock exec <vm> -- git --version`.

Every clone then has the account signed in at the console, where `exec` runs commands as an
administrator, so whatever a workload runs can act as one in its own VM, which is wiped when it
is released. `serve` sets each warm VM's clock from this Mac's, and the agent restarts a restored
VM's network adapter, which comes back receiving nothing.
