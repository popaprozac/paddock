import Foundation

/// The privacy permissions paddock's guest helpers need, and the command `paddock grant` types in
/// macOS Recovery to write them into an image's privacy database (TCC.db). SIP guards that
/// database while the image's macOS runs, so a VM can't grant itself more; Recovery's root can
/// write it with SIP left on.
public enum PrivacyGrants {
    public struct Grant: Sendable {
        /// TCC's name for the permission.
        public var service: String
        /// Path of the signed binary in the guest.
        public var helper: String
    }

    public static let helpers = [
        Grant(service: "kTCCServiceAccessibility", helper: "/usr/local/libexec/paddock-session"),
        Grant(service: "kTCCServiceSystemPolicyAllFiles", helper: "/usr/local/libexec/paddock-guestd"),
    ]

    /// Lines for Recovery's Terminal (bash 3.2, as root): one command, each line ending in `&&`,
    /// so the VM halts only if every step worked. For each helper, it compiles the binary's
    /// designated requirement into the code requirement TCC stores, so the permission belongs to
    /// that signed binary, then writes the row with the values macOS writes when the owner allows
    /// it in System Settings. The installed system's tools run from Recovery, which has no
    /// sqlite3. Assumes the volumes' default names.
    public static func recoveryScript(_ grants: [Grant] = helpers) -> String {
        var lines = ["set -o pipefail", #"M="/Volumes/Macintosh HD/usr/bin" D=/Volumes/Data"#]
        var rows: [String] = []
        for (index, grant) in grants.enumerated() {
            let csreq = "/tmp/paddock-\(index).csreq"
            lines.append(#""$M/codesign" -d -r- "$D\#(grant.helper)" | sed -n 's/^designated => //p' | "$M/csreq" -r- -b \#(csreq)"#)
            rows.append("insert or replace into access (service, client, client_type, auth_value, auth_reason, "
                + "auth_version, csreq, indirect_object_identifier_type, flags) values ('\(grant.service)', "
                + "'\(grant.helper)', 1, 2, 4, 1, readfile('\(csreq)'), 0, 0);")
        }
        lines.append(#""$M/sqlite3" "$D/Library/Application Support/com.apple.TCC/TCC.db" "\#(rows.joined(separator: " "))""#)
        lines.append("halt")
        return lines.joined(separator: " &&\n") + "\n"
    }
}
