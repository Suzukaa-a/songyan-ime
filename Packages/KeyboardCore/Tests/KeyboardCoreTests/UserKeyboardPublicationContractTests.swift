import XCTest
import os

@testable import KeyboardCore

/// Cross-module contract tests: publication-source provenance, delete prune, and
/// the interface semantics of `UserKeyboardPublicationTransaction` (failure propagates unchanged / success is structured).
final class UserKeyboardPublicationContractTests: XCTestCase {

    // MARK: - provenance: kind + packageID structurally distinguish the same schema from different sources

    func testSourceIdentityDistinguishesSameSchemaAcrossSources() {
        let a = KeyboardPublicationSource(resourceKind: "userScheme", packageID: "pkg-a")
        let b = KeyboardPublicationSource(resourceKind: "userScheme", packageID: "pkg-b")
        XCTAssertEqual(a, .userScheme(packageID: "pkg-a"))
        XCTAssertEqual(b, .userScheme(packageID: "pkg-b"))
        XCTAssertNotEqual(a, b, "different sources of the same schema must be distinguishable")
        XCTAssertEqual(a?.packageID, "pkg-a")
        XCTAssertTrue(a?.isUserScheme == true)
        XCTAssertNil(KeyboardPublicationSource(resourceKind: "rimeIce", packageID: nil))
        XCTAssertEqual(KeyboardPublicationSource(resourceKind: "userDictionary", packageID: nil), .userDictionary)
        // userScheme missing package identity -> invalid identity (fail closed).
        XCTAssertNil(KeyboardPublicationSource(resourceKind: "userScheme", packageID: nil))
        XCTAssertNil(KeyboardPublicationSource(resourceKind: "userScheme", packageID: ""))
        XCTAssertNil(KeyboardPublicationSource(resourceKind: "bogus", packageID: "x"))
    }

    // MARK: - prune: delete from the same source, keep other sources

    func testPruneRemovesOnlySameSourceSchemas() {
        let shared = PublishedKeyboard(schemaID: "double_pinyin", layout: .merged14)
        let other = PublishedKeyboard(schemaID: "wubi", layout: .merged14)
        let same = PublishedKeyboard(schemaID: "double_pinyin", layout: .phone9)
        let published = [shared, other, same]

        let result = PublishedKeyboardPrune.retained(
            published: published,
            publicationSource: .userScheme(packageID: "pkg-a"),
            deletingSource: .userScheme(packageID: "pkg-a"),
            deletedSchemaIDs: ["double_pinyin"])
        XCTAssertEqual(result.retained, [other])
        XCTAssertEqual(result.removed, [shared, same])
        XCTAssertTrue(result.didChange)
    }

    func testPruneKeepsAllWhenPublicationBelongsToAnotherSource() {
        // Another source happens to provide a schema of the same name: never delete by schema string.
        let published = [PublishedKeyboard(schemaID: "double_pinyin", layout: .merged14)]
        let result = PublishedKeyboardPrune.retained(
            published: published,
            publicationSource: .userScheme(packageID: "pkg-b"),
            deletingSource: .userScheme(packageID: "pkg-a"),
            deletedSchemaIDs: ["double_pinyin"])
        XCTAssertEqual(result.retained, published)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertFalse(result.didChange)
    }

    // MARK: - Delete admission policy (same rule as the UI "in use")

    func testDeletionPolicyOnlyRefusesWhenEnabledAndSourceMatches() {
        XCTAssertEqual(
            InstalledSourceDeletionPolicy.decision(
                recipeEnabled: true,
                publicationSource: .userScheme(packageID: "pkg-a"),
                deletingPackageID: "pkg-a"), .refusedInUse)
        XCTAssertEqual(
            InstalledSourceDeletionPolicy.decision(
                recipeEnabled: false,
                publicationSource: .userScheme(packageID: "pkg-a"),
                deletingPackageID: "pkg-a"), .allowed)
        XCTAssertEqual(
            InstalledSourceDeletionPolicy.decision(
                recipeEnabled: true,
                publicationSource: .userScheme(packageID: "pkg-b"),
                deletingPackageID: "pkg-a"), .allowed)
    }

    // MARK: - Transaction interface semantics (verify the protocol shape with a fake implementation)

