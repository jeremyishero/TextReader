import XCTest
@testable import CoreLogic

final class LanguageRouterTests: XCTestCase {

    let router = LanguageRouter()

    func testSimplifiedChinese() {
        XCTAssertEqual(router.detect("林风对众人说道，今天的天气不错。"), .zhHans)
    }

    func testTraditionalChinese() {
        XCTAssertEqual(router.detect("林風對眾人說道，今天的天氣不錯。"), .zhHant)
    }

    func testEnglish() {
        XCTAssertEqual(router.detect("The quick brown fox jumps over the lazy dog."), .english)
    }

    func testMixedChineseEnglishPrefersDominant() {
        // 英文为主
        XCTAssertEqual(router.detect("He said hello world, then left the room quickly."), .english)
        // 中文为主（混入少量英文）
        XCTAssertEqual(router.detect("他说了一句 hello world 然后离开了房间。"), .zhHans)
    }

    func testEmptyAndNeutral() {
        XCTAssertEqual(router.detect(""), .zhHans)
        XCTAssertEqual(router.detect("1234567890"), .zhHans)
    }
}
