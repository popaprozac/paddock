import Foundation
import Testing
@testable import PaddockCore

@Suite struct BundleNameTests {
    @Test(arguments: ["golden", "ci-runner_1.2", "macOS27"])
    func acceptsSimpleNames(_ name: String) throws {
        try BundleName.validate(name)
    }

    @Test(arguments: ["", "a/b", "..", ".hidden", "with space", String(repeating: "x", count: 65)])
    func rejectsUnsafeNames(_ name: String) {
        #expect(throws: PaddockError.self) { try BundleName.validate(name) }
    }
}

@Suite struct PaddockHomeTests {
    @Test func usesPaddockHomeWhenSet() {
        let home = PaddockHome.fromEnvironment(["PADDOCK_HOME": "/Volumes/Fast/paddock", "HOME": "/Users/me"])
        #expect(home.root.path == "/Volumes/Fast/paddock")
        #expect(home.vmsDirectory.path == "/Volumes/Fast/paddock/vms")
        #expect(home.ipswCacheDirectory.path == "/Volumes/Fast/paddock/cache/ipsw")
    }

    @Test func defaultsToDotPaddockInHome() {
        let home = PaddockHome.fromEnvironment(["HOME": "/Users/me"])
        #expect(home.root.path == "/Users/me/.paddock")
    }

    @Test func resolvesBundlesByName() throws {
        let home = PaddockHome(root: URL(fileURLWithPath: "/tmp/p"))
        let bundle = try home.bundle(named: "golden")
        #expect(bundle.url.path == "/tmp/p/vms/golden")
        #expect(bundle.diskURL.lastPathComponent == "disk.img")
        #expect(bundle.auxiliaryStorageURL.lastPathComponent == "aux.img")
        #expect(bundle.configURL.lastPathComponent == "config.json")
        #expect(throws: PaddockError.self) { try home.bundle(named: "../etc") }
    }
}

@Suite struct VMConfigTests {
    static let sample = VMConfig(
        hardwareModel: Data([1, 2, 3, 4]),
        machineIdentifier: Data([5, 6, 7, 8]),
        macAddress: "12:34:56:78:9a:bc",
        cpuCount: 4,
        memorySize: 8 << 30,
        diskSize: 80 << 30,
        display: .init(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80),
        os: .init(version: "27.1", build: "27B100")
    )

    @Test func roundTripsThroughBundle() throws {
        let tmp = try TemporaryDirectory()
        let bundle = VMBundle(url: tmp.url)
        try bundle.writeConfig(Self.sample)
        #expect(try bundle.readConfig() == Self.sample)
    }

    @Test func storesBinaryFieldsAsBase64() throws {
        let tmp = try TemporaryDirectory()
        let bundle = VMBundle(url: tmp.url)
        try bundle.writeConfig(Self.sample)
        let json = try String(contentsOf: bundle.configURL, encoding: .utf8)
        #expect(json.contains("\"hardwareModel\" : \"AQIDBA==\""))
    }

    @Test func missingConfigIsAClearError() throws {
        let tmp = try TemporaryDirectory()
        let bundle = VMBundle(url: tmp.url.appendingPathComponent("nope"))
        #expect(throws: PaddockError.self) { try bundle.readConfig() }
    }
}
