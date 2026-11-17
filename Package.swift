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
    ],
    targets: [
        .target(name: "PaddockCore"),
        .executableTarget(
            name: "paddock",
            dependencies: [
                "PaddockCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(name: "paddock-guestd", dependencies: ["PaddockCore"]),
        .executableTarget(name: "paddock-session", dependencies: ["PaddockCore"]),
        .testTarget(name: "PaddockCoreTests", dependencies: ["PaddockCore"]),
    ]
)
