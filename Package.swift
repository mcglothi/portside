// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Portside",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Held to 1.20.x on purpose. 1.20 is the last release with the API
        // Portside uses (getTerminal, direct buffer access); 1.99 is SwiftTerm
        // v2, which moves parsing off the main thread and only exposes state
        // through snapshots, and needs a planned migration. A plain `from:`
        // would let a routine package update pull it in.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", "1.20.0"..<"1.21.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Portside",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [.process("Resources")]
        ),
        // The `portside` command an agent (or a person) drives the running app
        // with. Shares no code with the app on purpose: it only speaks the
        // socket protocol, so it stays tiny and can't drift into doing work
        // the app's checks don't see.
        .executableTarget(
            name: "portside-cli",
            path: "Sources/PortsideCLI"
        ),
        .testTarget(
            name: "PortsideTests",
            // portside-cli too, so `swift test` builds the binary that
            // MCPServerTests runs as a real process.
            dependencies: ["Portside", "portside-cli"]
        )
    ]
)
