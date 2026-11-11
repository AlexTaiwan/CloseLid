/// Decides whether quitting the app should put the Mac back to normal sleep.
///
/// Fails safe: an unreadable state (`nil`) is treated like Awake. `disablesleep 0` is
/// idempotent, so reverting a Mac that was already normal changes nothing, while
/// skipping the revert on a Mac that was really awake leaves it running with the lid
/// closed and no app left to show it. Only a positive "normal" reading, or the user's
/// "Stay Awake After Quit" choice, skips the revert.
enum QuitPolicy {
    static func shouldRevertOnQuit(sleepDisabled: Bool?, stayAwakeAfterQuit: Bool) -> Bool {
        sleepDisabled != false && !stayAwakeAfterQuit
    }
}
