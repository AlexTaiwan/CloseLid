import Foundation

/// Pure text parsing of `pmset` output. No I/O.
enum PmsetParser {
    /// Parses `pmset -g` output.
    /// Accepts system-wide-only output as well as output with a current profile.
    /// - Returns: `true` if a `SleepDisabled 1` line exists, `false` if the text is
    ///   recognisably pmset output without that flag set, `nil` if the text does not
    ///   look like `pmset -g` output at all.
    static func sleepDisabled(fromSettings text: String) -> Bool? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.first == "SleepDisabled" else { continue }
            guard fields.count == 2 else { return nil }
            switch fields[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return text.contains("Currently in use:") ? false : nil
    }

    /// Parses `pmset -g batt` output ("Now drawing from 'AC Power'").
    static func powerSource(fromBattery text: String) -> PowerSource {
        if text.contains("'AC Power'") { return .ac }
        if text.contains("'Battery Power'") { return .battery }
        return .unknown
    }
}
