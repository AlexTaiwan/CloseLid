import Foundation
import IOKit.pwr_mgt

protocol SleepAssertionHolding: AnyObject {
    var isHeld: Bool { get }
    func acquire()
    func release()
}

/// Belt-and-braces guard against *idle* sleep while Awake mode is on.
/// This does NOT stop lid-close sleep; `pmset disablesleep` does that.
final class IOPMSleepAssertion: SleepAssertionHolding {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isHeld = false

    func acquire() {
        guard !isHeld else { return }
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "CloseLid: keep awake with lid closed" as CFString,
            &assertionID
        )
        isHeld = (status == kIOReturnSuccess)
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHeld = false
    }

    deinit { release() }
}
