import Foundation

/// A VM on disk: a directory holding the boot disk, auxiliary storage and `config.json`.
///
///     <name>/
///       disk.img     sparse raw disk image
///       aux.img      Mac auxiliary storage (NVRAM)
///       config.json  hardware model, machine identifier, MAC address, CPU, memory, display
///       state.vzvmsave  optional saved memory and device state of a paused VM
public struct VMBundle: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var name: String { url.lastPathComponent }
    public var diskURL: URL { url.appendingPathComponent("disk.img") }
    public var auxiliaryStorageURL: URL { url.appendingPathComponent("aux.img") }
    public var configURL: URL { url.appendingPathComponent("config.json") }
    public var savedStateURL: URL { url.appendingPathComponent("state.vzvmsave") }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: configURL.path)
    }

    public func readConfig() throws -> VMConfig {
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw PaddockError("no VM bundle at \(url.path) (missing config.json)")
        }
        do {
            return try JSONDecoder().decode(VMConfig.self, from: data)
        } catch {
            throw PaddockError("unreadable \(configURL.path): \(error.localizedDescription)")
        }
    }

    public func writeConfig(_ config: VMConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }
}
