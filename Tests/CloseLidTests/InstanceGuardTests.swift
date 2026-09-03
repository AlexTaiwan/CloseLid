import XCTest
@testable import CloseLid

final class InstanceGuardTests: XCTestCase {
    func testFirstInstanceRuns() {
        XCTAssertFalse(InstanceGuard.shouldStandDown(otherInstances: 0, isTesting: false))
    }

    func testSecondInstanceStandsDown() {
        XCTAssertTrue(InstanceGuard.shouldStandDown(otherInstances: 1, isTesting: false))
        XCTAssertTrue(InstanceGuard.shouldStandDown(otherInstances: 3, isTesting: false))
    }

    // The tests run inside the app (TEST_HOST), so a developer running their own copy
    // of CloseLid would otherwise make every test run stand down and hang on the modal.
    func testTestRunsNeverStandDown() {
        XCTAssertFalse(InstanceGuard.shouldStandDown(otherInstances: 1, isTesting: true))
    }

    // Proves the exemption is live in this very process, which is the case that hung.
    func testThisProcessIsDetectedAsATestRun() {
        XCTAssertTrue(InstanceGuard.isRunningTests)
    }
}
