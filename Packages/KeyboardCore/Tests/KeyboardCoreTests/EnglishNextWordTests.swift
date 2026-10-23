import XCTest

@testable import KeyboardCore

final class EnglishNextWordTests: XCTestCase {
    func testContractionsHaveContinuations() {
        let model = EnglishNextWordModel()
        XCTAssertEqual(model.predictions(after: "I've"), ["been", "got", "never"])
        XCTAssertEqual(model.predictions(after: "I’ve"), ["been", "got", "never"], "typographic apostrophe")
        XCTAssertEqual(model.predictions(after: "zzz"), [])
        XCTAssertEqual(model.predictions(after: ""), [])
    }

    func testTypedPairsRankFirst() {
        var model = EnglishNextWordModel()
        model.learn("I've", "decided")
        XCTAssertEqual(model.predictions(after: "i've"), ["decided", "been", "got"])
        model.learn("I've", "got")
        model.learn("I've", "got")
        XCTAssertEqual(model.predictions(after: "I've").first, "got")
    }

    func testLearnedContextsAreBounded() {
        var model = EnglishNextWordModel()
        for index in 0...EnglishNextWordModel.learnedCapacity { model.learn("w\(index)", "next") }
        XCTAssertEqual(model.predictions(after: "w0"), [], "oldest context dropped")
        XCTAssertEqual(model.predictions(after: "w1"), ["next"])
    }
}
