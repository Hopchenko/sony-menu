import AppKit
import SwiftUI

extension TestMain {
    static func modelSupportTests() async {
        await test("Automatic discovery prefers connected XM4 over disconnected XM3 and retains offline identity") {
            let xm3 = HeadphoneDevice(id: "xm3", name: "WH-1000XM3", connected: false)
            let xm4 = HeadphoneDevice(id: "xm4", name: "WH-1000XM4", connected: true)
            try expect(HeadphoneSelection.choose([xm3, xm4], preferred: nil, current: "xm3", remembered: "xm3") == xm4)
            let offline = HeadphoneDevice(id: "xm4", name: xm4.name, connected: false)
            try expect(HeadphoneSelection.choose([xm3, offline], preferred: nil, current: "xm4", remembered: "xm4") == offline)
            try expect(HeadphoneSelection.choose([xm3, xm4], preferred: "xm3", current: "xm4", remembered: nil) == xm3)
        }
        await test("Both connected headsets retain current target independent of arrival order") {
            let a = HeadphoneDevice(id: "a", name: "WH-1000XM4", connected: true)
            let b = HeadphoneDevice(id: "b", name: "WH-1000XM4", connected: true)
            try expect(HeadphoneSelection.choose([b,a], preferred: nil, current: "a", remembered: "b") == a)
            try expect(HeadphoneSelection.choose([b,a], preferred: nil, current: nil, remembered: "a") == a)
            try expect(HeadphoneSelection.choose([a], preferred: "missing", current: nil, remembered: nil) == nil)
            try expect(HeadphoneSelection.choose([HeadphoneDevice(id: "x", name: "WH-1000XM5", connected: true)], preferred: nil, current: nil, remembered: nil) == nil)
        }
        await test("Switching from XM3 after sleep to XM4 clears old sleep intent and isolates preferences") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.color != nil }
            rig.store.colorChoice = .silver
            rig.store.reconnectAfterUnlock = true
            rig.platform.onSleep?(); try expect(rig.platform.selectionLocked)
            rig.platform.onWake?(); rig.platform.onUnlock?()
            try await wait { rig.store.ready }
            rig.store.setAmbient(level: 7)
            rig.platform.address = "AA-BB-CC-DD-EE-FF"
            rig.platform.modelName = "WH-1000XM4"
            rig.transport.modelName = "WH-1000XM4"
            rig.transport.colorReply = [5,3,0x30,0xFE]
            rig.platform.onConnection?()
            try await wait { rig.store.ready && rig.store.state.modelName == "WH-1000XM4" }
            try expect(rig.store.model == .xm4 && rig.store.sleepStatus == nil)
            try expect(rig.store.state.color == nil && rig.store.lastDetectedColor == nil && rig.store.colorChoice == .automatic)
            try expect(!rig.store.reconnectAfterUnlock && !rig.store.disconnectOnSleep)
            rig.store.colorChoice = .blue
            try expect(rig.store.artworkName == "HeadphonesXM4Blue")
            try await Task.sleep(for: .milliseconds(240))
            try expect(!rig.transport.commands.contains { $0.payload.first == 0x68 }, "Old ambient write crossed headset sessions")
            rig.platform.address = "00-11-22-33-44-55"
            rig.platform.modelName = "WH-1000XM3"; rig.transport.modelName = "WH-1000XM3"
            rig.platform.onConnection?()
            try await wait { rig.store.ready }
            try expect(rig.store.colorChoice == .silver && rig.store.reconnectAfterUnlock)
        }
        await test("Legacy XM3 preferences migrate even when XM4 is the first selected device") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.defaults.set("silver", forKey: "headphoneColorChoice")
            rig.defaults.set(false, forKey: "disconnectOnSleep")
            rig.platform.address = "XM4-ID"; rig.platform.modelName = "WH-1000XM4"; rig.transport.modelName = "WH-1000XM4"
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try await wait { rig.store.ready }
            try expect(rig.store.colorChoice == .automatic && !rig.store.disconnectOnSleep)
            rig.platform.address = "XM3-ID"; rig.platform.modelName = "WH-1000XM3"; rig.transport.modelName = "WH-1000XM3"
            rig.platform.onConnection?()
            try await wait { rig.store.ready }
            try expect(rig.store.colorChoice == .silver && !rig.store.disconnectOnSleep)
            try expect(rig.defaults.bool(forKey: "xm3ColorMigrated"))
        }
        await test("Physically confirmed XM4 blue report selects Blue automatically without changing XM3 mappings") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.platform.modelName = "WH-1000XM4"; rig.transport.modelName = "WH-1000XM4"
            rig.transport.colorReply = [5,3,0x30,5]
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try await wait { rig.store.ready && rig.store.state.color == .blue }
            try expect(rig.store.colorChoice == .automatic && rig.store.artworkName == "HeadphonesXM4Blue")
            try expect(HeadphoneModel.xm3.color(sonyValue: 5) == nil)
            rig.transport.emit([5,3,0x30,0xFF])
            try expect(rig.store.state.color == .blue)
        }
        await test("XM4 keeps audio connected on sleep by default and preserves an explicit sleep preference") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.platform.modelName = "WH-1000XM4"; rig.transport.modelName = "WH-1000XM4"
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try await wait { rig.store.ready }
            try expect(!rig.store.disconnectOnSleep && HeadphoneModel.xm3.disconnectOnSleepByDefault)
            rig.platform.onSleep?()
            try expect(rig.platform.isConnected && rig.platform.disconnectCount == 0 && !rig.store.ready)
            rig.platform.onWake?(); try await wait { rig.store.ready }
            rig.store.disconnectOnSleep = true
            rig.store.shutdown()
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try expect(rig.store.disconnectOnSleep, "An explicit saved preference was overwritten by the default")
        }
        await test("XM4 disconnect keeps model and artwork while clearing live controls") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.platform.modelName = "WH-1000XM4"; rig.transport.modelName = "WH-1000XM4"
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try await wait { rig.store.ready }
            rig.store.colorChoice = .blue
            rig.platform.isConnected = false; rig.platform.onConnection?()
            try expect(!rig.store.ready && !rig.store.bluetoothConnected && rig.store.state.batteryPercent == nil)
            try expect(rig.store.modelName == "WH-1000XM4" && rig.store.artworkName == "HeadphonesXM4Blue")
        }
        await test("XM4 uses captured V1 reply layouts and the model-specific noise write encoding") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.platform.modelName = "WH-1000XM4"; rig.transport.modelName = "WH-1000XM4"
            rig.transport.initReply = [1,0,0x70,0]
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            rig.transport.emit([0x11,0,40,0]); rig.transport.emit([0x19,0,2]); rig.transport.emit([0x67,2,1,2,2,1,0,0])
            try expect(rig.store.state.batteryPercent == 40 && rig.store.state.codecName == "AAC" && rig.store.state.noiseMode == .noiseCancellation)
            try expect(!rig.transport.commands.contains { $0.payload == [0xE6,1] })
            rig.store.setMode(.off)
            try await wait { rig.store.state.noiseMode == .off }
            try expect(rig.transport.commands.contains { $0.payload == [0x68,2,0,2,0,1,0,0] })
        }
        await test("XM4 artwork switches model icons and renders all colors in native Light and Dark") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.platform.modelName = "WH-1000XM4"; rig.transport.modelName = "WH-1000XM4"
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try await wait { rig.store.ready }
            let icons = HeadphoneIconController(applicationIcon: { _ in }, finderIcon: { _ in true })
            icons.update(.black); icons.update(.black, model: .xm4)
            try expect(icons.appliedModel == .xm4)
            for mode in [AppAppearance.light, .dark] {
                for choice in [HeadphoneColorChoice.black, .silver, .blue] {
                    rig.store.colorChoice = choice; rig.store.appearance = mode
                    let image = NSImage(contentsOfFile: "Resources/\(rig.store.artworkName).png")!
                    image.setName(NSImage.Name(rig.store.artworkName))
                    for settings in [false,true] {
                        rig.store.settingsShown = settings
                        let host = NSHostingView(rootView: HeadphonePanel(store: rig.store))
                        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:360,height:800), styleMask:[.borderless], backing:.buffered, defer:false)
                        window.appearance = mode.native; window.contentView = host
                        host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                        try expect(abs(host.bounds.width - 360) < 1 && host.bounds.height < 800)
                        let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
                        host.cacheDisplay(in:host.bounds,to:bitmap)
                        try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"build/test-previews/xm4-\(choice.rawValue)-\(mode.rawValue)-\(settings ? "settings" : "controls").png"))
                        window.contentView = nil
                    }
                }
            }
        }
    }
}
