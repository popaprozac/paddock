import ArgumentParser
import Foundation
import PaddockCore

extension ImageTemplate: ExpressibleByArgument {}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write a starter image file for 'paddock build'.",
        discussion: """
            minimal: the latest macOS with nothing left to click, for your own agents and for you. \
            ci: a pinned macOS plus the tools CI jobs need. managed: for a Mac fleet under MDM, \
            with the privacy grants from an MDM profile. Every template leaves accepting Apple's \
            license to you: uncomment its license line to accept it for the image.
            """)

    @Argument(help: "Image file to write, such as golden.yaml; the VM is named after it.")
    var file: String

    @Option(help: "Template to start from.")
    var template: ImageTemplate = .minimal

    func run() throws {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw PaddockError("\(url.path) already exists")
        }
        try template.text.write(to: url, atomically: true, encoding: .utf8)
        print("Wrote \(url.lastPathComponent) from the \(template.rawValue) template.")
        if template != .minimal {
            print("  Set from.ipsw to the restore image that pins your macOS version.")
        }
        print("  Edit it, then: paddock build \(file)")
    }
}
