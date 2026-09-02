import SwiftUI

@main
struct CloseLidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            // Silhouettes differ on purpose: the menu bar flattens rendering modes to a
            // monochrome template, so fill-vs-outline of one glyph is not distinguishable.
            switch state.mode {
            case .normal:
                Image(systemName: "laptopcomputer")
                    .accessibilityLabel("CloseLid: normal sleep")
            case .awake:
                Image(systemName: "cup.and.saucer.fill")
                    .accessibilityLabel("CloseLid: awake with lid closed")
            case .unknown:
                Image(systemName: "laptopcomputer.trianglebadge.exclamationmark")
                    .accessibilityLabel("CloseLid: sleep setting unknown")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
