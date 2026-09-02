import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case enabled
    case disabled
    /// Registered, but macOS wants the user to approve it under
    /// System Settings › General › Login Items & Extensions.
    case requiresApproval
}

protocol LoginItemManaging: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ on: Bool) throws
}

/// Registers this app itself as a login item. No helper, no plist: `SMAppService.mainApp`
/// is the macOS 13+ replacement for the old "Login Items" AppleScript dance.
final class SMAppServiceLoginItem: LoginItemManaging {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
