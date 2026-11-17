import ArgumentParser
import Foundation
import PaddockCore

struct Clone: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make a copy-on-write clone of a VM with a fresh machine identifier and MAC address.",
        discussion: """
            The clone shares disk blocks with the source until either one writes, so it is fast \
            and nearly free. Both must be on the same APFS volume. A running VM can't be cloned.
            """)

    @Argument(help: "VM to clone, usually the golden image.")
    var source: String

    @Argument(help: "Name of the new VM.")
    var name: String

    func validate() throws {
        try BundleName.validate(source)
        try BundleName.validate(name)
    }

    func run() throws {
        let home = PaddockHome.fromEnvironment()
        let started = ContinuousClock.now
        let config = try VMClone.clone(try home.bundle(named: source), to: try home.bundle(named: name))
        let elapsed = ContinuousClock.now - started
        print("Cloned '\(source)' to '\(name)' in \(DurationFormat.short(elapsed)) (MAC \(config.macAddress))")
    }
}
