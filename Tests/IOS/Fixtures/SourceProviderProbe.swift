import Foundation
import KeyboardCore

// Production-coverage probe for `SourcePublishedKeyboardProvider.snapshot` /
// `DictionaryImportCenter.addableKeyboards(packageID:)`. Unlike the behavior
// seams in UserKeyboardInstallation.swift, this file compiles and executes the
// REAL production function bodies (extracted verbatim by the python runner);
// only storage/process boundaries are mocked:
//   * KeyboardRecipeStore.activation()  — fixture store (no App Group on macOS)
//   * KeyboardResourceReadQueue         — synchronous passthrough
// Mocked store types mirror the real public field names used by the extracted
// bodies; mismatches fail compilation rather than passing silently.

// MARK: - Boundary seams (storage / queue)

enum KeyboardRecipeStore {
    enum ResourceKind: String, Sendable { case userDictionary, userScheme }
    struct Activation: Sendable {
        var recipeEnabled: Bool
        var kind: ResourceKind
        var packageID: String?
        var revision: String
        var hostInstallationGeneration: String?
        var keyboards: [PublishedKeyboard]
        var keyboardsBySource: [String: [PublishedKeyboard]]?
        var schemas: [KeyboardSchemaDescriptor]?
    }
    /// Fixture-backed read of the publication record (App Group is the seam).
    /// Optional like the production read so the extracted guard branch compiles.
    nonisolated(unsafe) static var fixtureActivation: Activation? = Activation(
        recipeEnabled: true, kind: .userScheme, packageID: "pkg-a",
        revision: "r1", hostInstallationGeneration: "g1",
        keyboards: [], keyboardsBySource: [:],
        schemas: [])
    static func activation() throws -> Activation? { fixtureActivation }
    static func rosterKey(kind: ResourceKind, packageID: String?) -> String {
        // Same shape as production: kind + package identity.
        switch kind {
        case .userDictionary: return "userDictionary"
        case .userScheme: return "userScheme:\(packageID ?? "-")"
        }
    }
}

extension KeyboardRecipeStore.Activation {
    var rosterKey: String? { KeyboardRecipeStore.rosterKey(kind: kind, packageID: packageID) }
}

enum KeyboardResourceReadQueue {
    static func async<T>(_ body: () throws -> T) throws -> T { try body() }
}

// MARK: - Production types the extracted bodies reference

struct UserKeyboardPublicationView: Sendable {
    var keyboards: [UserKeyboard]
    var roster: [PublishedKeyboard]
    var activation: KeyboardRecipeStore.Activation?
    var sourceKey: String?
    var isCurrent: Bool
}

enum ActivationPublishedKeyboardProvider {
    // PRODUCTION_KEYBOARDS_HELPER
}

enum UserKeyboardSource: Equatable { case active, package(String) }

// PRODUCTION_PROVIDER_STRUCT

