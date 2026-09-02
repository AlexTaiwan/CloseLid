/// Copy shown in the macOS admin-password dialog. The dialog is otherwise attributed to
/// "osascript", so these sentences are what earns the user's trust. Pure; no I/O.
enum PrivilegedPrompt {
    static let install =
        "CloseLid needs your password once to add a sudoers rule that lets it turn lid-close sleep on and off without asking again."
    static let remove =
        "CloseLid needs your password once to remove the sudoers rule it installed."
    static let removeWhileAwake = remove + " This also switches back to normal sleep."
}
