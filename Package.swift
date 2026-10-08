// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Portside",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.16.0"),
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
            dependencies: ["Portside"]
        )
    ]
)
