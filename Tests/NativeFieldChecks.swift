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
            try expect(abs(field.bounds.width - 286) < 1, "Dropdown did not fill the shared field width")
            field.selectItem(at: 1)
            try expect(field.sendAction(field.action, to: field.target))
            try expect(selected == 1 && field.titleOfSelectedItem == longName && field.toolTip == longName && field.accessibilityValue() as? String == longName)
            try expect(abs(field.bounds.width - 286) < 1, "Long device name changed the field width")
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
            func edges(_ path: String, row: CGFloat) throws -> (Int, Int) {
                let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!
                let scale = CGFloat(bitmap.pixelsWide) / 360
                let y = Int(row * scale)
                let reference = bitmap.colorAt(x: Int(20 * scale), y: y)!.usingColorSpace(.sRGB)!
                let matches = (0..<bitmap.pixelsWide).filter { x in
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    return abs(color.redComponent - reference.redComponent) < 0.001 && abs(color.greenComponent - reference.greenComponent) < 0.001 && abs(color.blueComponent - reference.blueComponent) < 0.001
                }
                return (matches.first!, matches.last!)
            }
            for theme in ["light", "dark"] {
                let main = try edges("build/test-previews/\(theme)-controls.png", row: 136)
                let settings = try edges("build/test-previews/\(theme)-settings.png", row: 170)
                try expect(main.0 == settings.0 && main.1 == settings.1, "Unequal \(theme) main/settings card edges: \(main), \(settings)")
            }
        }
    }
}
