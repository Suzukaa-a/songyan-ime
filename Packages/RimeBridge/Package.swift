// swift-tools-version: 6.0
//
// RimeBridge — thin Swift wrapper over the vendored RimeKit XCFramework
// (static librime 1.17.0 + the rb_* C bridge), including its API contract and
// concurrency model.
//
// The prebuilt XCFramework is committed under Vendored/, so app builds need no
// engine toolchain. To rebuild it, run
// Tools/BuildRimeIOS/scripts/43-build-rimekit.py, then install it with
// Tools/BuildRimeIOS/scripts/export-rimekit.py, which records the slice
// checksums in Packages/RimeBridge/RimeKitArtifact.json.

import PackageDescription

let package = Package(
    name: "RimeBridge",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "RimeBridge", targets: ["RimeBridge"])
    ],
    targets: [
        // Vendored engine + thin C bridge. The XCFramework contains static
        // librime for arm64 iOS Simulator and arm64 device.
        .binaryTarget(
            name: "RimeKit",
            path: "Vendored/RimeKit.xcframework"
        ),
        .target(
            name: "RimeLeversSupport",
            dependencies: ["RimeKit"],
            // The shipped umbrella flips Bool before including levers. Compile the
            // adapter with original public headers, not the flavored Clang module.
            cSettings: [.unsafeFlags(["-fno-modules"])]
        ),
        .target(
            name: "RimeBridge",
            dependencies: ["RimeKit", "RimeLeversSupport"]
        ),
        .testTarget(
            name: "RimeBridgeTests",
            dependencies: ["RimeBridge"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
