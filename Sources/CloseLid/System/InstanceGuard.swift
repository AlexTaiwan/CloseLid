import AppKit

/// Counts other running copies of this same app bundle. Injectable so the decision
/// can be tested without a second process.
protocol RunningInstancesCounting {
    func otherInstanceCount() -> Int
}

struct WorkspaceInstances: RunningInstancesCounting {
    func otherInstanceCount() -> Int {
        guard let id = Bundle.main.bundleIdentifier else { return 0 }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me }
            .count
    }
}

/// Two copies of CloseLid (say `/Applications` and a `build/` copy) share one bundle id,
/// one login item and one system-wide flag, but each reverts the flag on quit unless
/// "Stay Awake After Quit" is set. Quitting either then silently switches sleep back on
/// under the other, and the Mac sleeps at the next lid close with the menu still ticked.
/// So only the first copy runs; a later one stands down without touching the flag.
enum InstanceGuard {
    /// `isTesting` is not a convenience: the unit tests run inside the app itself
    /// (TEST_HOST), so a developer's own copy of CloseLid would make every test run
    /// stand down and block on the modal. Checked here rather than at the call site
    /// so the exemption is visible next to the rule.
    static func shouldStandDown(otherInstances: Int, isTesting: Bool) -> Bool {
        !isTesting && otherInstances > 0
    }

    /// True when the process was launched by XCTest.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static let alertTitle = "CloseLid is already running."
    static let alertMessage = """
        Another copy of CloseLid is already running and owns the sleep setting. \
        This copy will quit and has changed nothing.

        Two copies fight over the same setting, so keep only one — the one in \
        /Applications — and delete the other.
        """
}
