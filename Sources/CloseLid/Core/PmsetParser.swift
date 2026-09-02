import Foundation

/// Pure text parsing of `pmset` output. No I/O.
enum PmsetParser {
    /// Parses `pmset -g` output.
    /// - Returns: `true` if a `SleepDisabled 1` line exists, `false` if the text is
    ///   recognisably pmset output without that flag set, `nil` if the text does not
    ///   look like `pmset -g` output at all.
    static func sleepDisabled(fromSettings text: String) -> Bool? {
        guard text.contains("Currently in use:") else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            return fields[1] == "1"
        }
        return false
    }

    /// Parses `pmset -g batt` output ("Now drawing from 'AC Power'").
    static func powerSource(fromBattery text: String) -> PowerSource {
        if text.contains("'AC Power'") { return .ac }
        if text.contains("'Battery Power'") { return .battery }
        return .unknown
    }
}
