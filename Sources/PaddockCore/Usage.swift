import Darwin
import Foundation

/// What this Mac uses right now, measured on the host.
public struct MacUsage: Codable, Equatable, Sendable {
    public var cpu: Double?          // percent of the whole Mac's CPU since the last sample
    public var memoryUsed: UInt64    // bytes: app memory, wired and compressed, as Activity Monitor counts it
    public var memoryTotal: UInt64
    public var pressure: String      // macOS's memory pressure: normal, warn or critical
    public var thermal: String       // nominal, fair, serious or critical
    public var diskFree: UInt64?     // bytes free on the volume VMs are cloned to

    /// The pressure as a level to compare: 0 normal, 1 warn, 2 critical.
    public var pressureLevel: Int {
        ["warn": 1, "critical": 2][pressure] ?? 0
    }

    public init(cpu: Double?, memoryUsed: UInt64, memoryTotal: UInt64, pressure: String, thermal: String,
                diskFree: UInt64?) {
        self.cpu = cpu
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.pressure = pressure
        self.thermal = thermal
        self.diskFree = diskFree
    }
}

/// What one VM costs this Mac: its Virtualization.framework process, measured on the host, so
/// nothing is asked of the guest and nothing it does can change the numbers.
public struct VMUsage: Codable, Equatable, Sendable {
    public var cpu: Double?   // percent of one core since the last sample, as top shows it
    public var memory: UInt64 // the process's memory footprint, in bytes: the guest's memory and the VM's own
}

/// Samples the Mac's usage and each running VM's. CPU figures are the change since the previous
/// sample, so the first has none; sample at a steady pace.
public final class UsageSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastHost: (busy: UInt64, total: UInt64)?
    private var lastProcesses: [pid_t: (cpu: UInt64, at: UInt64)] = [:]  // nanoseconds of CPU, at mach time

    public init() {}

    /// The Mac's usage and that of each VM running from a bundle in `vms`, by VM name.
    public func sample(vms folder: URL, diskFree: UInt64?) -> (mac: MacUsage, vms: [String: VMUsage]) {
        lock.lock()
        defer { lock.unlock() }
        let now = mach_absolute_time()
        let host = Self.hostTicks()
        var cpu: Double?
        if let host, let last = lastHost {
            cpu = Self.percent(host.busy &- last.busy, of: host.total &- last.total)
        }
        lastHost = host
        var vms: [String: VMUsage] = [:]
        var seen: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
        for (pid, name) in Self.vmProcesses(in: folder) {
            guard let usage = Self.rusage(pid) else { continue }
            var vmCPU: Double?
            if let last = lastProcesses[pid] {
                vmCPU = Self.percent(usage.cpu &- last.cpu, of: Self.nanoseconds(now &- last.at))
            }
            seen[pid] = (usage.cpu, now)
            vms[name] = VMUsage(cpu: vmCPU, memory: usage.footprint)
        }
        lastProcesses = seen
        return (MacUsage(cpu: cpu, memoryUsed: Self.memoryUsed(), memoryTotal: ProcessInfo.processInfo.physicalMemory,
                         pressure: Self.pressure(), thermal: Self.thermal(ProcessInfo.processInfo.thermalState),
                         diskFree: diskFree), vms)
    }

    /// `part` as a percentage of `whole`, or nil when no time has passed.
    static func percent(_ part: UInt64, of whole: UInt64) -> Double? {
        whole == 0 ? nil : Double(part) / Double(whole) * 100
    }

    /// The VM a Virtualization process runs, from a file it holds open: its bundle's disk image,
    /// directly in `folder`.
    static func vmName(openFile path: String, in folder: String) -> String? {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        guard path.hasPrefix(prefix), path.hasSuffix("/disk.img") else { return nil }
        let parts = path.dropFirst(prefix.count).split(separator: "/")
        return parts.count == 2 ? String(parts[0]) : nil
    }

    /// macOS's memory pressure level, as `kern.memorystatus_vm_pressure_level` reports it.
    static func pressure(level: Int32) -> String {
        switch level {
        case 4: "critical"
        case 2: "warn"
        default: "normal"
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func pressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "normal" }
        return pressure(level: level)
    }

    private static func hostTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)  // user, system, nice
        return (busy, busy + UInt64(ticks.2))                             // and idle
    }

    /// Bytes in use, as Activity Monitor's Memory Used counts them.
    private static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        guard result == KERN_SUCCESS else { return 0 }
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * UInt64(page)
    }

    private static func nanoseconds(_ machTime: UInt64) -> UInt64 {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return machTime * UInt64(base.numer) / UInt64(base.denom)
    }

    private static func rusage(_ pid: pid_t) -> (cpu: UInt64, footprint: UInt64)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        return (nanoseconds(info.ri_user_time + info.ri_system_time), info.ri_phys_footprint)
    }

    /// Every running Virtualization.framework VM process with a VM in `folder` open, by pid.
    /// shortcut: matches Apple's XPC service by its path, which a macOS release could move; the
    /// VMs then show no usage until this follows it.
    private static func vmProcesses(in folder: URL) -> [pid_t: String] {
        let root = folder.resolvingSymlinksInPath().path
        var found: [pid_t: String] = [:]
        for pid in allPIDs() where executable(pid)?.contains("/com.apple.Virtualization.VirtualMachine.xpc/") == true {
            if let name = openFiles(pid).lazy.compactMap({ vmName(openFile: $0, in: root) }).first {
                found[pid] = name
            }
        }
        return found
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(0, filled))))
    }

    private static func executable(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func openFiles(_ pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        return fds.prefix(Int(max(0, filled)) / MemoryLayout<proc_fdinfo>.stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                     Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard got == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { return nil }
            return withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
    }
}
