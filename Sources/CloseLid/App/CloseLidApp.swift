import SwiftUI

@main
struct CloseLidApp: App {
    var body: some Scene {
        MenuBarExtra("CloseLid", systemImage: "laptopcomputer") {
            Text("CloseLid scaffold")
            Divider()
            Button("Quit CloseLid") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
