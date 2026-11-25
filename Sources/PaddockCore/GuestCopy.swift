import Foundation

/// `paddock cp`'s guest side. A path in a VM is the guest account's, as scp's are: absolute, or
/// relative to its home, and empty for the home folder itself. A file goes through the agent's
/// staging folder, `~/paddock`, where put and get work, and is moved between it and the path as
/// the account, with the guest's own shell: POSIX sh on macOS and Linux, cmd.exe on Windows.
public enum GuestCopy {
    /// A `<vm>:<path>` argument, split at its first colon, or nil for a path on this Mac: one with
    /// no colon, or whose part before it isn't a VM's name, as "./a:b" is.
    public static func split(_ argument: String) -> (vm: String, path: String)? {
        guard let colon = argument.firstIndex(of: ":"),
              (try? BundleName.validate(String(argument[..<colon]))) != nil else { return nil }
        return (String(argument[..<colon]), String(argument[argument.index(after: colon)...]))
    }

    /// The last component of a guest path, or nil if it names a folder, as "" or "work/" do.
    public static func lastComponent(of path: String) -> String? {
        let last = path.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last
        guard let last, !last.isEmpty, last != ".", last != ".." else { return nil }
        return String(last)
    }

    /// Why `path` can't be named in the guest's shell, or nil. cmd.exe expands %VAR% even inside
    /// quotes, and a quote can't be in a Windows path at all.
    public static func problem(with path: String, windows: Bool) -> String? {
        if path.contains("\0") || path.contains("\n") || path.contains("\r") {
            return "a path in a VM can't hold a line break or a NUL"
        }
        if windows, path.contains("%") || path.contains("\"") {
            return "a path in a Windows VM can't hold % or \""
        }
        return nil
    }

    /// A name for the file in the staging folder, unique to one copy.
    public static func stagingName() -> String {
        "cp-" + UUID().uuidString.lowercased()
    }

    /// Moves the staged file to `path`, or into it, under `name`, if it's a folder. If the move
    /// fails, the staged file goes, and the command fails with the shell's own message.
    public static func moveIn(_ staging: String, to path: String, name: String, windows: Bool) -> String {
        if windows {
            let target = windowsPath(path), staged = #""%USERPROFILE%\paddock\\#(staging)""#
            return #"cd /d "%USERPROFILE%" && (if exist "\#(target)\*" (move /y \#(staged) "\#(target)\\#(name)" >nul) "#
                + #"else (move /y \#(staged) "\#(target)" >nul)) || (del /f /q \#(staged) 2>nul & exit 1)"#
        }
        return "cd ~ && d=\(quoted(posixPath(path))) && { [ -d \"$d\" ] && d=\"$d/\"\(quoted(name)); true; } && "
            + "mv -f ~/paddock/\(staging) \"$d\" || { rm -f ~/paddock/\(staging); exit 1; }"
    }

    /// Copies the file at `path` into the staging folder as `staging`. A folder is refused.
    public static func stageOut(_ path: String, as staging: String, windows: Bool) -> String {
        if windows {
            let source = windowsPath(path)
            return #"cd /d "%USERPROFILE%" && (if exist "\#(source)\*" (echo "\#(source)" is a folder; paddock cp copies files& exit 1)) && "#
                + #"copy /y "\#(source)" "%USERPROFILE%\paddock\\#(staging)" >nul"#
        }
        return "cd ~ && s=\(quoted(posixPath(path))) && "
            + "if [ -d \"$s\" ]; then echo \"$s is a folder; paddock cp copies files\"; exit 1; fi && "
            + "cp -f \"$s\" ~/paddock/\(staging)"
    }

    /// Removes the staged file, if it's there.
    public static func remove(_ staging: String, windows: Bool) -> String {
        windows ? #"del /f /q "%USERPROFILE%\paddock\\#(staging)" 2>nul"# : "rm -f ~/paddock/\(staging)"
    }

    /// The path relative to the home folder the shell starts in: "~" and a leading "~/" mean it,
    /// and "" is the folder itself.
    private static func posixPath(_ path: String) -> String {
        if path == "~" || path.isEmpty { return "." }
        if path.hasPrefix("~/") { return String(path.dropFirst(2)).isEmpty ? "." : String(path.dropFirst(2)) }
        return path
    }

    /// The same for cmd.exe, with its own separators, which its commands need in a path.
    private static func windowsPath(_ path: String) -> String {
        let path = path.replacingOccurrences(of: "/", with: "\\")
        if path == "~" || path.isEmpty { return "." }
        if path.hasPrefix("~\\") { return String(path.dropFirst(2)).isEmpty ? "." : String(path.dropFirst(2)) }
        return path
    }

    /// `text` in single quotes for a POSIX shell, which takes everything in them literally but a
    /// single quote, written as '\''.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
