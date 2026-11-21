import ArgumentParser
import Foundation
import PaddockCore

extension ImageTemplate: ExpressibleByArgument {}

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write a starter image file for 'paddock build'.",
        discussion: """
            minimal: the latest macOS with nothing left to click, for your own agents and for you. \
            ci: a pinned macOS plus the Command Line Tools, for git and the compilers. managed: a pinned macOS, with a person \
            making the privacy grants in the image, so paddock never writes the privacy database. \
            debian: Debian 13 with no screen, for Linux CI and agents. debian-desktop: Debian 13 with \
            Xfce, for agents and people that use its screen. ubuntu: Ubuntu 26.04 LTS with no screen. \
            Templates are starting points: any file can take any setting. Every macOS template leaves \
            accepting Apple's license to you: uncomment its license line to accept it for the image.
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
        if template == .ci || template == .managed {
            print("  Set from.ipsw to the restore image that pins your macOS version.")
        }
        print("  Edit it, then: paddock build \(file)")
    }
}
