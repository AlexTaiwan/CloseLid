/// Decides when Keep Awake must switch itself off to protect the battery, and the
/// wording that goes with it. Pure; no I/O.
///
/// With `disablesleep 1` a closed MacBook on battery cannot sleep or hibernate, so it
/// runs until a forced shutdown. Nobody sees the menu with the lid closed, so the app
/// has to act on its own: at or below `threshold` it restores normal sleep, and the
/// Mac sleeps with the work still in memory instead of dying.
enum BatteryGuard {
    /// Percent of charge. macOS shows its own low-battery warning at the same level.
    static let threshold = 10

    /// True only on battery with a known charge at or below the threshold.
    /// An unknown charge (`nil`) or an unknown power source is never "low".
    static func isLow(powerSource: PowerSource, batteryPercent: Int?) -> Bool {
        guard powerSource == .battery, let batteryPercent else { return false }
        return batteryPercent <= threshold
    }

    /// True when the guard has positive evidence that the battery is no longer low:
    /// on AC, or a known charge above the threshold. Unknown readings are not evidence.
    static func isRecovered(powerSource: PowerSource, batteryPercent: Int?) -> Bool {
        if powerSource == .ac { return true }
        guard let batteryPercent else { return false }
        return batteryPercent > threshold
    }

    static func shouldRevert(mode: PowerMode, powerSource: PowerSource, batteryPercent: Int?) -> Bool {
        mode == .awake && isLow(powerSource: powerSource, batteryPercent: batteryPercent)
    }

    /// The power-source row of the menu.
    static func menuLine(powerSource: PowerSource, batteryPercent: Int?) -> String {
        switch powerSource {
        case .ac:
            return "On AC power"
        case .unknown:
            return "Power source unknown"
        case .battery:
            guard let batteryPercent else {
                return "On battery — Keep Awake will run it down to empty"
            }
            if batteryPercent <= threshold {
                return "On battery (\(batteryPercent)%) — too low, Keep Awake will run it down to empty"
            }
            return "On battery (\(batteryPercent)%) — Keep Awake switches off at \(threshold)%"
        }
    }

    /// Menu row left behind after the guard has switched Keep Awake off.
    static func notice(percent: Int) -> String {
        "Keep Awake switched itself off at \(percent)% battery"
    }
}
