import AppKit
import SwiftUI

extension TestMain {
    private static func popup(in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton { return popup }
        return view.subviews.compactMap { popup(in: $0) }.first
    }
    static func nativeFieldTests() async {
        await test("Native dropdown fills its field and preserves long device names") {
            var selected = 0
            let longName = "External microphone with a long manufacturer, model and connection name"
            let host = NSHostingView(rootView: NativeMenuPicker(selection: Binding(get: { selected }, set: { selected = $0 }), options: [(0, "Mac microphone"), (1, longName)], label: "Mac microphone").frame(width: 286))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 286, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil; window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            try await wait { popup(in: host) != nil }
            let field = popup(in: host)!
            try expect(abs(field.alignmentRect(forFrame: field.frame).width - 286) < 1, "Dropdown alignment rect did not fill the shared field width: \(field.alignmentRect(forFrame: field.frame)) (frame \(field.frame))")
            field.selectItem(at: 1)
            try expect(field.sendAction(field.action, to: field.target))
            try expect(selected == 1 && field.titleOfSelectedItem == longName && field.toolTip == longName && field.accessibilityValue() as? String == longName)
            try expect(abs(field.alignmentRect(forFrame: field.frame).width - 286) < 1, "Long device name changed the field width")
        }
        await test("Native dropdown keeps confirmed selection when a write is rejected") {
            let host = NSHostingView(rootView: NativeMenuPicker(selection: Binding<Int>.constant(0), options: [(0, "Confirmed"), (1, "Requested")], label: "Sound quality mode").frame(width: 286))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 286, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil; window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            try await wait { popup(in: host) != nil }
            let field = popup(in: host)!
            field.selectItem(at: 1)
            try expect(field.sendAction(field.action, to: field.target))
            try expect(field.indexOfSelectedItem == 0 && field.titleOfSelectedItem == "Confirmed")
        }
        await test("Settings and main cards retain equal outer margins with a scroll rail") {
            func edges(_ path: String) throws -> (Int, Int) {
                let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!
                let scale = CGFloat(bitmap.pixelsWide) / 360
                let background = bitmap.colorAt(x: 0, y: 0)!.usingColorSpace(.sRGB)!
                func same(_ a: NSColor, _ b: NSColor) -> Bool {
                    abs(a.redComponent - b.redComponent) < 0.001 && abs(a.greenComponent - b.greenComponent) < 0.001 && abs(a.blueComponent - b.blueComponent) < 0.001
                }
                // Find a flat part of the first card rather than sampling a
                // fixed row, which can hit its antialiased corner on another OS.
                var widest: (Int, Int)?
                for row in stride(from: 120, to: 230, by: 4) {
                    let y = Int(CGFloat(row) * scale)
                    let reference = bitmap.colorAt(x: Int(20 * scale), y: y)!.usingColorSpace(.sRGB)!
                    if same(reference, background) { continue }
                    let matches = (0..<bitmap.pixelsWide).filter { x in
                        same(bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!, reference)
                    }
                    if let first = matches.first, let last = matches.last,
                       last - first > (widest.map { $0.1 - $0.0 } ?? 0) { widest = (first, last) }
                }
                guard let widest else { throw TestFailure(description: "No card surface found in \(path)") }
                return widest
            }
            for theme in ["light", "dark"] {
                let main = try edges("build/test-previews/\(theme)-controls.png")
                let settings = try edges("build/test-previews/\(theme)-settings.png")
                // Allow one physical pixel for antialiasing at fractional backing coordinates.
                try expect(abs(main.0 - settings.0) <= 1 && abs(main.1 - settings.1) <= 1, "Unequal \(theme) main/settings card edges: \(main), \(settings)")
            }
        }
    }
}
