import AppKit
import SwiftUI

extension TestMain {
    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap { scrollView(in: $0) }.first
    }

    static func headphoneColorTests() async {
        await test("Sony color values map only known black and silver/white variants") {
            for value: UInt8 in [1, 0x11] { try expect(HeadphoneColor(sonyValue: value) == .black) }
            for value: UInt8 in [2, 3, 0x12, 0x13] { try expect(HeadphoneColor(sonyValue: value) == .silver) }
            for value: UInt8 in [0, 4, 5, 0xFF] { try expect(HeadphoneColor(sonyValue: value) == nil) }
        }
        await test("Headphone color is read from device info and remembered") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.transport.colorReply = [5, 3, 0, 3]
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try await wait { rig.store.ready && rig.store.state.color == .silver }
            try expect(rig.store.headphoneColor == .silver && rig.store.lastDetectedColor == .silver)
            try expect(rig.defaults.string(forKey: "detectedHeadphoneColor") == "silver")
            try expect(rig.transport.commands.contains { $0.payload == [4, 3] })
            let count = rig.transport.commands.filter { $0.payload == [4, 3] }.count
            rig.store.refresh()
            try await Task.sleep(for: .milliseconds(30))
            try expect(rig.transport.commands.filter { $0.payload == [4, 3] }.count == count, "Known immutable color was queried again")
        }
        await test("Malformed or unknown color replies preserve confirmed identity") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.color == .black }
            let name = rig.store.state.modelName
            for payload: [UInt8] in [[5], [5,3], [5,3,0], [5,3,0,255], [5,2,0,3]] { rig.transport.emit(payload) }
            try expect(rig.store.state.color == .black && rig.store.state.modelName == name)
        }
        await test("Unreported color keeps controls usable and permits a manual artwork choice") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.transport.colorReply = nil
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try await wait { rig.store.ready }
            try expect(rig.store.state.color == nil && rig.store.headphoneColor == .black)
            rig.store.colorChoice = .silver
            try expect(rig.store.headphoneColor == .silver)
            try expect(rig.defaults.string(forKey: "headphoneColorChoice") == "silver")
        }
        await test("Manual color wins over reports and Auto restores the reported color") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.color == .black }
            rig.store.colorChoice = .black
            rig.transport.emit([5,3,0,3])
            try expect(rig.store.headphoneColor == .black && rig.store.lastDetectedColor == .silver)
            rig.store.colorChoice = .automatic
            try expect(rig.store.headphoneColor == .silver)
        }
        await test("Last detected color survives disconnect and is replaced on a new session") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.defaults.set("silver", forKey: "detectedHeadphoneColor")
            rig.transport.colorReply = nil
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try expect(rig.store.headphoneColor == .silver)
            try await wait { rig.store.ready }
            rig.client.disconnect()
            try expect(rig.store.state.color == nil && rig.store.headphoneColor == .silver)
            rig.transport.colorReply = [5,3,0,1]
            rig.store.connect()
            try await wait { rig.store.ready && rig.store.headphoneColor == .black }
            try expect(rig.defaults.string(forKey: "detectedHeadphoneColor") == "black")
        }
        await test("Invalid saved color settings safely fall back to Auto and black") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.defaults.set("future-value", forKey: "headphoneColorChoice")
            rig.defaults.set("unknown", forKey: "detectedHeadphoneColor")
            rig.transport.colorReply = nil
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try expect(rig.store.colorChoice == .automatic && rig.store.lastDetectedColor == nil && rig.store.headphoneColor == .black)
        }
        await test("Application and Finder icons use the same artwork only when color changes") {
            let black = NSImage(size: NSSize(width: 10, height: 10))
            let silver = NSImage(size: NSSize(width: 10, height: 10))
            var app: [ObjectIdentifier] = [], finder: [ObjectIdentifier] = []
            let icons = HeadphoneIconController(image: { $0 == .black ? black : silver }, applicationIcon: { app.append(ObjectIdentifier($0)) }, finderIcon: { finder.append(ObjectIdentifier($0)); return true })
            icons.update(.black); icons.update(.black); icons.update(.silver); icons.update(.silver)
            try expect(app == [ObjectIdentifier(black), ObjectIdentifier(silver)] && finder == app)
            try expect(icons.appliedColor == .silver && icons.finderIconUpdated)
        }
        await test("Missing artwork preserves the icon and failed Finder writes never start retries") {
            var app = 0, finder = 0
            let icons = HeadphoneIconController(image: { $0 == .black ? NSImage(size: NSSize(width: 10, height: 10)) : nil }, applicationIcon: { _ in app += 1 }, finderIcon: { _ in finder += 1; return false })
            icons.update(.silver)
            try expect(app == 0 && finder == 0 && icons.appliedColor == nil)
            icons.update(.black); icons.update(.black)
            try expect(app == 1 && finder == 1 && !icons.finderIconUpdated)
        }
        await test("Bundled silver and black artwork is transparent and visually distinct") {
            @MainActor func brightness(_ color: HeadphoneColor) throws -> Double {
                let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: "Resources/\(color.imageName).png")))!
                try expect(bitmap.hasAlpha && min(bitmap.pixelsWide, bitmap.pixelsHigh) >= 128)
                var total = 0.0, count = 0.0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                        let pixel = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        if pixel.alphaComponent > 0.9 { total += Double(pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3; count += 1 }
                    }
                }
                try expect(count > 10)
                return total / count
            }
            let black = try brightness(.black), silver = try brightness(.silver)
            try expect(silver > black + 0.2, "Artwork colors are swapped or duplicated")
        }
        await test("Icon comparisons identify matching pixels independently of encoded metadata") {
            let black = NSImage(named: "Headphones"), silver = NSImage(named: "HeadphonesSilver")
            try expect(HeadphoneArtwork.matches(black, black) && HeadphoneArtwork.matches(silver, silver))
            try expect(!HeadphoneArtwork.matches(black, silver) && !HeadphoneArtwork.matches(nil, silver))
        }
        await test("Silver artwork renders in both panel themes without changing layout") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.colorChoice = .silver
            for theme in [AppAppearance.light, .dark] {
                rig.store.appearance = theme
                let host = NSHostingView(rootView: HeadphonePanel(store: rig.store))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = theme.native; window.contentView = host
                host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                try expect(abs(host.bounds.width - 360) < 1 && host.bounds.height < 700)
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/test-previews/silver-\(theme.rawValue)-controls.png"))
                window.contentView = nil
                rig.store.settingsShown = true
                let settingsHost = NSHostingView(rootView: HeadphonePanel(store: rig.store))
                window.contentView = settingsHost
                settingsHost.setFrameSize(settingsHost.fittingSize); settingsHost.layoutSubtreeIfNeeded()
                if let scroll = scrollView(in: settingsHost), let document = scroll.documentView {
                    let bottom = document.isFlipped ? document.bounds.maxY - 1 : document.bounds.minY
                    document.scrollToVisible(NSRect(x: 0, y: bottom, width: 1, height: 1))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                settingsHost.layoutSubtreeIfNeeded()
                let settingsBitmap = settingsHost.bitmapImageRepForCachingDisplay(in: settingsHost.bounds)!
                settingsHost.cacheDisplay(in: settingsHost.bounds, to: settingsBitmap)
                try settingsBitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/test-previews/color-selector-\(theme.rawValue)-settings.png"))
                window.contentView = nil
                rig.store.settingsShown = false
            }
        }
    }
}