    private final class Store: Sendable {
        private let state: OSAllocatedUnfairLock<(list: [PublishedKeyboard], replacements: Int)>
        init(_ list: [PublishedKeyboard] = []) { state = OSAllocatedUnfairLock(initialState: (list, 0)) }
        func snapshot() -> [PublishedKeyboard] { state.withLock { $0.list } }
        func replacements() -> Int { state.withLock { $0.replacements } }
        func add(_ k: PublishedKeyboard) {
            state.withLock { if !$0.list.contains(k) { $0.list.append(k) } }
        }
        func replace(with keyboards: [PublishedKeyboard]) {
            state.withLock {
                $0.replacements += 1
                $0.list = keyboards
            }
        }
    }

    private struct FakeTransaction: UserKeyboardPublicationTransaction {
        let store: Store
        let failAdd: Bool
        var failReplace = false

        func addKeyboard(_ keyboard: PublishedKeyboard) async throws -> UserKeyboardMutationOutcome {
            if failAdd { throw UserKeyboardPublicationError.unavailable("generation failed") }
            store.add(keyboard)
            return UserKeyboardMutationOutcome(
                keyboard: keyboard, added: true,
                publishedKeyboards: store.snapshot())
        }
        func removeKeyboard(_ keyboard: PublishedKeyboard) async throws -> UserKeyboardMutationOutcome {
            throw UserKeyboardPublicationError.notAdded
        }
        func replaceKeyboards(_ keyboards: [PublishedKeyboard]) async throws -> [PublishedKeyboard] {
            if failReplace { throw UserKeyboardPublicationError.unavailable("validation failed") }
            store.replace(with: keyboards)
            return store.snapshot()
        }
        func publishedKeyboards() async throws -> [PublishedKeyboard] { store.snapshot() }
        func addableKeyboards() async throws -> [PublishedKeyboard] {
            [PublishedKeyboard(schemaID: "generic", layout: .merged14)]
        }
    }

    func testTransactionReportsFailureAndDoesNotReportSuccess() async throws {
        let store = Store()
        let tx = FakeTransaction(store: store, failAdd: true)
        do {
            _ = try await tx.addKeyboard(PublishedKeyboard(schemaID: "generic", layout: .merged14))
            XCTFail("a failure must throw and never return success")
        } catch {
            XCTAssertEqual(error as? UserKeyboardPublicationError, .unavailable("generation failed"))
        }
        let published = try await tx.publishedKeyboards()
        XCTAssertEqual(published, [], "a failed add must not change the published roster")
    }

    func testTransactionSuccessReturnsStructuredOutcome() async throws {
        let store = Store()
        let tx = FakeTransaction(store: store, failAdd: false)
        let keyboard = PublishedKeyboard(schemaID: "generic", layout: .merged14)
        let outcome = try await tx.addKeyboard(keyboard)
        XCTAssertTrue(outcome.added)
        XCTAssertEqual(outcome.keyboard, keyboard)
        XCTAssertEqual(outcome.publishedKeyboards, [keyboard])
    }

    func testReplacePublishesTheCompleteRosterExactlyOnce() async throws {
        let original = PublishedKeyboard(schemaID: "old", layout: .qwerty26)
        let expected = [
            PublishedKeyboard(schemaID: "alpha", layout: .qwerty26),
            PublishedKeyboard(schemaID: "alpha", layout: .merged14),
            PublishedKeyboard(schemaID: "beta", layout: .phone9),
        ]
        let store = Store([original])
        let tx = FakeTransaction(store: store, failAdd: false)

        let result = try await tx.replaceKeyboards(expected)

        XCTAssertEqual(result, expected)
        XCTAssertEqual(store.snapshot(), expected, "the full set submitted by the caller must be published")
        XCTAssertEqual(store.replacements(), 1, "one save may perform only one full replacement")
    }

    func testReplaceValidationFailureLeavesPublishedRosterUntouched() async throws {
        let original = [PublishedKeyboard(schemaID: "stable", layout: .qwerty26)]
        let store = Store(original)
        let tx = FakeTransaction(store: store, failAdd: false, failReplace: true)

        do {
            _ = try await tx.replaceKeyboards([
                PublishedKeyboard(schemaID: "new", layout: .merged14),
                PublishedKeyboard(schemaID: "new", layout: .phone9),
            ])
            XCTFail("a validation failure must throw")
        } catch {
            XCTAssertEqual(
                error as? UserKeyboardPublicationError,
                .unavailable("validation failed"))
        }
        XCTAssertEqual(store.snapshot(), original, "a failure must not change the existing published set")
        XCTAssertEqual(store.replacements(), 0, "a validation failure must not publish")
    }
}
