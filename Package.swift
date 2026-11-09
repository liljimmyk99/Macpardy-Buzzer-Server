// swift-tools-version: 6.0
//
//  The phone buzzer (#99), as a package that runs inside the app (built-in
//  server) or as a self-hosted server that a Mac connects to as the host.
//
//  • BuzzerCore           the rules: one room, its phones, buzzes, Final.
//                         Foundation-only so it builds on Linux: no Network,
//                         AppKit, OSLog or CommonCrypto.
//  • BuzzerWebPage        buzzer.html, served by both servers.
//  • BuzzerHostProtocol   the Mac ↔ self-hosted server messages (#103).
//  • BuzzerHub            many rooms, host sessions and the grace period, with
//                         no I/O (#103). Foundation-only.
//  • BuzzerServerNIO      the self-hosted server's HTTP/WebSocket transport
//                         on SwiftNIO (#103).
//  • macpardy-buzzer-server  the executable the Docker image runs.
//

import PackageDescription

let package = Package(
    name: "MacpardyBuzzer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "BuzzerCore", targets: ["BuzzerCore"]),
        .library(name: "BuzzerWebPage", targets: ["BuzzerWebPage"]),
        .library(name: "BuzzerHostProtocol", targets: ["BuzzerHostProtocol"]),
        .executable(name: "macpardy-buzzer-server", targets: ["MacpardyBuzzerServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(name: "BuzzerCore"),
        .target(name: "BuzzerWebPage", resources: [.copy("Resources/buzzer.html")]),
        .target(name: "BuzzerHostProtocol", dependencies: ["BuzzerCore"]),
        .target(name: "BuzzerHub", dependencies: ["BuzzerCore", "BuzzerHostProtocol"]),
        .target(
            name: "BuzzerServerNIO",
            dependencies: [
                "BuzzerCore",
                "BuzzerHub",
                "BuzzerWebPage",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "MacpardyBuzzerServer",
            dependencies: ["BuzzerHub", "BuzzerServerNIO"]
        ),
        .testTarget(name: "BuzzerCoreTests", dependencies: ["BuzzerCore", "BuzzerWebPage"]),
        .testTarget(name: "BuzzerHostProtocolTests", dependencies: ["BuzzerHostProtocol"]),
        .testTarget(name: "BuzzerHubTests", dependencies: ["BuzzerHub", "BuzzerHostProtocol", "BuzzerCore"]),
        .testTarget(
            name: "BuzzerServerNIOTests",
            dependencies: [
                "BuzzerServerNIO",
                "BuzzerHub",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
    ]
)
