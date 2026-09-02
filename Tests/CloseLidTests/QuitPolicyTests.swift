import XCTest
@testable import CloseLid

final class QuitPolicyTests: XCTestCase {
    func testRevertsWhenAwakeAndUserWantsNormalAfterQuit() {
        XCTAssertTrue(QuitPolicy.shouldRevertOnQuit(sleepDisabled: true, stayAwakeAfterQuit: false))
    }
    func testDoesNotRevertWhenUserOptedToStayAwake() {
        XCTAssertFalse(QuitPolicy.shouldRevertOnQuit(sleepDisabled: true, stayAwakeAfterQuit: true))
    }
    func testDoesNotRevertWhenAlreadyNormal() {
        XCTAssertFalse(QuitPolicy.shouldRevertOnQuit(sleepDisabled: false, stayAwakeAfterQuit: false))
        XCTAssertFalse(QuitPolicy.shouldRevertOnQuit(sleepDisabled: false, stayAwakeAfterQuit: true))
    }
    func testDoesNotTouchSystemWhenStateUnknown() {
        XCTAssertFalse(QuitPolicy.shouldRevertOnQuit(sleepDisabled: nil, stayAwakeAfterQuit: false))
        XCTAssertFalse(QuitPolicy.shouldRevertOnQuit(sleepDisabled: nil, stayAwakeAfterQuit: true))
    }
}
