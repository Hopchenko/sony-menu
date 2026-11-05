import AppKit
import SwiftUI

/// Apply overrides to the popover itself: changing NSApp alone can leave its
/// already-created hosting window using the previous appearance.
@MainActor
enum PanelAppearance {
    static func apply(_ mode: AppAppearance, to popover: NSPopover) {
        NSApp.appearance = mode.native
        popover.appearance = mode.native
        popover.contentViewController?.view.appearance = mode.native
        popover.contentViewController?.view.window?.appearance = mode.native
    }
}

struct PanelPalette {
    let dark: Bool
    var background: NSColor { gray(dark ? 0.12 : 0.98) }
    var card: NSColor { gray(dark ? 0.18 : 0.93) }
    var text: NSColor { gray(dark ? 0.96 : 0.10) }
    var secondary: NSColor { gray(dark ? 0.76 : 0.32) }
    var selected: NSColor { gray(dark ? 0.30 : 0.80) }
    private func gray(_ value: CGFloat) -> NSColor { NSColor(srgbRed: value, green: value, blue: value, alpha: 1) }
}
