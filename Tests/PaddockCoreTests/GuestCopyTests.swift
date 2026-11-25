import Foundation
import Testing
@testable import PaddockCore

@Suite struct GuestCopyTests {
    @Test func splitsAVMPathAtItsFirstColon() {
        #expect(GuestCopy.split("golden-slot1-abc:/tmp/x")! == ("golden-slot1-abc", "/tmp/x"))
        #expect(GuestCopy.split("vm:")! == ("vm", ""))
        #expect(GuestCopy.split(#"win-slot1:C:\Users\admin\x"#)! == ("win-slot1", #"C:\Users\admin\x"#))
        #expect(GuestCopy.split("./a:b") == nil)
        #expect(GuestCopy.split("/tmp/a:b") == nil)
        #expect(GuestCopy.split("plain.txt") == nil)
    }

    @Test func namesAFileOnlyWhenThePathEndsInOne() {
        #expect(GuestCopy.lastComponent(of: "work/app.zip") == "app.zip")
        #expect(GuestCopy.lastComponent(of: #"C:\out\log.txt"#) == "log.txt")
        #expect(GuestCopy.lastComponent(of: "work/") == nil)
        #expect(GuestCopy.lastComponent(of: "") == nil)
        #expect(GuestCopy.lastComponent(of: "..") == nil)
    }

    @Test func refusesWhatTheGuestsShellCantTake() {
        #expect(GuestCopy.problem(with: "a b/it's.txt", windows: false) == nil)
        #expect(GuestCopy.problem(with: "line\nbreak", windows: false) != nil)
        #expect(GuestCopy.problem(with: #"C:\Users\%USERNAME%\x"#, windows: true) != nil)
        #expect(GuestCopy.problem(with: #"C:\a "b""#, windows: true) != nil)
        #expect(GuestCopy.problem(with: #"C:\a b\c.txt"#, windows: true) == nil)
    }

    @Test func writesWindowsPathsWithBackslashes() {
        let script = GuestCopy.moveIn("cp-1", to: "work/app.zip", name: "app.zip", windows: true)
        #expect(script.contains(#""work\app.zip""#))
        #expect(GuestCopy.moveIn("cp-1", to: "", name: "a.txt", windows: true).contains(#"".\a.txt""#))
    }

    /// The POSIX scripts, run in this Mac's sh with a home of their own, as the guest's would be.
    @Test func movesFilesInAndOutAsScpDoes() throws {
        let home = try TemporaryDirectory()
        let staging = home.url.appendingPathComponent("paddock")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent("a folder"), withIntermediateDirectories: true)
        func stage(_ text: String) throws -> String {
            let name = GuestCopy.stagingName()
            try Data(text.utf8).write(to: staging.appendingPathComponent(name))
            return name
        }
        func run(_ script: String) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.environment = ["HOME": home.url.path, "PATH": "/bin:/usr/bin"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        func contents(_ path: String) -> String? {
            (try? Data(contentsOf: home.url.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
        }

        // A file path, a folder takes the file's own name, and "" is the home folder.
        #expect(try run(GuestCopy.moveIn(try stage("one"), to: "it's here.txt", name: "x", windows: false)).0 == 0)
        #expect(contents("it's here.txt") == "one")
        #expect(try run(GuestCopy.moveIn(try stage("two"), to: "a folder", name: "app.zip", windows: false)).0 == 0)
        #expect(contents("a folder/app.zip") == "two")
        #expect(try run(GuestCopy.moveIn(try stage("three"), to: "~", name: "notes.md", windows: false)).0 == 0)
        #expect(contents("notes.md") == "three")
        #expect(try run(GuestCopy.moveIn(try stage("four"), to: "~/a folder/renamed", name: "x", windows: false)).0 == 0)
        #expect(contents("a folder/renamed") == "four")

        // A folder that isn't there fails, and the staged file goes.
        let lost = try stage("five")
        #expect(try run(GuestCopy.moveIn(lost, to: "no such folder/x", name: "x", windows: false)).0 != 0)
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent(lost).path))

        // Out: a file is staged, a folder is refused.
        let out = GuestCopy.stagingName()
        #expect(try run(GuestCopy.stageOut("a folder/app.zip", as: out, windows: false)).0 == 0)
        #expect(contents("paddock/\(out)") == "two")
        #expect(try run(GuestCopy.remove(out, windows: false)).0 == 0)
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent(out).path))
        let (status, output) = try run(GuestCopy.stageOut("a folder", as: GuestCopy.stagingName(), windows: false))
        #expect(status != 0 && output.contains("is a folder"))
    }
}
