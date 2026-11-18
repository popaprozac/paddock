/// What `paddock build` writes into a macOS 26 image from Recovery, before its first boot, in place
/// of Setup Assistant, which ignores provisioning on 26: the account, the guest agent, automatic
/// login, and the per-user Setup Assistant's record of pages already seen, so the first boot logs
/// in to the desktop by itself. Found by a spike on 26.6.2; the per-user keys are the ones that
/// Setup Assistant wrote there after a login by hand.
public enum OfflineSetup {
    /// The account's user ID: the first account on a fresh install, as Setup Assistant makes it.
    public static let userID = 501

    /// Lines for Recovery's Terminal (bash 3.2, as root), for an account named `account`, which
    /// Provisioning has checked: one command, each line ending in `&&`, so the VM halts only if
    /// every step worked. The account's password must already be in `$P`, from `read -rs P`, so it
    /// is never on screen or in this text; the script unsets it once it's written. The guest
    /// agent's files come from the shared guest folder. It runs the installed system's tools
    /// where Recovery has none, and assumes the volumes' default names, as `paddock grant` does.
    public static func recoveryScript(account: String, fullName: String) -> String {
        let user = "/Local/Target/Users/\(account)"
        let dscl = #"dscl -f "$N" localonly"#
        let libexec = #""$D/usr/local/libexec""#
        let daemon = #""$D/Library/LaunchDaemons/paddock.guestd.plist""#
        let agent = #""$D/Library/LaunchAgents/paddock.session.plist""#
        var lines = [
            "D=/Volumes/Data",
            #"S="/Volumes/Macintosh HD""#,
            #"G="/Volumes/My Shared Files""#,
            "N=$D/private/var/db/dslocal/nodes/Default",
            "H=$D/Users/\(account)",
            // The account, as Setup Assistant makes it: dscl hashes the password offline, and
            // the account gets a Secure Token and owns the volume at its first login.
            "\(dscl) -create \(user)",
            "\(dscl) -create \(user) RealName \(quoted(fullName))",
            "\(dscl) -create \(user) UniqueID \(userID)",
            "\(dscl) -create \(user) PrimaryGroupID 20",
            "\(dscl) -create \(user) UserShell /bin/zsh",
            "\(dscl) -create \(user) NFSHomeDirectory /Users/\(account)",
            #"\#(dscl) -passwd \#(user) "$P""#,
            // macOS's automatic login reads the password from this file, obscured, not encrypted,
            // as System Settings writes it.
            #""$S/usr/bin/perl" -e '\#(kcpasswordProgram)' "$P" > "$D/private/etc/kcpassword""#,
            "unset P",
            #"chmod 600 "$D/private/etc/kcpassword""#,
            #"chown root:wheel "$D/private/etc/kcpassword""#,
            #"defaults write "$D/Library/Preferences/com.apple.loginwindow" autoLoginUser \#(account)"#,
            // -merge, not -append, which adds the name again if it's already there.
            "\(dscl) -merge /Local/Target/Groups/admin GroupMembership \(account)",
            #"mkdir -p "$H/Library/Preferences""#,
            #"ditto "$S/System/Library/User Template/Non_localized" "$H""#,
            #"ditto "$S/System/Library/User Template/English.lproj" "$H""#,
            // Device Setup Assistant is done.
            #"touch "$D/private/var/db/.AppleSetupDone""#,
            "mkdir -p \(libexec)",
            // -X leaves out extended attributes such as quarantine, which would stop launchd.
            #"cp -X "$G/paddock-guestd" "$G/paddock-session" \#(libexec)"#,
            #"cp -X "$G/paddock.guestd.plist" "$D/Library/LaunchDaemons/""#,
            #"cp -X "$G/paddock.session.plist" "$D/Library/LaunchAgents/""#,
            #"chown root:wheel \#(libexec)/paddock-guestd \#(libexec)/paddock-session \#(daemon) \#(agent)"#,
            #"chmod 755 \#(libexec)/paddock-guestd \#(libexec)/paddock-session"#,
            "chmod 644 \(daemon) \(agent)",
            // The per-user Setup Assistant shows its pages at the first login unless the account's
            // preferences say it has seen them, for this very macOS.
            #"PV=$(defaults read "$S/System/Library/CoreServices/SystemVersion" ProductVersion)"#,
            #"PB=$(defaults read "$S/System/Library/CoreServices/SystemVersion" ProductBuildVersion)"#,
            #"A="$H/Library/Preferences/com.apple.SetupAssistant""#,
        ]
        lines += seenPages.map { #"defaults write "$A" DidSee\#($0) -bool true"# }
        lines += seenOnVersion.map { #"defaults write "$A" \#($0) "$PV""# }
        lines += seenOnBuild.map { #"defaults write "$A" \#($0) "$PB""# }
        lines += [
            #"defaults write "$A" LastPrivacyBundleVersion -int 2"#,
            #"defaults write "$A" MiniBuddyLaunchReason -int 0"#,
            #"defaults write "$A" MiniBuddyShouldLaunchToResumeSetup -bool false"#,
            #"defaults write "$A" selectedFDEEscrowType DeclinedFDE"#,
            #"chown -R \#(userID):20 "$H""#,
            #"touch "$D/private/var/db/.AppleDiagnosticsSetupDone""#,
            #"chmod 400 "$D/private/var/db/.AppleDiagnosticsSetupDone""#,
            "halt",
        ]
        return lines.joined(separator: " &&\n") + "\n"
    }

    /// Perl, from the installed system, that prints the password given as its argument as macOS
    /// keeps it for automatic login (/etc/kcpassword): a NUL after it, NULs up to a multiple of 12
    /// bytes, all XORed with Apple's fixed 11-byte key. No single quotes, as it goes inside them.
    static let kcpasswordProgram = #"@k=(0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F); $p=shift; $p.="\0"; $p.="\0" while length($p)%12; print join "", map { chr(ord(substr($p,$_,1)) ^ $k[$_ % 11]) } 0..length($p)-1"#

    /// Pages of the per-user Setup Assistant, for `DidSee<page>`.
    static let seenPages = [
        "Accessibility", "ActivationLock", "AppStore", "AppearanceSetup", "ApplePaySetup", "CloudSetup",
        "LockdownMode", "Privacy", "ScreenTime", "SiriSetup", "SyncSetup", "SyncSetup2", "TermsOfAddress",
        "TouchIDSetup", "iCloudLoginForStorageServices",
    ]
    /// Keys that hold the macOS version the pages were seen on.
    static let seenOnVersion = [
        "LastSeenAgeRangeSelectionProductVersion", "LastSeenCloudProductVersion", "LastSeenDiagnosticsProductVersion",
        "InitialSetupProductVersion", "LastPreLoginTasksPerformedVersion",
    ]
    /// Keys that hold the macOS build the pages were seen on.
    static let seenOnBuild = ["LastSeenBuddyBuildVersion", "InitialSetupBuildVersion", "LastPreLoginTasksPerformedBuild"]

    /// `text` as one word for bash, in single quotes.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
