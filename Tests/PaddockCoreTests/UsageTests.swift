import Foundation
import Testing
@testable import PaddockCore

@Suite struct UsageTests {
    @Test func cpuIsTheShareOfTimeAndNoneWithoutTime() {
        #expect(UsageSampler.percent(50, of: 200) == 25)
        #expect(UsageSampler.percent(3, of: 1) == 300)  // a VM busy on three cores
        #expect(UsageSampler.percent(5, of: 0) == nil)
    }

    @Test func aVMIsKnownByItsBundlesDiskImage() {
        let folder = "/Users/me/.paddock/vms"
        #expect(UsageSampler.vmName(openFile: "\(folder)/golden-slot1-abc/disk.img", in: folder) == "golden-slot1-abc")
        #expect(UsageSampler.vmName(openFile: "\(folder)/golden-slot1-abc/disk.img", in: folder + "/") == "golden-slot1-abc")
        #expect(UsageSampler.vmName(openFile: "\(folder)/golden-slot1-abc/aux.img", in: folder) == nil)
        #expect(UsageSampler.vmName(openFile: "\(folder)/a/b/disk.img", in: folder) == nil)
        #expect(UsageSampler.vmName(openFile: "/Volumes/Other/vms/x/disk.img", in: folder) == nil)
    }

    @Test func pressureLevelsReadAsMacOSNamesThem() {
        #expect(UsageSampler.pressure(level: 1) == "normal")
        #expect(UsageSampler.pressure(level: 2) == "warn")
        #expect(UsageSampler.pressure(level: 4) == "critical")
    }

    @Test func samplesThisMac() async throws {
        let empty = try TemporaryDirectory()
        let sampler = UsageSampler()
        let first = sampler.sample(vms: empty.url, diskFree: 42)
        #expect(first.mac.cpu == nil)
        #expect(first.mac.memoryTotal == ProcessInfo.processInfo.physicalMemory)
        #expect(first.mac.memoryUsed > 0 && first.mac.memoryUsed <= first.mac.memoryTotal)
        #expect(["normal", "warn", "critical"].contains(first.mac.pressure))
        #expect(first.mac.diskFree == 42)
        #expect(first.vms.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        let cpu = try #require(sampler.sample(vms: empty.url, diskFree: nil).mac.cpu)
        #expect(cpu >= 0 && cpu <= 100)
    }

    @Test func topShowsEachMacThenEachSlot() {
        let usage = MacUsage(cpu: 23.4, memoryUsed: 21 << 30, memoryTotal: 36 << 30, pressure: "normal",
                             thermal: "nominal", diskFree: 1_234_000_000_000)
        var assigned = ControlLink.SlotReport(number: 1, emptyReason: nil, assigned: true, warm: true, vm: "golden-slot1-a")
        assigned.age = 252
        assigned.usage = VMUsage(cpu: 112, memory: 13_958_643_712)
        assigned.holder = "zach on Studio"
        let preparing = ControlLink.SlotReport(number: 2, emptyReason: nil, assigned: false, warm: false, vm: "golden-slot2-b")
        let studio = MacStatus(name: "Studio", image: "golden", online: true, usage: usage, slots: [assigned, preparing])
        let laptop = MacStatus(name: "Laptop", image: "golden", online: false, usage: nil, slots: [])
        let lines = TopView.lines(of: [studio, laptop], from: "the pool", waiting: 2, width: 200)
        #expect(lines[0] == "paddock top · the pool · 2 Macs · 1 assigned · 1 preparing · 2 waiting")
        #expect(lines[2].hasPrefix("MAC "))
        #expect(lines[3] == "Studio  23%      21.0/36.0 GB  normal    1.2 TB     nominal")
        #expect(lines[4] == "Laptop  offline  -             -         -          -")
        #expect(lines[7] == "Studio  1     assigned   golden-slot1-a  zach on Studio  4m 12s  112%  13.0 GB")
        #expect(lines[8] == "Studio  2     preparing  golden-slot2-b  -               -       -     -")
        #expect(TopView.lines(of: [studio], from: "x", waiting: 0, width: 200)[0] == "paddock top · x · 1 Mac · 1 assigned · 1 preparing")
        #expect(TopView.lines(of: [studio], from: "x", width: 30).allSatisfy { $0.count <= 30 })
    }

    @Test func agesReadShort() {
        #expect(TopView.age(8) == "8s")
        #expect(TopView.age(252) == "4m 12s")
        #expect(TopView.age(7500) == "2h 05m")
    }
}
