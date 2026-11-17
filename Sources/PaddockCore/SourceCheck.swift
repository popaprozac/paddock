/// Settings in a golden image that break VMs nobody watches. serve checks them once, in the clone
/// it boots for its slot, and warns: they are security settings, so changing them in the golden
/// image is its owner's call, and paddock doesn't change them itself.
///
/// The screen lock isn't among them: clones always have it on, whatever the golden image says,
/// since macOS keeps that setting with the machine's identity, which every clone changes, and
/// turning it off takes the user's password. So the screen saver and sleep, which would trigger
/// it, must stay off.
public enum SourceCheck {
    /// A command for the guest agent to run as the guest's user. It prints one line per setting,
    /// as name=value, and needs no permission: reading the folder Full Disk Access guards fails
    /// at once without it, where touching the Desktop would wait for a prompt.
    public static let command = """
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
        let locks = "which locks the screen in a clone until the user's password is typed"
        switch values["saver"] {
        case "0"?:
            break
        case let saver?:
            let after = saver == "unset" ? "20 minutes without input, macOS's default" : "\(saver) s without input"
            problems.append("its screen saver starts after \(after), \(locks): set \"Start Screen Saver when "
                + "inactive\" to Never in System Settings > Lock Screen, and use paddock-guestd 0.5.0 or later, "
                + "which carries it into clones")
        case nil:
            problems.append("paddock couldn't read its screen saver setting")
        }
        for (name, what) in [("displaysleep", "display"), ("sleep", "Mac")] {
            if let minutes = values[name], minutes != "0" {
                problems.append("its \(what) sleeps after \(minutes) minutes, \(locks): run "
                    + "'sudo pmset -a sleep 0 displaysleep 0'")
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
