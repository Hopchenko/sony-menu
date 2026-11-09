import AppKit
import SwiftUI

extension TestMain {
    private static func xm4FeatureRig() -> TestRig {
        let rig = TestRig(start: false)
        rig.platform.modelName = "WH-1000XM4"; rig.transport.modelName = "WH-1000XM4"
        rig.transport.xm4FeaturesRespond = true
        rig.transport.colorReply = [5,3,0x30,5]
        rig.platform.microphones = MicrophoneState(devices: [MicrophoneDevice(id: 1, name: "MacBook Pro Microphone"), MicrophoneDevice(id: 2, name: "WH-1000XM4")], selectedID: 1)
        rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client, retryDelays: [.milliseconds(3)])
        return rig
    }
    static func xm4FeatureTests() async {
        await test("XM4 capabilities query actual settings without startup writes") {
            let rig = xm4FeatureRig(); defer { rig.close() }
            try await wait { rig.store.state.xm4.multipointEnabled != nil && rig.store.state.xm4.conversationOptions != nil && rig.store.state.dseeEnabled != nil }
            try expect(rig.store.state.xm4.speakToChatEnabled == true && rig.store.state.xm4.wearDetectionEnabled == true)
            try expect(rig.store.state.xm4.wearPowerOffEnabled == true && rig.store.state.dseeEnabled == false)
            try expect(rig.store.state.xm4.multipointSlot == 0xD2 && rig.store.state.xm4.multipointEnabled == true)
            try expect(!rig.transport.commands.contains { [0xF8,0xFC,0xD8,0xE8].contains($0.payload.first ?? 0) })
        }
        await test("XM4 idle after capability discovery performs no polling, writes, or connection checks") {
            let rig = xm4FeatureRig(); defer { rig.close() }
            try await wait { rig.store.state.xm4.multipointEnabled != nil && rig.store.state.xm4.conversationOptions != nil && rig.store.state.dseeEnabled != nil }
            let packets = rig.transport.sent.count, connections = rig.transport.connectCount, checks = rig.store.connectionCheckCount
            try await Task.sleep(for: .milliseconds(350))
            try expect(rig.transport.sent.count == packets && rig.transport.connectCount == connections && rig.store.connectionCheckCount == checks)
            try expect(rig.store.pendingXM4Change == nil && rig.platform.volumeWrites.isEmpty)
        }
        await test("Completed XM4 setting verification returns to idle without extra reads or retries") {
            let rig = xm4FeatureRig(); defer { rig.close() }
            try await wait { rig.store.state.xm4.multipointEnabled != nil && rig.store.state.xm4.wearDetectionEnabled != nil }
            rig.store.setWearDetection(false)
            try await wait { rig.store.pendingXM4Change == nil && rig.store.state.xm4.wearDetectionEnabled == false }
            let packets = rig.transport.sent.count, checks = rig.store.connectionCheckCount
            try await Task.sleep(for: .milliseconds(350))
            try expect(rig.transport.sent.count == packets && rig.store.connectionCheckCount == checks)
        }
        await test("XM4 setters use observed payloads and matching device readback") {
            let rig = xm4FeatureRig(); defer { rig.close() }
            try await wait { rig.store.state.xm4.multipointEnabled != nil && rig.store.state.dseeEnabled != nil }
            rig.store.setSpeakToChat(false)
            try await wait { rig.store.pendingXM4Change == nil && rig.store.state.xm4.speakToChatEnabled == false }
            rig.store.setConversationOptions(sensitivity: .low, focusOnVoice: true, timeout: .never)
            try await wait { rig.store.pendingXM4Change == nil && rig.store.state.xm4.conversationOptions?.timeout == .never }
            rig.store.setWearDetection(false)
            try await wait { rig.store.pendingXM4Change == nil && rig.store.state.xm4.wearDetectionEnabled == false }
            rig.store.setWearPowerOff(false)
            try await wait { rig.store.pendingXM4Change == nil && rig.store.state.xm4.wearPowerOffEnabled == false }
            rig.store.setDSEE(true)
            try await wait { rig.store.pendingXM4Change == nil && rig.store.state.dseeEnabled == true }
            rig.store.setMultipoint(false)
            try await wait { rig.store.pendingXM4Change == nil && rig.store.state.xm4.multipointEnabled == false }
            for p: [UInt8] in [[0xF8,5,1,0],[0xFC,5,0,2,1,3],[0xF8,3,0,0],[0xF8,4,1,0x11,0],[0xE8,2,0,1],[0xD8,0xD2,1,0],[0x94,1,0],[0x98,1,7,1]] {
                try expect(rig.transport.commands.contains { $0.payload == p }, "Missing verified feature payload \(p)")
            }
            try expect(!rig.platform.selectionLocked && rig.store.xm4ChangeStatus == "Multipoint updated.")
        }
        await test("XM4 change never optimistically updates a setting from an ACK") {
            let rig = xm4FeatureRig(); defer { rig.close() }
            try await wait { rig.store.state.xm4.speakToChatEnabled != nil }
            rig.transport.featureWritesApply = false
            rig.store.setSpeakToChat(false)
            try await Task.sleep(for: .milliseconds(40))
            try expect(rig.store.state.xm4.speakToChatEnabled == true && rig.store.pendingXM4Change == .speakToChat)
            let writes = rig.transport.commands.filter { $0.payload.first == 0xF8 }.count
            rig.store.setWearDetection(false)
            try await Task.sleep(for: .milliseconds(10))
            try expect(rig.transport.commands.filter { $0.payload.first == 0xF8 }.count == writes)
            rig.store.shutdown()
            try expect(rig.store.pendingXM4Change == nil)
        }
        await test("Malformed XM4 replies do not replace confirmed settings or discover a guessed slot") {
            let rig = xm4FeatureRig(); defer { rig.close() }
            try await wait { rig.store.state.xm4.conversationOptions != nil && rig.store.state.xm4.multipointEnabled != nil }
            let before = rig.store.state.xm4
            for p: [UInt8] in [[0xF7,5,0,255],[0xF7,3,1,0],[0xF7,4,1,0,0],[0xFB,5,0,9,0,1],[0xFB,5,0,0,2,1],[0xFB,5,0,0,0,9],[0xD7,0xD2,1,3],[0xD1,0xD3,2,255],[0xF1,5,0]] { rig.transport.emit(p) }
            try expect(rig.store.state.xm4 == before)
            for c in [UInt8(0xD1),0xD2,0xD3] {
                let name = Array("TOUCH_PANEL_SETTING".utf8)
                try expect(SonyXM4Settings.multipointSlot(from: [0xD1,c,2,UInt8(name.count)] + name + [0,1,0]) == nil)
            }
            rig.client.setTouchSensor(enabled: false)
            try expect(!rig.transport.commands.contains { $0.payload.first == 0xD8 })
        }
        await test("Multipoint confirmation never accepts unsolicited, unrelated or expired alerts") {
            let rig = xm4FeatureRig(); defer { rig.close() }
            try await wait { rig.store.state.xm4.multipointEnabled != nil }
            for p: [UInt8] in [[0x99,1,6,1],[0x99,1,7,1],[0x99,1,1,1],[0x99,1,7],[0x99,2,7,1]] { rig.transport.emit(p) }
            try expect(!rig.transport.commands.contains { $0.payload.first == 0x98 })
            rig.transport.autoRespond = false
            _ = rig.client.setMultipoint(false)
            rig.transport.emit([0x99,1,6,1])
            rig.client.cancelMultipointRequest()
            rig.transport.emit([0x99,1,7,1])
            // Drain the explicit request and its readbacks; no alert response should exist.
            for _ in 0..<8 {
                if let packet = rig.transport.commands.last { rig.transport.ack(packet) }
            }
            try expect(!rig.transport.commands.contains { $0.payload.first == 0x98 })
        }
        await test("XM3 never receives XM4-only inquiries or setting writes") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            try expect(!rig.client.setSpeakToChat(true) && !rig.client.setWearDetection(false) && !rig.client.setWearPowerOff(false) && !rig.client.setMultipoint(false) && !rig.client.setXM4DSEE(true))
            try expect(!rig.transport.commands.contains { [0xF0,0xD0,0xE0,0xFA].contains($0.payload.first ?? 0) })
        }
        await test("Multipoint confirmation survives the headset reconnecting") {
            let rig = xm4FeatureRig(); defer { rig.close() }
            try await wait { rig.store.state.xm4.multipointEnabled != nil }
            rig.transport.dropConnectionOnMultipoint = true
            rig.store.setMultipoint(false)
            try expect(rig.platform.selectionLocked)
            try await wait({ rig.store.pendingXM4Change == nil && rig.store.state.xm4.multipointEnabled == false }, milliseconds: 2000)
            try expect(rig.store.ready && !rig.platform.selectionLocked && rig.transport.connectCount == 2)
        }
        await test("Changing target cancels outstanding XM4 feature confirmation") {
            let rig = xm4FeatureRig(); defer { rig.close() }
            try await wait { rig.store.state.xm4.speakToChatEnabled != nil }
            rig.transport.featureWritesApply = false
            rig.store.setSpeakToChat(false)
            rig.platform.address = "OTHER-XM3"; rig.platform.modelName = "WH-1000XM3"; rig.transport.modelName = "WH-1000XM3"
            rig.platform.onConnection?()
            try expect(rig.store.pendingXM4Change == nil && rig.store.xm4ChangeStatus == nil && rig.store.state.xm4 == SonyXM4Settings())
        }
        await test("XM4 feature settings render with descriptions and a scrollable native layout") {
            let rig = xm4FeatureRig(); defer { rig.close() }
            try await wait { rig.store.state.xm4.multipointEnabled != nil && rig.store.state.xm4.conversationOptions != nil }
            rig.store.settingsShown = true
            func scroll(_ v: NSView) -> NSScrollView? { (v as? NSScrollView) ?? v.subviews.compactMap { scroll($0) }.first }
            for mode in [AppAppearance.light, .dark] {
                rig.store.appearance = mode
                let host = NSHostingView(rootView: HeadphonePanel(store: rig.store))
                let window = NSWindow(contentRect: NSRect(x:0,y:0,width:360,height:800), styleMask:[.borderless], backing:.buffered, defer:false)
                window.appearance = mode.native; window.contentView = host
                host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                try expect(abs(host.bounds.width - 360) < 1 && host.bounds.height < 800)
                guard let scroller = scroll(host), let document = scroller.documentView else { throw TestFailure(description: "Missing settings scroll view") }
                try expect(document.bounds.height > scroller.bounds.height)
                for (name,offset) in [("overview",CGFloat(0)),("conversation",CGFloat(350)),("multipoint",CGFloat(650)),("wearing",CGFloat(900))] {
                    document.scrollToVisible(NSRect(x:0,y:offset,width:1,height:450));scroller.reflectScrolledClipView(scroller.contentView);host.layoutSubtreeIfNeeded()
                    let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
                    host.cacheDisplay(in:host.bounds,to:bitmap)
                    try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"build/test-previews/xm4-features-\(name)-\(mode.rawValue).png"))
                }
                window.contentView = nil
            }
        }
    }
}
