import Foundation

/// Renders the single sudoers drop-in this app installs. Pure; no I/O.
enum SudoersRule {
    static let path = "/etc/sudoers.d/closelid"

    enum Error: Swift.Error, Equatable {
        case invalidUsername(String)
    }

    /// Conservative POSIX-style username: starts with a letter or underscore,
    /// then letters/digits/`_`/`.`/`-`, max 32 chars. Anything else is refused so a
    /// crafted username can never inject extra sudoers grammar.
    private static let usernamePattern = #"^[A-Za-z_][A-Za-z0-9_.\-]{0,31}$"#

    static func render(username: String) throws -> String {
        guard username.range(of: usernamePattern, options: .regularExpression) != nil,
              username != "ALL" else {
            throw Error.invalidUsername(username)
        }
        return """
        # Installed by CloseLid.app - allows toggling lid-close sleep without a password
        \(username) ALL=(root) NOPASSWD: \(PowerCommand.pmsetPath) -a disablesleep 1, \(PowerCommand.pmsetPath) -a disablesleep 0

        """
    }
}
