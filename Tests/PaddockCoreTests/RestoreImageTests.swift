import Foundation
import Testing
@testable import PaddockCore

@Suite struct RestoreImageTests {
    @Test func cachesUnderTheRemoteFileName() {
        let remote = RemoteRestoreImage(
            url: URL(string: "https://updates.cdn-apple.com/x/y/UniversalMac_27.1_27B100_Restore.ipsw")!,
            version: "27.1", build: "27B100")
        let cached = remote.cachedFileURL(in: URL(fileURLWithPath: "/tmp/cache/ipsw"))
        #expect(cached.path == "/tmp/cache/ipsw/UniversalMac_27.1_27B100_Restore.ipsw")
    }

    @Test func formatsByteCounts() {
        #expect(ByteFormat.gigabytes(18_253_611_008) == "18.3 GB")
        #expect(ByteFormat.gigabytes(512_000_000) == "0.5 GB")
    }
}

@Suite struct VMSizingTests {
    let limits = VMSizing.Limits(minimumCPUCount: 2, maximumCPUCount: 14,
                                 minimumMemorySize: 4 << 30, maximumMemorySize: 32 << 30)

    @Test func keepsRequestsInsideLimits() {
        let sizing = VMSizing.resolve(cpuCount: 6, memorySize: 12 << 30, limits: limits)
        #expect(sizing.cpuCount == 6)
        #expect(sizing.memorySize == 12 << 30)
    }

    @Test func raisesRequestsToTheImageMinimum() {
        let sizing = VMSizing.resolve(cpuCount: 1, memorySize: 1 << 30, limits: limits)
        #expect(sizing.cpuCount == 2)
        #expect(sizing.memorySize == 4 << 30)
    }

    @Test func capsRequestsAtTheHostMaximum() {
        let sizing = VMSizing.resolve(cpuCount: 64, memorySize: 64 << 30, limits: limits)
        #expect(sizing.cpuCount == 14)
        #expect(sizing.memorySize == 32 << 30)
    }

    @Test func roundsMemoryUpToWholeMebibytes() {
        let sizing = VMSizing.resolve(cpuCount: 4, memorySize: (8 << 30) + 1, limits: limits)
        #expect(sizing.memorySize == (8 << 30) + (1 << 20))
    }
}
