// swift-tools-version: 6.0
//
//  The phone buzzer, as a package that can run inside the app or, later, on a
//  self-hosted server (#99). `BuzzerCore` is Foundation-only so it builds on
//  Linux: no Network, AppKit, OSLog or CommonCrypto.
//

import PackageDescription

let package = Package(
    name: "MacpardyBuzzer",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "BuzzerCore", targets: ["BuzzerCore"]),
    ],
    targets: [
        .target(name: "BuzzerCore"),
        .testTarget(name: "BuzzerCoreTests", dependencies: ["BuzzerCore"]),
    ]
)
