import AppKit
import SwiftUI

extension TestMain {
    static func accessibilityTests() async {
        await test("Open popover updates Light, Dark and clears every Device override") {
            let rig = TestRig(); defer { rig.close(); NSApp.appearance = nil }
            let popover = NSPopover()
            let host = NSHostingController(rootView: HeadphonePanel(store: rig.store))
            popover.contentViewController = host
            let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
            let window = NSWindow(contentRect: anchor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = anchor
            window.orderFront(nil)
            popover.animates = false
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            defer { popover.close(); window.orderOut(nil) }
            for mode in [AppAppearance.light, .dark, .light, .device] {
                rig.store.appearance = mode
                PanelAppearance.apply(mode, to: popover)
                try await Task.sleep(for: .milliseconds(40))
                host.view.layoutSubtreeIfNeeded()
                if mode != .device {
                    guard let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) else { throw TestFailure(description: "Popover capture failed") }
                    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                    let red = bitmap.colorAt(x: 8, y: 8)!.usingColorSpace(.sRGB)!.redComponent
                    try expect(mode == .dark ? red < 0.25 : red > 0.9, "Popover pixels did not follow appearance")
                }
                if mode == .device {
                    try expect(popover.appearance == nil && host.view.appearance == nil && host.view.window?.appearance == nil && NSApp.appearance == nil)
                } else {
                    try expect(host.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (mode == .dark ? .darkAqua : .aqua))
                }
            }
        }
        await test("Light and Dark text meet 4.5:1 contrast on all panel surfaces") {
            func luminance(_ color: NSColor) -> Double {
                let c = color.usingColorSpace(.sRGB)!
                func linear(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
                return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
            }
            for dark in [false, true] {
                let p = PanelPalette(dark: dark)
                for text in [p.text, p.secondary] {
                    for surface in [p.background, p.card, p.selected] {
                        let a = luminance(text), b = luminance(surface)
                        let ratio = (max(a,b) + 0.05) / (min(a,b) + 0.05)
                        try expect(ratio >= 4.5, "Text contrast \(ratio):1, dark=\(dark)")
                    }
                }
            }
        }
        await test("Native appearance segments have accessible descriptions and update the binding") {
            var mode = AppAppearance.device
            let coordinator = AppearancePicker.Coordinator(selection: Binding(get: { mode }, set: { mode = $0 }))
            let control = AppearancePicker.makeControl(target: coordinator, action: #selector(AppearancePicker.Coordinator.changed(_:)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = control
            defer { window.contentView = nil; window.orderOut(nil) }
            window.makeKeyAndOrderFront(nil)
            control.selectedSegment = 0
            try expect(control.acceptsFirstResponder && control.trackingMode == .selectOne)
            try expect(control.accessibilityLabel() == "Appearance")
            for index in 0..<3 {
                try expect(control.image(forSegment: index)?.accessibilityDescription?.isEmpty == false)
                try expect(control.toolTip(forSegment: index)?.isEmpty == false)
            }
            try expect(window.makeFirstResponder(control), "Native appearance control cannot receive keyboard focus")
            try expect(window.firstResponder === control)
            for index in 0..<3 {
                control.selectedSegment = index
                try expect(control.sendAction(control.action, to: control.target))
                try expect(mode == AppAppearance.allCases[index], "Native selection did not update appearance")
            }

        }
    }
}
