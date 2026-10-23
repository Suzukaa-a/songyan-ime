import XCTest

@testable import KeyboardCore

final class KeyboardBootClassificationTests: XCTestCase {

    func testReadyEngineAtEntryIsWarmReuse() {
        for everReady in [true, false] {
            XCTAssertEqual(
                KeyboardBootClassification(
                    hadReadyEngineAtEntry: true,
                    processHasEverBeenReady: everReady),
                .warmReuse,
                "entering this appearance with a ready engine = warm resume (never boot)")
        }
        XCTAssertFalse(KeyboardBootClassification.warmReuse.isCold)
    }

    func testNoReadyEngineIsColdAndDistinguishesFirstBoot() {
        XCTAssertEqual(
            KeyboardBootClassification(
                hadReadyEngineAtEntry: false,
                processHasEverBeenReady: false),
            .coldFirstBoot,
            "the first engine established in the process = a true cold start")
        XCTAssertEqual(
            KeyboardBootClassification(
                hadReadyEngineAtEntry: false,
                processHasEverBeenReady: true),
            .coldRebootInProcess,
            "the process had a ready engine before and has none now = a re-boot within the process (still not a warm resume)"
        )
        XCTAssertTrue(KeyboardBootClassification.coldFirstBoot.isCold)
        XCTAssertTrue(KeyboardBootClassification.coldRebootInProcess.isCold)
    }

    /// The classification is pure-value: the same input is always equal, and the three classes are mutually unequal (never both called "resume").
    func testClassificationIsDeterministicAndDistinct() {
        let kinds: [KeyboardBootClassification] = [.warmReuse, .coldRebootInProcess, .coldFirstBoot]
        XCTAssertEqual(
            Set(kinds.map(\.rawValue)).count, kinds.count,
            "the three diagnostic labels must be mutually distinct")
        for kind in kinds {
            XCTAssertEqual(
                KeyboardBootClassification(
                    hadReadyEngineAtEntry: kind == .warmReuse,
                    processHasEverBeenReady: kind != .coldFirstBoot),
                kind)
        }
    }
}
