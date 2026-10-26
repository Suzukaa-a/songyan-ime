// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LayoutKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "LayoutKit", targets: ["LayoutKit"])],
    targets: [
        .target(name: "LayoutKit"),
        .testTarget(name: "LayoutKitTests", dependencies: ["LayoutKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
