import XCTest

@testable import SkinKit

final class SkinKitTests: XCTestCase {
    func testDefaultsStrictPathsAndContrast() throws {
        let skin = try SkinDefinition.decode(
            Data(
                ##"{"formatVersion":1,"id":"my-blue","name":"蓝","variants":{"light":{"colors":{"accent":"#145ACC","text":"#FFFFFF"}}},"typography":{"family":"rounded"}}"##
                    .utf8))
        XCTAssertEqual(skin.typography.keySize, 22)
        XCTAssertEqual(skin.resolvedColors(dark: false)["text"]!.hex, "#000000")
        XCTAssertEqual(try SkinDefinition.decode(skin.encoded()), skin)
        for json in [
            #"{"formatVersion":2,"id":"x","name":"x"}"#, #"{"formatVersion":1,"id":"../x","name":"x"}"#,
            #"{"formatVersion":1,"id":"x","name":"x","variants":{"light":{"code":"a"}}}"#,
            #"{"formatVersion":1,"id":"x","name":"x","spacing":{"visualInsetX":7}}"#,
        ] {
            XCTAssertThrowsError(try SkinDefinition.decode(Data(json.utf8)))
        }
    }
}
