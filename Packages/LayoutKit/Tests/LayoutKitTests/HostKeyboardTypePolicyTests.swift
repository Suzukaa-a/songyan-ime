import XCTest

@testable import LayoutKit

/// `HostKeyboardTypePolicy` classification matrix: ASCII/numeric fields use half-width punctuation, ordinary text uses Chinese punctuation.
final class HostKeyboardTypePolicyTests: XCTestCase {
    /// The three newly classified kinds must be ASCII.
    func testNewlyClassifiedTypesRequireASCII() {
        XCTAssertTrue(HostKeyboardTypePolicy.requiresASCIIPunctuation(.asciiCapable))
        XCTAssertTrue(HostKeyboardTypePolicy.requiresASCIIPunctuation(.numbersAndPunctuation))
        XCTAssertTrue(HostKeyboardTypePolicy.requiresASCIIPunctuation(.numberPad))
    }

    func testASCIIAndNumericFieldsRequireASCII() {
        let ascii: [HostKeyboardTypeKind] = [
            .asciiCapable, .numbersAndPunctuation, .url,
            .emailAddress, .numberPad, .decimalPad,
            .asciiCapableNumberPad, .phonePad, .namePhonePad,
        ]
        for kind in ascii {
            XCTAssertTrue(HostKeyboardTypePolicy.requiresASCIIPunctuation(kind), "\(kind) should be ASCII")
        }
    }

    func testProseFieldsKeepChinesePunctuation() {
        for kind in [HostKeyboardTypeKind.unspecified, .other, .twitter, .webSearch] {
            XCTAssertFalse(HostKeyboardTypePolicy.requiresASCIIPunctuation(kind), "\(kind) should not be ASCII")
        }
    }

    /// Every case must be classified explicitly (none may fall into an undefined branch).
    func testClassificationIsTotal() {
        XCTAssertEqual(HostKeyboardTypeKind.allCases.count, 13)
        for kind in HostKeyboardTypeKind.allCases {
            _ = HostKeyboardTypePolicy.requiresASCIIPunctuation(kind)
            _ = HostKeyboardTypePolicy.preferredInput(kind)
        }
    }

    func testPreferredInputFollowsHostFieldWithoutClassifyingPlainText() {
        for kind in [
            HostKeyboardTypeKind.url, .emailAddress, .asciiCapable,
            .namePhonePad,
        ] {
            XCTAssertEqual(HostKeyboardTypePolicy.preferredInput(kind), .english)
        }
        for kind in [
            HostKeyboardTypeKind.numberPad, .decimalPad,
            .asciiCapableNumberPad, .phonePad, .numbersAndPunctuation,
        ] {
            XCTAssertEqual(HostKeyboardTypePolicy.preferredInput(kind), .numeric)
        }
        XCTAssertEqual(HostKeyboardTypePolicy.preferredInput(.unspecified), .unchanged)
        XCTAssertEqual(HostKeyboardTypePolicy.preferredInput(.other), .unchanged)
        XCTAssertEqual(HostKeyboardTypePolicy.preferredInput(.webSearch), .unchanged)
        XCTAssertEqual(HostKeyboardTypePolicy.preferredInput(.twitter), .unchanged)
    }

    func testCapitalizationRequiresKnownCursorContextExceptAllCharacters() {
        let policy = HostKeyboardTypePolicy.self
        XCTAssertFalse(policy.shouldCapitalize(.sentences, beforeCursor: nil, kind: .unspecified))
        XCTAssertTrue(policy.shouldCapitalize(.sentences, beforeCursor: "", kind: .unspecified))
        XCTAssertTrue(policy.shouldCapitalize(.sentences, beforeCursor: "Done. ", kind: .unspecified))
        XCTAssertTrue(policy.shouldCapitalize(.sentences, beforeCursor: "Done!\n", kind: .unspecified))
        XCTAssertFalse(policy.shouldCapitalize(.sentences, beforeCursor: "Done. x", kind: .unspecified))
        XCTAssertFalse(policy.shouldCapitalize(.sentences, beforeCursor: "a. b", kind: .unspecified))
        XCTAssertTrue(policy.shouldCapitalize(.words, beforeCursor: "hello ", kind: .unspecified))
        XCTAssertFalse(policy.shouldCapitalize(.words, beforeCursor: "hello", kind: .unspecified))
        XCTAssertTrue(policy.shouldCapitalize(.allCharacters, beforeCursor: nil, kind: .unspecified))
        XCTAssertFalse(policy.shouldCapitalize(.allCharacters, beforeCursor: "", kind: .numberPad))
        XCTAssertFalse(policy.shouldCapitalize(.sentences, beforeCursor: "", kind: .url))
        XCTAssertFalse(policy.shouldCapitalize(.words, beforeCursor: "", kind: .emailAddress))
    }

    func testEmptySearchReturnRequiresProvenDocumentState() {
        let policy = HostKeyboardTypePolicy.self
        XCTAssertFalse(policy.returnEnabled(isSearch: true, enablesAutomatically: true, documentIsEmpty: true))
        XCTAssertFalse(policy.returnEnabled(isSearch: true, enablesAutomatically: false, documentIsEmpty: true))
        XCTAssertTrue(policy.returnEnabled(isSearch: true, enablesAutomatically: true, documentIsEmpty: nil))
        XCTAssertTrue(policy.returnEnabled(isSearch: true, enablesAutomatically: true, documentIsEmpty: false))
        XCTAssertTrue(policy.returnEnabled(isSearch: false, enablesAutomatically: true, documentIsEmpty: nil))
        XCTAssertFalse(policy.returnEnabled(isSearch: false, enablesAutomatically: true, documentIsEmpty: true))
        XCTAssertTrue(policy.returnEnabled(isSearch: false, enablesAutomatically: true, documentIsEmpty: false))
        XCTAssertTrue(policy.returnEnabled(isSearch: false, enablesAutomatically: false, documentIsEmpty: true))
    }
}
