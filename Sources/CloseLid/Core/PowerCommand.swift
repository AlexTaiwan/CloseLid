import Foundation

/// Every command this app runs, spelled out with absolute paths. Pure; no I/O.
enum PowerCommand {
    static let pmsetPath = "/usr/bin/pmset"
    static let sudoPath = "/usr/bin/sudo"

    static let probeSettings = [pmsetPath, "-g"]
    static let probeBattery = [pmsetPath, "-g", "batt"]

    /// Exit status 0 iff the sudoers rule allows the enable command without a password.
    static let probeHelper = [sudoPath, "-n", "-l", pmsetPath, "-a", "disablesleep", "1"]

    /// Runs as the user through non-interactive sudo; relies on the installed rule.
    static func setSleepDisabled(_ enabled: Bool) -> [String] {
        [sudoPath, "-n", pmsetPath, "-a", "disablesleep", enabled ? "1" : "0"]
    }

    /// Shell script executed as root (via PrivilegedRunner) exactly once at install.
    /// The rule is passed through a quoted heredoc so nothing in it is expanded,
    /// validated with visudo, and only then copied into place with safe ownership/mode.
    static func installHelperScript(ruleText: String) -> String {
        var body = ruleText
        while body.hasSuffix("\n") { body.removeLast() }
        return """
        set -eu
        TMP="$(/usr/bin/mktemp /tmp/closelid.XXXXXX)"
        /bin/cat > "$TMP" <<'CLOSELID_RULE'
        \(body)
        CLOSELID_RULE
        /bin/chmod 0440 "$TMP"
        /usr/sbin/visudo -c -f "$TMP" >/dev/null
        /usr/bin/install -m 0440 -o root -g wheel "$TMP" \(SudoersRule.path)
        /bin/rm -f "$TMP"
        """
    }

    /// Shell script executed as root at removal. Reverts sleep first so the machine
    /// is never left stuck awake with no silent way back.
    static let removeHelperScript = """
    set -u
    \(pmsetPath) -a disablesleep 0
    /bin/rm -f \(SudoersRule.path)
    """
}
