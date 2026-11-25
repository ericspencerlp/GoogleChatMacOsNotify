import AppKit

/// Builds the menu bar icon. SwiftUI renders `Image(systemName:)` in the menu bar as a
/// monochrome template, so a colored icon has to be a non-template `NSImage`.
enum MenuBarIcon {
    static let highlightColor = NSColor.systemOrange

    static func image(symbol: String, highlighted: Bool) -> NSImage {
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Google Chat Notifier") ?? NSImage()
        guard highlighted else {
            let image = base.withSymbolConfiguration(size) ?? base
            image.isTemplate = true
            return image
        }
        let config = size.applying(NSImage.SymbolConfiguration(paletteColors: [highlightColor]))
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = false
        return image
    }
}
