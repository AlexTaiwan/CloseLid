import Foundation

/// How long after the display turns off (which closing the lid always does) macOS
/// asks for the password. Read-only here: changing it needs the user's login
/// password, so the menu sends the user to System Settings instead.
enum ScreenLockDelay: Equatable {
    case immediate
    case after(seconds: Int)
    case off
    case unknown

    /// Menu wording, e.g. "Password after lid close: immediately".
    var menuLine: String {
        switch self {
        case .immediate:          return "Password after lid close: immediately"
        case let .after(seconds): return "Password after lid close: after \(Self.describe(seconds))"
        case .off:                return "Password after lid close: never"
        case .unknown:            return "Password after lid close: unknown"
        }
    }

    private static func describe(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return seconds == 3600 ? "1 hour" : "\(seconds / 3600) hours" }
        if seconds % 60 == 0 { return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes" }
        return "\(seconds) seconds"
    }
}

/// Pure text parsing of `sysadminctl -screenLock status`. No I/O.
enum ScreenLockParser {
    /// sysadminctl writes its answer to stderr behind a log prefix, e.g.
    /// "2026-10-21 13:08:57.866 sysadminctl[24180:13438270] screenLock delay is immediate".
    static func delay(fromStatus text: String) -> ScreenLockDelay {
        guard let range = text.range(of: "screenLock ") else { return .unknown }
        let rest = text[range.upperBound...]
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if rest == "is off" { return .off }
        guard rest.hasPrefix("delay is ") else { return .unknown }
        let value = rest.dropFirst("delay is ".count)
        if value == "immediate" { return .immediate }
        let fields = value.split(separator: " ")
        guard fields.count == 2, fields[1] == "seconds", let seconds = Int(fields[0]), seconds >= 0 else {
            return .unknown
        }
        return seconds == 0 ? .immediate : .after(seconds: seconds)
    }
}
