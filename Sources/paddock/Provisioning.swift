import Darwin
import Foundation
import PaddockCore
import Virtualization

/// The account macOS 27 creates on a VM's first boot after install, in place of Setup Assistant,
/// for `paddock run --provision` and `paddock build`.
enum Provisioning {
    /// Rejects names provisioning can't use. Reported on Apple's developer forums for macOS 27:
    /// provisioning an account with the host user's name fails, and Setup Assistant appears.
    static func validate(account: String) throws {
        guard account.range(of: "^[a-z_][a-z0-9_.-]{0,31}$", options: .regularExpression) != nil else {
            throw PaddockError("'\(account)' isn't a short account name: use lowercase letters, digits, '_', '.' or '-'")
        }
        if account == NSUserName() {
            throw PaddockError("give the VM's account a name other than this Mac's user, '\(account)'")
        }
    }

    /// The account's password, read from the terminal without echo, twice, so a typo can't
    /// lock the account. paddock keeps it in memory only, for as long as the command runs.
    static func readPassword(for account: String) throws -> String {
        let password = try readSecret("Password for '\(account)' in the VM: ")
        guard try readSecret("Again: ") == password else {
            throw PaddockError("the two passwords differ")
        }
        return password
    }

    /// Guest provisioning for the account, with automatic login and Remote Login on.
    @available(macOS 27, *)
    static func options(account: String, fullName: String, password: String) throws -> VZMacGuestProvisioningOptions {
        let options = VZMacGuestProvisioningOptions()
        options.fullName = fullName
        options.username = account
        options.password = password
        options.logsInAutomatically = true
        options.enablesRemoteLogin = true
        try options.validate()
        return options
    }

    private static func readSecret(_ prompt: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
            throw PaddockError("paddock needs a terminal to read the password from")
        }
        let secret = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !secret.isEmpty else { throw PaddockError("the password can't be empty") }
        return secret
    }
}
