import SwiftUI
import AppKit

@main
struct CloseLidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    private static let normalIcon = statusIcon("laptopcomputer", color: .systemBlue)
    private static let awakeIcon = statusIcon("cup.and.saucer.fill", color: .systemGreen)
    private static let unknownIcon = statusIcon("laptopcomputer.trianglebadge.exclamationmark", color: .systemOrange)

    /// Rasterize the symbol and tint it before handing it to MenuBarExtra.
    /// SwiftUI foreground styles alone can be lost when macOS templates the label.
    private static func statusIcon(_ name: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                return false
            }
            let scale = min(bounds.width / symbol.size.width, bounds.height / symbol.size.height)
            let fitted = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let rect = NSRect(x: (bounds.width - fitted.width) / 2,
                              y: (bounds.height - fitted.height) / 2,
                              width: fitted.width, height: fitted.height)
            symbol.draw(in: rect)
            color.setFill()
            bounds.fill(using: .sourceIn)
            return true
        }
        // Materialize the drawing so the status item receives original-color pixels.
        guard let data = image.tiffRepresentation, let raster = NSImage(data: data) else {
            image.isTemplate = false
            return image
        }
        raster.size = size
        raster.isTemplate = false
        return raster
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            // Use non-template raster images so the menu bar preserves status colors.
            switch state.mode {
            case .normal:
                Image(nsImage: Self.normalIcon)
                    .accessibilityLabel("CloseLid: normal sleep")
            case .awake:
                Image(nsImage: Self.awakeIcon)
                    .accessibilityLabel("CloseLid: awake with lid closed")
            case .unknown:
                Image(nsImage: Self.unknownIcon)
                    .accessibilityLabel("CloseLid: sleep setting unknown")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
