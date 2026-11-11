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
    // Fail safe: an unreadable state reverts, unless the user asked to stay awake.
    func testRevertsWhenStateUnknownUnlessUserOptedToStayAwake() {
        XCTAssertTrue(QuitPolicy.shouldRevertOnQuit(sleepDisabled: nil, stayAwakeAfterQuit: false))
        XCTAssertFalse(QuitPolicy.shouldRevertOnQuit(sleepDisabled: nil, stayAwakeAfterQuit: true))
    }
}
