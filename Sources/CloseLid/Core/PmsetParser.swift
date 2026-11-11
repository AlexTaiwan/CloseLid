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

    /// Parses the charge from `pmset -g batt` output, e.g.
    /// " -InternalBattery-0 (id=1234)\t87%; discharging; 5:10 remaining present: true".
    /// - Returns: 0...100, or `nil` when there is no internal battery line (a desktop
    ///   Mac, or unreadable output). `nil` must never be read as "empty".
    static func batteryPercent(fromBattery text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) where line.contains("InternalBattery") {
            guard let percentIndex = line.firstIndex(of: "%") else { return nil }
            let digits = String(line[..<percentIndex].reversed().prefix(while: { $0.isASCII && $0.isNumber }).reversed())
            guard let value = Int(digits), (0...100).contains(value) else { return nil }
            return value
        }
        return nil
    }
}
