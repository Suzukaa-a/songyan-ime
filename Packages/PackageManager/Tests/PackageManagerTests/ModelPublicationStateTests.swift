import XCTest

@testable import PackageManager

final class ModelPublicationStateTests: XCTestCase {
    func testSentenceStatusRequiresCurrentPublicationBeforeAcceptingLoadEvidence() {
        func status(
            _ publication: ModelPublicationState, enabled: Bool = true,
            selection: Bool = true, model: String? = "测试模型", loaded: Bool = true
        ) -> GrammarModelStatus {
            .resolve(
                publication: publication, enabled: enabled, hasSelection: selection,
                modelName: model, loadConfirmed: loaded)
        }
        XCTAssertEqual(status(.notPublished), .inactive)
        XCTAssertEqual(status(.otherSource), .inactive)
        XCTAssertEqual(status(.currentInstallation, enabled: false), .inactive)
        XCTAssertEqual(status(.olderInstallation), .olderVersion)
        XCTAssertEqual(status(.revisionOnly), .unverifiedVersion)
        XCTAssertEqual(status(.currentInstallation, selection: false), .noInputMethod)
        XCTAssertEqual(status(.currentInstallation, model: nil), .disabled)
        XCTAssertEqual(status(.currentInstallation, loaded: false), .awaitingLoad(model: "测试模型"))
        XCTAssertEqual(status(.currentInstallation), .loaded(model: "测试模型"))
        // A valid historical receipt describes a past load, never current process liveness.
        XCTAssertTrue(status(.currentInstallation).message.contains("上次使用键盘时"))
    }

    func testPublicationRequiresSourceRevisionAndHostGeneration() {
        func state(
            _ source: Bool = true, _ revision: String? = "r", _ generation: String? = "published",
            _ host: String? = "installed"
        ) -> ModelPublicationState {
            .resolve(
                sourceMatches: source, installedRevision: "r", installedGeneration: "installed",
                publishedRevision: revision, publishedGeneration: generation, hostGeneration: host)
        }
        XCTAssertEqual(state(), .currentInstallation)
        XCTAssertEqual(state(false), .otherSource)
        XCTAssertEqual(state(true, "old"), .olderInstallation)
        XCTAssertEqual(state(true, "r", "published", "different-install"), .olderInstallation)
        XCTAssertEqual(state(true, "r", "published", nil), .revisionOnly)
        XCTAssertEqual(state(true, nil, nil), .notPublished)
        XCTAssertEqual(state(true, "r", ""), .notPublished)
        // Shared publication generation is deliberately different from host generation.
        XCTAssertEqual(state(true, "r", "another-publication", "installed"), .currentInstallation)
    }
}
