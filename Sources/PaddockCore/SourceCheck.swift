/// Settings in a golden image that break VMs nobody watches. serve checks them once, in the clone
/// it boots for its slot, and warns: they are security settings, so changing them in the golden
/// image is its owner's call, and paddock doesn't change them itself.
public enum SourceCheck {
    /// A command for the guest agent to run as the guest's user. It prints one line per setting,
    /// as name=value, and needs no permission: reading the folder Full Disk Access guards fails
    /// at once without it, where touching the Desktop would wait for a prompt.
    public static let command = """
        printf 'lock=%s\\n' "$(sysadminctl -screenLock status 2>&1 | sed -n 's/.*screenLock //p' | tail -1)"
        printf 'saver=%s\\n' "$(defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || echo unset)"
        pmset -g | awk '/^ displaysleep /{print "displaysleep=" $2} /^ sleep /{print "sleep=" $2}'
        ls '/Library/Application Support/com.apple.TCC' >/dev/null 2>&1 && echo files=all || echo files=limited
        """

    /// What `command`'s output shows is wrong, each as what happens and what to change.
    public static func problems(in output: [String]) -> [String] {
        var values: [String: String] = [:]
        for line in output {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        var problems: [String] = []
        switch values["lock"] {
        case let lock? where lock.contains("off"):
            break
        case let lock?:
            problems.append("its screen locks (screen lock \(lock.isEmpty ? "on" : lock)), and only the user's password "
                + "unlocks it: set \"Require password after screen saver begins or display is turned off\" to Never in "
                + "System Settings > Lock Screen")
        case nil:
            problems.append("paddock couldn't read its screen lock setting")
        }
        switch values["saver"] {
        case "0"?:
            break
        case let saver?:
            let after = saver == "unset" ? "20 minutes without input, macOS's default" : "\(saver) s without input"
            problems.append("its screen saver starts after \(after): set \"Start Screen Saver when "
                + "inactive\" to Never in System Settings > Lock Screen")
        case nil:
            problems.append("paddock couldn't read its screen saver setting")
        }
        for (name, what) in [("displaysleep", "display"), ("sleep", "Mac")] {
            if let minutes = values[name], minutes != "0" {
                problems.append("its \(what) sleeps after \(minutes) minutes: run 'sudo pmset -a sleep 0 displaysleep 0'")
            }
        }
        if values["files"] == "limited" {
            problems.append("paddock-guestd lacks Full Disk Access, so a command that touches Desktop, Documents or "
                + "Downloads waits for a prompt nobody answers: add /usr/local/libexec/paddock-guestd in System Settings "
                + "> Privacy & Security > Full Disk Access")
        }
        return problems
    }
}
