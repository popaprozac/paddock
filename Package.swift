// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "paddock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "paddock", targets: ["paddock"]),
        .executable(name: "paddock-guestd", targets: ["paddock-guestd"]),
        .executable(name: "paddock-session", targets: ["paddock-session"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // The official MCP SDK, for `paddock mcp`. Pinned exactly: it is pre-1.0 and changes its API.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        // Reads image files for `paddock build`. PaddockCore decodes them with any Decoder, so the
        // guest binaries, which link PaddockCore, don't carry a YAML parser.
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
    ],
    targets: [
        .target(name: "PaddockCore"),
        .executableTarget(
            name: "paddock",
            dependencies: [
                "PaddockCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(name: "paddock-guestd", dependencies: ["PaddockCore"]),
        .executableTarget(name: "paddock-session", dependencies: ["PaddockCore"]),
        .testTarget(name: "PaddockCoreTests", dependencies: ["PaddockCore", .product(name: "Yams", package: "Yams")]),
        .testTarget(name: "PaddockTests", dependencies: ["paddock"]),
    ]
)
