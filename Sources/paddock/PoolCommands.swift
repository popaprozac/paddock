import ArgumentParser
import Foundation
import PaddockCore

/// The commands that log this Mac in to a control plane as a client and look at its pool.

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Log in to a control plane, so this Mac's paddock commands use its pool.",
        discussion: """
            Takes a login token from 'paddock-control login-token', where the control plane runs. \
            paddock makes this Mac a key, which never leaves it, and trusts only the control \
            plane's CA that the token names. The login is kept in the paddock home's client \
            folder, apart from a Mac's own link to the pool as a host. Logging in again \
            replaces it.
            """)

    @Argument(help: "The control plane's URL, such as https://studio.local:7443.")
    var url: String

    @Option(help: "A login token from 'paddock-control login-token'.")
    var token: String

    func run() async throws {
        let url = try ControlEnrollment.url(url)
        let parsed = try ControlLink.Token(token)
        guard parsed.kind == .client else {
            throw PaddockError("that's a join token, for adding a Mac with 'paddock serve --join'; to log in, use a token "
                + "from 'paddock-control login-token'")
        }
        let home = PaddockHome.fromEnvironment()
        let identity = try await ControlEnrollment.join(url, token: parsed, as: .client,
                                                        name: "\(NSUserName()) on \(ControlClient.computerName)")
        try identity.save(to: ControlIdentity.folder(in: home, for: .client))
        let hosts = try await Pool.hosts(identity)
        let online = hosts.filter(\.online).count
        print("Logged in to the control plane at \(url.absoluteString) as \(identity.id); "
            + "its pool has \(hosts.count) Mac\(hosts.count == 1 ? "" : "s"), \(online) online. See them: paddock hosts")
    }
}

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Log out of the control plane: it forgets this client, and this Mac forgets the login.")

    func run() async throws {
        let home = PaddockHome.fromEnvironment()
        let identity = try PoolConnection.identity(in: home)
        var removedThere = true
        do {
            let connection = try await PoolConnection.open(identity)
            _ = try await connection.ask(ControlLink.Message(type: "request", op: "logout"))
            connection.close()
        } catch {
            removedThere = false
            print("Couldn't reach the control plane (\(error.localizedDescription)); to remove this client there too: "
                + "paddock-control remove-client \(identity.id)")
        }
        try FileManager.default.removeItem(at: ControlIdentity.folder(in: home, for: .client))
        print("Logged out of \(identity.url.absoluteString)" + (removedThere ? "; it no longer knows \(identity.id)" : ""))
    }
}

struct Hosts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hosts",
        abstract: "List the Macs in the logged-in control plane's pool, and what each reports.")

    @Flag(help: "Print JSON, with each Mac's address, cores, memory, free disk and what it and its VMs use now too.")
    var json = false

    func run() async throws {
        let hosts = try await Pool.hosts(try PoolConnection.identity()).sorted { $0.name < $1.name }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(hosts), as: UTF8.self))
            return
        }
        guard !hosts.isEmpty else {
            return print("No Macs have joined the pool yet. Add one with a token from 'paddock-control join-token'.")
        }
        let when = DateFormatter()
        when.dateFormat = "MMM d HH:mm"
        let rows = [["NAME", "ID", "STATUS", "IMAGE", "SLOTS", "MACOS", "PADDOCK"]] + hosts.map { host in
            [host.name, host.id, host.online ? "online since \(host.connected.map(when.string(from:)) ?? "?")" : "offline",
             host.image ?? "-", Pool.slotSummary(host.slots ?? []), host.macos ?? "-", host.version ?? "-"]
        }
        let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
        for row in rows {
            print(zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
        }
    }
}

enum Pool {
    /// The pool's Macs, asked of the control plane over one short link.
    static func hosts(_ identity: ControlIdentity) async throws -> [ControlLink.HostStatus] {
        let connection = try await PoolConnection.open(identity)
        defer { connection.close() }
        return try await connection.ask(ControlLink.Message(type: "request", op: "hosts")).flatMap { $0.hosts ?? [] }
    }

    /// A host's slots in a few words, such as "1 warm, 1 assigned".
    static func slotSummary(_ slots: [ControlLink.SlotReport]) -> String {
        guard !slots.isEmpty else { return "-" }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for slot in slots {
            if counts[slot.state] == nil { order.append(slot.state) }
            counts[slot.state, default: 0] += 1
        }
        return order.map { "\(counts[$0]!) \($0)" }.joined(separator: ", ")
    }
}
