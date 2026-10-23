// swift-tools-version: 6.0
//
// SkinKit: skin definitions (colors, fonts, key caps) and the keyboard appearance policy.
import PackageDescription

let package = Package(
    name: "SkinKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SkinKit", targets: ["SkinKit"])
    ],
    targets: [
        .target(name: "SkinKit"),
        .testTarget(
            name: "SkinKitTests",
            dependencies: ["SkinKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
