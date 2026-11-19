import Foundation

/// One Mac as `paddock top` shows it: what its serve reports, from the Mac itself or through the
/// control plane.
public struct MacStatus: Codable, Equatable, Sendable {
    public var name: String
    public var image: String?
    public var online: Bool
    public var usage: MacUsage?  // none until serve has sampled twice, or while the Mac is offline
    public var slots: [ControlLink.SlotReport]

    public init(name: String, image: String?, online: Bool, usage: MacUsage?, slots: [ControlLink.SlotReport]) {
        self.name = name
        self.image = image
        self.online = online
        self.usage = usage
        self.slots = slots
    }
}

/// `paddock top`'s screen, as lines: a summary, then a row per Mac, then a row per slot.
public enum TopView {
    public static func lines(of macs: [MacStatus], from source: String, width: Int) -> [String] {
        let slots = macs.filter(\.online).flatMap(\.slots)
        let counts = ["warm", "assigned", "preparing", "empty"].compactMap { state -> String? in
            let count = slots.filter { $0.state == state }.count
            return count == 0 ? nil : "\(count) \(state)"
        }
        let summary = (["paddock top", source, macs.count == 1 ? "1 Mac" : "\(macs.count) Macs"] + counts)
            .joined(separator: " · ")
        let macRows = [["MAC", "CPU", "MEMORY", "PRESSURE", "DISK FREE", "THERMAL"]] + macs.map(row)
        var slotRows = [["MAC", "SLOT", "STATE", "VM", "FOR", "CPU", "MEMORY"]]
        for mac in macs where mac.online {
            slotRows += mac.slots.map { row($0, on: mac) }
        }
        let screen = [summary, ""] + columns(macRows) + [""] + columns(slotRows)
        return screen.map { String($0.prefix(max(width, 20))) }
    }

    static func row(_ mac: MacStatus) -> [String] {
        guard mac.online else { return [mac.name, "offline", "-", "-", "-", "-"] }
        guard let usage = mac.usage else { return [mac.name, "-", "-", "-", "-", "-"] }
        let used = String(format: "%.1f", Double(usage.memoryUsed) / Double(1 << 30))
        let memory = used + "/" + ByteFormat.memory(usage.memoryTotal)
        return [mac.name, percent(usage.cpu), memory, usage.pressure, usage.diskFree.map(disk) ?? "-", usage.thermal]
    }

    static func row(_ slot: ControlLink.SlotReport, on mac: MacStatus) -> [String] {
        let vm: String = slot.vm ?? slot.reason ?? "-"
        let since: String = slot.age.map(age) ?? "-"
        let memory: String = slot.usage.map { ByteFormat.memory($0.memory) } ?? "-"
        return [mac.name, String(slot.number), slot.state, vm, since, percent(slot.usage?.cpu), memory]
    }

    static func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "-"
    }

    /// Free disk in decimal units, as Finder counts it: "180.3 GB" or "1.2 TB".
    static func disk(_ bytes: UInt64) -> String {
        bytes >= 1_000_000_000_000 ? String(format: "%.1f TB", Double(bytes) / 1e12) : ByteFormat.gigabytes(Int64(bytes))
    }

    /// "8s", "4m 12s" or "2h 05m".
    static func age(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds)s"
        case ..<3600: "\(seconds / 60)m \(seconds % 60)s"
        default: "\(seconds / 3600)h " + String(format: "%02dm", seconds % 3600 / 60)
        }
    }

    /// Rows as columns two spaces apart, the last one unpadded.
    static func columns(_ rows: [[String]]) -> [String] {
        let widths = (0..<(rows.first?.count ?? 0)).map { index in rows.map { $0[index].count }.max() ?? 0 }
        return rows.map { row in
            zip(row, widths).enumerated().map { index, cell in
                index == row.count - 1 ? cell.0 : cell.0.padding(toLength: cell.1, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
    }
}
