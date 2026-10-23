// swift-tools-version: 6.0
//
// QuickContentKit: quick-content library (symbol catalog + recents).
//
// Layering contract:
//   - Data and pure logic only: the symbol catalog model (strict JSON v1), catalog
//     import/export storage and the recents store. No dependency on
//     KeyboardCore/SkinKit/UIKit, so the logic tests run on macOS.
//   - Search (Chinese name / pinyin alias / symbol text) lives entirely in this
//     package with its own query buffer; it never writes to the host text proxy,
//     never reaches Rime and never calls the engine.
//   - The default data is a small, original set of common Unicode symbols (names and
//     pinyin aliases written for this repo); no third-party symbol library is bundled.
import PackageDescription

let package = Package(
    name: "QuickContentKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "QuickContentKit", targets: ["QuickContentKit"])
    ],
    targets: [
        .target(name: "QuickContentKit", resources: [.process("Resources")]),
        .testTarget(
            name: "QuickContentKitTests",
            dependencies: ["QuickContentKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
