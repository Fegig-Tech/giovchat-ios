// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GiovChat",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GiovChatCore", targets: ["GiovChatCore"]),
        .library(name: "GiovChat", targets: ["GiovChat"]),
    ],
    targets: [
        .target(
            name: "GiovChatCore",
            path: "Sources/GiovChatCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "GiovChat",
            dependencies: ["GiovChatCore"],
            path: "Sources/GiovChat",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GiovChatCoreTests",
            dependencies: ["GiovChatCore"],
            path: "Tests/GiovChatCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GiovChatTests",
            dependencies: ["GiovChat", "GiovChatCore"],
            path: "Tests/GiovChatTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
