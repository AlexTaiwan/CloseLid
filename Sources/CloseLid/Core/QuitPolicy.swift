/// Decides whether quitting the app should put the Mac back to normal sleep.
/// Only acts when we positively know the Mac is in Awake mode.
enum QuitPolicy {
    static func shouldRevertOnQuit(sleepDisabled: Bool?, stayAwakeAfterQuit: Bool) -> Bool {
        sleepDisabled == true && !stayAwakeAfterQuit
    }
}
