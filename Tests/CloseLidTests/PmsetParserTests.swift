import XCTest
@testable import CloseLid

final class PmsetParserTests: XCTestCase {
    // Captured from `pmset -g` on macOS 26.5.2 with disablesleep unset.
    static let settingsNormal = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             1
     sleep                0 (sleep prevented by powerd)
     hibernatemode        3
     ttyskeepawake        1
     displaysleep         0
     tcpkeepalive         1
     lowpowermode         0
     womp                 1
    """

    // Same, with `sudo pmset -a disablesleep 1` applied.
    static let settingsAwake = """
    System-wide power settings:
    Currently in use:
     standby              1
     SleepDisabled        1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     sleep                0
     hibernatemode        3
     displaysleep         0
    """

    static let settingsExplicitZero = """
    System-wide power settings:
    Currently in use:
     SleepDisabled        0
     sleep                1
    """

    func testNormalSettingsReportsFalse() {
        XCTAssertEqual(PmsetParser.sleepDisabled(fromSettings: Self.settingsNormal), false)
    }

    func testAwakeSettingsReportsTrue() {
        XCTAssertEqual(PmsetParser.sleepDisabled(fromSettings: Self.settingsAwake), true)
    }

    func testExplicitZeroReportsFalse() {
        XCTAssertEqual(PmsetParser.sleepDisabled(fromSettings: Self.settingsExplicitZero), false)
    }

    func testGarbageReportsNil() {
        XCTAssertNil(PmsetParser.sleepDisabled(fromSettings: ""))
        XCTAssertNil(PmsetParser.sleepDisabled(fromSettings: "pmset: command not found"))
    }

    func testSleepDisabledIsMatchedAsWholeWordOnly() {
        // A hypothetical future key that merely contains the substring must not match.
        let text = "System-wide power settings:\nCurrently in use:\n SleepDisabledFoo 1\n"
        XCTAssertEqual(PmsetParser.sleepDisabled(fromSettings: text), false)
    }

    func testPowerSourceAC() {
        let text = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1234)\t100%; charged; 0:00 remaining present: true\n"
        XCTAssertEqual(PmsetParser.powerSource(fromBattery: text), .ac)
    }

    func testPowerSourceBattery() {
        let text = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t87%; discharging; 5:10 remaining present: true\n"
        XCTAssertEqual(PmsetParser.powerSource(fromBattery: text), .battery)
    }

    func testPowerSourceUnknown() {
        XCTAssertEqual(PmsetParser.powerSource(fromBattery: ""), .unknown)
    }

    func testSnapshotModeMapping() {
        XCTAssertEqual(PmsetSnapshot(sleepDisabled: nil, powerSource: .ac).mode, .unknown)
        XCTAssertEqual(PmsetSnapshot(sleepDisabled: true, powerSource: .ac).mode, .awake)
        XCTAssertEqual(PmsetSnapshot(sleepDisabled: false, powerSource: .ac).mode, .normal)
    }
}
