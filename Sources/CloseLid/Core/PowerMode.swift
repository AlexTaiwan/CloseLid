import Foundation

enum PowerMode: Equatable {
    case normal   // lid close sleeps the Mac (SleepDisabled absent or 0)
    case awake    // SleepDisabled 1: Mac keeps running with the lid closed
    case unknown  // could not read pmset
}

enum PowerSource: Equatable {
    case ac, battery, unknown
}

struct PmsetSnapshot: Equatable {
    var sleepDisabled: Bool?
    var powerSource: PowerSource

    var mode: PowerMode {
        switch sleepDisabled {
        case nil: return .unknown
        case true?: return .awake
        case false?: return .normal
        }
    }
}
