import XCTest
@testable import CloseLid

final class BatteryGuardTests: XCTestCase {
    func testThresholdIsTenPercent() {
        XCTAssertEqual(BatteryGuard.threshold, 10)
    }

    func testIsLowOnlyOnBatteryAtOrBelowThreshold() {
        XCTAssertTrue(BatteryGuard.isLow(powerSource: .battery, batteryPercent: 10))
        XCTAssertTrue(BatteryGuard.isLow(powerSource: .battery, batteryPercent: 0))
        XCTAssertFalse(BatteryGuard.isLow(powerSource: .battery, batteryPercent: 11))
        XCTAssertFalse(BatteryGuard.isLow(powerSource: .ac, batteryPercent: 5))
        XCTAssertFalse(BatteryGuard.isLow(powerSource: .unknown, batteryPercent: 5))
        XCTAssertFalse(BatteryGuard.isLow(powerSource: .battery, batteryPercent: nil),
                       "an unknown charge must never be treated as empty")
    }

    func testIsRecoveredNeedsPositiveEvidence() {
        XCTAssertTrue(BatteryGuard.isRecovered(powerSource: .ac, batteryPercent: 5))
        XCTAssertTrue(BatteryGuard.isRecovered(powerSource: .ac, batteryPercent: nil))
        XCTAssertTrue(BatteryGuard.isRecovered(powerSource: .battery, batteryPercent: 11))
        XCTAssertFalse(BatteryGuard.isRecovered(powerSource: .battery, batteryPercent: 10))
        XCTAssertFalse(BatteryGuard.isRecovered(powerSource: .battery, batteryPercent: nil))
        XCTAssertFalse(BatteryGuard.isRecovered(powerSource: .unknown, batteryPercent: nil))
    }

    func testShouldRevertOnlyWhenAwakeAndLow() {
        XCTAssertTrue(BatteryGuard.shouldRevert(mode: .awake, powerSource: .battery, batteryPercent: 10))
        XCTAssertFalse(BatteryGuard.shouldRevert(mode: .normal, powerSource: .battery, batteryPercent: 10))
        XCTAssertFalse(BatteryGuard.shouldRevert(mode: .unknown, powerSource: .battery, batteryPercent: 10))
        XCTAssertFalse(BatteryGuard.shouldRevert(mode: .awake, powerSource: .battery, batteryPercent: 11))
        XCTAssertFalse(BatteryGuard.shouldRevert(mode: .awake, powerSource: .ac, batteryPercent: 5))
    }

    func testMenuLine() {
        XCTAssertEqual(BatteryGuard.menuLine(powerSource: .ac, batteryPercent: 80), "On AC power")
        XCTAssertEqual(BatteryGuard.menuLine(powerSource: .unknown, batteryPercent: nil), "Power source unknown")
        XCTAssertEqual(BatteryGuard.menuLine(powerSource: .battery, batteryPercent: nil),
                       "On battery — Keep Awake will run it down to empty")
        XCTAssertEqual(BatteryGuard.menuLine(powerSource: .battery, batteryPercent: 42),
                       "On battery (42%) — Keep Awake switches off at 10%")
        XCTAssertEqual(BatteryGuard.menuLine(powerSource: .battery, batteryPercent: 8),
                       "On battery (8%) — too low, Keep Awake will run it down to empty")
    }

    func testNotice() {
        XCTAssertEqual(BatteryGuard.notice(percent: 10), "Keep Awake switched itself off at 10% battery")
    }
}
