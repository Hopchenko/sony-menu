import AppKit
import IOBluetooth
import SwiftUI

extension TestMain {
    static func discoveryTests() async {
        await test("Fresh service discovery recovers when the Sony records arrive after Bluetooth connects") {
            var available = false, queries = 0, opens = 0
            var failures: [String] = []
            let discovery = SonyControlServiceDiscovery(retryDelays: [.milliseconds(5), .milliseconds(5)], tryOpen: {
                guard available else { return false }; opens += 1; return true
            }, query: { queries += 1; return 0 }, failure: { failures.append($0) })
            discovery.start(); try expect(queries == 1 && opens == 0)
            discovery.completed(status: 0)
            try await wait { queries == 2 }
            available = true; discovery.completed(status: 0)
            try await Task.sleep(for: .milliseconds(25))
            try expect(opens == 1 && queries == 2 && failures.isEmpty)
        }
        await test("Missing Sony records exhaust a finite discovery budget and report one terminal failure") {
            var queries = 0, failures: [String] = []
            let discovery = SonyControlServiceDiscovery(retryDelays: [.milliseconds(3), .milliseconds(3)], tryOpen: { false }, query: { queries += 1; return 0 }, failure: { failures.append($0) })
            discovery.start(); discovery.completed(status: 0)
            try await wait { queries == 2 }; discovery.completed(status: 0)
            try await wait { queries == 3 }; discovery.completed(status: 0)
            try await Task.sleep(for: .milliseconds(25))
            discovery.completed(status: 0); discovery.start()
            try expect(queries == 3 && failures == ["No supported Sony MDR control service was found"])
        }
        await test("Cancelled service discovery ignores late SDP completion and schedules no more radio work") {
            var queries = 0, opens = 0, failures = 0, available = false
            let discovery = SonyControlServiceDiscovery(retryDelays: [.milliseconds(30)], tryOpen: { if available { opens += 1 }; return available }, query: { queries += 1; return 0 }, failure: { _ in failures += 1 })
            discovery.start(); discovery.completed(status: 0); discovery.cancel()
            available = true; discovery.completed(status: 0)
            try await Task.sleep(for: .milliseconds(50))
            try expect(queries == 1 && opens == 0 && failures == 0)
        }
        await test("A transient SDP start failure is retried and can open the later service") {
            var queries = 0, available = false, opens = 0, failures = 0
            let discovery = SonyControlServiceDiscovery(retryDelays: [.milliseconds(3)], tryOpen: { if available { opens += 1 }; return available }, query: { queries += 1; return queries == 1 ? kIOReturnNotReady : 0 }, failure: { _ in failures += 1 })
            discovery.start(); try await wait { queries == 2 }
            available = true; discovery.completed(status: 0)
            try expect(opens == 1 && failures == 0)
        }
        await test("Connected headset recovers without reopening the panel and stays Connecting during bounded retries") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.transport.connectFailuresRemaining = 2
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client, retryDelays: [.milliseconds(10), .milliseconds(10)])
            try expect(rig.store.isConnecting && rig.store.connectionLabel == "Connecting…" && rig.store.notice == nil)
            try await wait { rig.store.ready }
            try expect(rig.transport.connectCount == 3 && !rig.store.isConnecting && rig.store.notice == nil)
            let packets = rig.transport.sent.count
            try await Task.sleep(for: .milliseconds(60))
            try expect(rig.transport.connectCount == 3 && rig.transport.sent.count == packets)
        }
        await test("Retry exhaustion exposes an actionable error and manual disconnect cancels retry feedback") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.transport.connectFails = true
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client, retryDelays: [.milliseconds(5)])
            try expect(rig.store.isConnecting && rig.store.notice == nil)
            try await wait { rig.transport.connectCount == 2 && !rig.store.isConnecting }
            try expect(rig.store.connectionLabel == "Controls unavailable" && rig.store.notice == "simulated failure")
            rig.store.connect(); try expect(rig.store.isConnecting)
            rig.store.disconnect()
            try await Task.sleep(for: .milliseconds(20))
            try expect(!rig.store.isConnecting && rig.store.connectionLabel == "Disconnected")
        }
        await test("Connecting spinner and multiple-headset control hint fit the native panel") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.platform.devices = [HeadphoneDevice(id: "xm3", name: "WH-1000XM3", connected: true), HeadphoneDevice(id: "xm4", name: "WH-1000XM4", connected: true)]
            rig.transport.connectFails = true
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client, retryDelays: [.seconds(30)])
            try expect(rig.store.isConnecting && rig.store.notice == nil)
            for theme in [AppAppearance.light, .dark] {
                rig.store.appearance = theme
                let host = NSHostingView(rootView: HeadphonePanel(store: rig.store))
                let window = NSWindow(contentRect: NSRect(x:0,y:0,width:360,height:800), styleMask:[.borderless], backing:.buffered, defer:false)
                window.appearance = theme.native; window.contentView = host
                host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                try expect(abs(host.bounds.width - 360) < 1 && host.bounds.height < 800)
                let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"build/test-previews/connecting-\(theme.rawValue).png"))
                window.contentView = nil
            }
        }
    }
}
