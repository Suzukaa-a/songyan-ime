import Foundation
import XCTest

@testable import KeyboardCore

@MainActor
final class InputSessionPublicationTests: XCTestCase {
    func testSchemaReconciliationPreservesExactPublicationAndAuxiliaryRoute() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("input-session-publication-\(UUID().uuidString)")
        let build = root.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for schema in ["source", "english_aux"] {
            try Data().write(to: build.appendingPathComponent("\(schema).schema.yaml"))
        }

        let owner = PublishedKeyboard(schemaID: "source", layout: .qwerty26)
        let route = EnglishCandidateRoute(owner: owner, candidateSchemaID: "english_aux")
        let resource = KeyboardResourceSet(
            id: "published", name: "Source", sharedDirectory: root, userDirectory: root,
            layoutEntries: [], prebuiltDirectory: build,
            schemas: [
                KeyboardSchemaDescriptor(id: "source", name: "Source", alphabet: "abcdefghijklmnopqrstuvwxyz"),
                KeyboardSchemaDescriptor(id: "english_aux", name: "English", alphabet: "abcdefghijklmnopqrstuvwxyz"),
            ], selectedSchemaID: "source", publicationGeneration: "generation-1",
            publishedKeyboards: [owner], englishCandidateRoutes: [route])
        let engine = DemoEngine()
        try engine.setup(sharedDirectory: root, userDirectory: root)

        let session = InputSession(engine: engine, layout: .qwerty26, resourceSet: resource)
        let resolved = try XCTUnwrap(session.resourceSet)
        XCTAssertEqual(resolved.publicationGeneration, "generation-1")
        XCTAssertEqual(resolved.publishedKeyboards, [owner])
        XCTAssertEqual(resolved.englishCandidateRoutes, [route])
        XCTAssertEqual(
            resolved.availableCombinations.map(\.id), [owner.id],
            "Session must not recreate unpublished 26-key combinations")
        XCTAssertEqual(
            resolved.inputSchemeChoices.map(\.id), ["source"],
            "Auxiliary candidate schema is not a user keyboard")
        XCTAssertEqual(resolved.runnableEnglishCandidateRoutes(forPublished: [owner]), [route])
    }

    func testExplicitEmptyPublicationStaysEmptyAfterSchemaReconciliation() throws {
        let root = FileManager.default.temporaryDirectory
        let resource = KeyboardResourceSet(
            id: "empty", name: "Source", sharedDirectory: root, userDirectory: root,
            layoutEntries: [],
            schemas: [
                KeyboardSchemaDescriptor(
                    id: "source", name: "Source", alphabet: "abcdefghijklmnopqrstuvwxyz")
            ],
            selectedSchemaID: "source", publishedKeyboards: [])
        let engine = DemoEngine()
        try engine.setup(sharedDirectory: root, userDirectory: root)

        let resolved = try XCTUnwrap(
            InputSession(
                engine: engine, layout: .qwerty26,
                resourceSet: resource
            ).resourceSet)
        XCTAssertEqual(resolved.publishedKeyboards, [])
        XCTAssertTrue(resolved.availableCombinations.isEmpty)
    }
}