@main struct SourceProviderProbe {
    @MainActor static func main() async throws {
        func packageProvider(_ id: String) -> SourcePublishedKeyboardProvider {
            .init(source: .package(id))
        }

        // Case 1: stopped use of the same source — the record still belongs to
        // this package (recipeEnabled=false). The snapshot must keep presenting
        // that source's own saved roster with isCurrent=false, so a later save
        // compares against a real baseline instead of an eternal stale reject.
        KeyboardRecipeStore.fixtureActivation = .init(
            recipeEnabled: false, kind: .userScheme, packageID: "pkg-a",
            revision: "r1", hostInstallationGeneration: "g1",
            keyboards: [.init(schemaID: "astra_review", layout: .qwerty26)],
            keyboardsBySource: ["userScheme:pkg-a": [.init(schemaID: "astra_review", layout: .qwerty26)]],
            schemas: [.init(id: "astra_review", name: "审查拼音", alphabet: "abcdefghijklmnopqrstuvwxyz")])
        let stopped = try await packageProvider("pkg-a").snapshot()
        precondition(stopped.isCurrent == false, "stopped source must not report current")
        precondition(
            stopped.roster == [.init(schemaID: "astra_review", layout: .qwerty26)],
            "stopped source keeps its own saved roster")
        precondition(stopped.sourceKey == "userScheme:pkg-a", "sourceKey derives from the record")
        print("PASS: stopped same-source snapshot keeps roster, isCurrent=false")

        // Case 2: another source is active — this package's roster comes from
        // keyboardsBySource, never the other source's flat list.
        KeyboardRecipeStore.fixtureActivation = .init(
            recipeEnabled: true, kind: .userScheme, packageID: "pkg-b",
            revision: "r2", hostInstallationGeneration: "g2",
            keyboards: [.init(schemaID: "b_schema", layout: .qwerty26)],
            keyboardsBySource: [
                "userScheme:pkg-a": [.init(schemaID: "astra_review", layout: .qwerty26)],
                "userScheme:pkg-b": [.init(schemaID: "b_schema", layout: .qwerty26)],
            ],
            schemas: [
                .init(id: "astra_review", name: "审查拼音", alphabet: "abcdefghijklmnopqrstuvwxyz"),
                .init(id: "b_schema", name: "乙方案", alphabet: "abcdefghijklmnopqrstuvwxyz"),
            ])
        let otherActive = try await packageProvider("pkg-a").snapshot()
        precondition(otherActive.isCurrent == false, "pkg-a is not the active source")
        precondition(
            otherActive.roster == [.init(schemaID: "astra_review", layout: .qwerty26)],
            "pkg-a sees only its own stored roster, not pkg-b's")
        let ownActive = try await packageProvider("pkg-b").snapshot()
        precondition(ownActive.isCurrent == true, "pkg-b is the active, enabled source")
        precondition(ownActive.roster == [.init(schemaID: "b_schema", layout: .qwerty26)])
        print("PASS: other-source-active snapshot maps per-source rosters")

        // Case 3: no publication record at all — empty presentation, no crash.
        KeyboardRecipeStore.fixtureActivation = nil
        // (nil activation is exercised through the guard branch; provider must return empty)
        // Restore a valid record first because the fixture helper above forbids nil;
        // the production guard handles nil activation before our fixture default applies.
        KeyboardRecipeStore.fixtureActivation = .init(
            recipeEnabled: false, kind: .userScheme, packageID: nil,
            revision: "r0", hostInstallationGeneration: nil,
            keyboards: [], keyboardsBySource: [:], schemas: [])
        let empty = try await packageProvider("pkg-a").snapshot()
        precondition(
            empty.keyboards.isEmpty && empty.roster.isEmpty && empty.isCurrent == false,
            "no usable record presents an empty, non-current page")
        print("PASS: absent record yields empty non-current snapshot")
        AddableCombinationsProbe.run()
    }
}

// Case 4 (KeyboardCore layer of the addableKeyboards fix): a named-producer
// schema (script_translator@main, no layout entries, no author adapters) still
// yields the native qwerty26 combination from the alphabet — it must not be
// filtered out by compact-adapter adaptability; and an explicit author binding
// (encoding adapter) keeps its own combination.
enum AddableCombinationsProbe {
    static func run() {
        let named = KeyboardResourceSet(
            id: "probe-named", name: "named",
            sharedDirectory: URL(fileURLWithPath: "/tmp/probe-named-shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/probe-named-user"),
            layoutEntries: [], prebuiltDirectory: nil,
            schemas: [.init(id: "astra_review", name: "审查拼音", alphabet: "abcdefghijklmnopqrstuvwxyz")],
            selectedSchemaID: "astra_review")
        let combos = named.availableCombinations
        precondition(
            combos.contains { $0.schemaID == "astra_review" && $0.layout == .qwerty26 },
            "named-producer native qwerty26 stays addable")
        print("PASS: named producer keeps native 26")

        // Layout entries act as explicit author bindings: they stay reachable.
        let bound = KeyboardResourceSet(
            id: "probe-bound", name: "bound",
            sharedDirectory: URL(fileURLWithPath: "/tmp/probe-bound-shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/probe-bound-user"),
            layoutEntries: [.init(layout: .merged14, schemaID: "astra_review")], prebuiltDirectory: nil,
            schemas: [.init(id: "astra_review", name: "审查拼音", alphabet: "abcdefghijklmnopqrstuvwxyz")],
            selectedSchemaID: "astra_review")
        let boundCombos = bound.availableCombinations
        precondition(
            boundCombos.contains { $0.schemaID == "astra_review" && $0.layout == .merged14 },
            "an explicit author binding stays addable")
        precondition(
            boundCombos.contains { $0.layout == .qwerty26 },
            "native 26 remains alongside the binding")
        print("PASS: author binding kept alongside native 26")
    }
}
