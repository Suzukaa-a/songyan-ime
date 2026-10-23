// swift-tools-version: 6.0
//
// AppearanceKit: the combined "appearance project" document (keyboard skin + candidate area layout).
//
// Why this layer exists:
//   - SkinKit only knows skins (colors, fonts, key caps) and CandidateKit only knows candidate
//     layout parameters. Neither depends on the other, which avoids a SkinKit <-> CandidateKit cycle.
//   - Users should reason about a single appearance: picking one decides both the skin and the
//     candidate layout. This package holds both and is the single runtime source of that identity.
//
// Boundaries:
//   - The document is a container of references plus content. It adds no color or font layer:
//     candidate text color and size still derive from the skin (SkinDefinition).
//   - Selection and application commit atomically in one file, so a runtime snapshot can never mix
//     generations (selectedID == document.id == skin.id == candidateBar.id).
import PackageDescription

let package = Package(
    name: "AppearanceKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AppearanceKit", targets: ["AppearanceKit"])
    ],
    dependencies: [
        .package(path: "../SkinKit"),
        .package(path: "../CandidateKit"),
    ],
    targets: [
        .target(name: "AppearanceKit", dependencies: ["SkinKit", "CandidateKit"]),
        .testTarget(
            name: "AppearanceKitTests",
            dependencies: ["AppearanceKit", "SkinKit", "CandidateKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
