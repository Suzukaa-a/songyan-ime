// swift-tools-version: 6.0
//
// CandidateKit: candidate area configuration and rendering contract (the third user-customizable
// layer besides layout keys and skins).
//
// Layering:
//   - LayoutKit: layout key actions.
//   - SkinKit: skins, including candidate text size and color.
//   - CandidateKit: candidate area presentation config (composition row visibility/position,
//     collapsed strip, expanded list/grid, rows/columns/spacing, comment display, paging/expand
//     control placement) plus a render-agnostic presentation model and action interface.
//
// Boundaries:
//   - Config only describes presentation. Candidate data always comes from real EngineSnapshot
//     candidates (candidate.index forwarded as-is); fake candidates and commit overrides are not
//     configurable.
//   - Depends on KeyboardCore (the Candidate value type), not on SkinKit or UIKit rendering.
//     Colors and fonts are injected through CandidateAreaEnvironment, so there is no third skin.
//   - Renderers are a source-level extension point (registered at compile time); user JSON can only
//     choose parameters within the schema.
import PackageDescription

let package = Package(
    name: "CandidateKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "CandidateKit", targets: ["CandidateKit"])
    ],
    dependencies: [
        .package(path: "../KeyboardCore"),
        // LayoutKit is the single provider of the content-level runtime identity
        // (`LayoutRuntimeIdentity`) and its observation coordinator; candidate/ambiguity transaction
        // snapshots must use the same identity type to avoid string collisions.
        .package(path: "../LayoutKit"),
    ],
    targets: [
        .target(name: "CandidateKit", dependencies: ["KeyboardCore", "LayoutKit"]),
        .testTarget(
            name: "CandidateKitTests",
            dependencies: ["CandidateKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
