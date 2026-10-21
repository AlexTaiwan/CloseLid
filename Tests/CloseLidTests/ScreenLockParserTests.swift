import XCTest
@testable import CloseLid

final class ScreenLockParserTests: XCTestCase {
    // Captured from `sysadminctl -screenLock status` on macOS 26.6.2 (stderr).
    static let immediate = "2026-10-21 13:08:57.866 sysadminctl[24180:13438270] screenLock delay is immediate\n"

    func testImmediate() {
        XCTAssertEqual(ScreenLockParser.delay(fromStatus: Self.immediate), .immediate)
    }

    func testSecondsDelay() {
        let text = Self.immediate.replacingOccurrences(of: "immediate", with: "300 seconds")
        XCTAssertEqual(ScreenLockParser.delay(fromStatus: text), .after(seconds: 300))
    }

    func testZeroSecondsIsImmediate() {
        XCTAssertEqual(ScreenLockParser.delay(fromStatus: "screenLock delay is 0 seconds"), .immediate)
    }

    func testOff() {
        XCTAssertEqual(ScreenLockParser.delay(fromStatus: "x sysadminctl[1:2] screenLock is off\n"), .off)
    }

    func testUnrecognisedOutputIsUnknown() {
        for text in ["", "garbage", "screenLock delay is soon", "screenLock delay is -5 seconds"] {
            XCTAssertEqual(ScreenLockParser.delay(fromStatus: text), .unknown, text)
        }
    }

    func testMenuLines() {
        XCTAssertEqual(ScreenLockDelay.immediate.menuLine, "Password after lid close: immediately")
        XCTAssertEqual(ScreenLockDelay.after(seconds: 60).menuLine, "Password after lid close: after 1 minute")
        XCTAssertEqual(ScreenLockDelay.after(seconds: 300).menuLine, "Password after lid close: after 5 minutes")
        XCTAssertEqual(ScreenLockDelay.after(seconds: 3600).menuLine, "Password after lid close: after 1 hour")
        XCTAssertEqual(ScreenLockDelay.after(seconds: 5).menuLine, "Password after lid close: after 5 seconds")
        XCTAssertEqual(ScreenLockDelay.off.menuLine, "Password after lid close: never")
    }
}
