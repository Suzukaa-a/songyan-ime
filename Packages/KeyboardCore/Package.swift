// swift-tools-version: 6.0
//
// KeyboardCore — UI-independent keyboard logic.
//
// Boundaries:
//   - No UIKit/SwiftUI imports, so both HostApp and KeyboardExtension can use it
//     and `swift test` runs on macOS.
//   - Defines only the consumer-side contract (EngineBackend protocol + value types)
//     and a clearly labelled DemoEngine; the real librime engine is supplied by
//     Packages/RimeBridge implementing EngineBackend. Demo candidates are never
//     presented as real ones.
//   - Layouts describe physical keycaps and logical keys only; no schema, dictionary
//     or engine data distribution.

import PackageDescription

let package = Package(
    name: "KeyboardCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "KeyboardCore", targets: ["KeyboardCore"])
    ],
    targets: [
        .target(name: "KeyboardCore"),
        .testTarget(
            name: "KeyboardCoreTests",
            dependencies: ["KeyboardCore"],
            resources: [.process("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
