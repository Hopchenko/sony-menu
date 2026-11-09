import AppKit
import Foundation
import IOBluetooth
import SwiftUI

struct TestFailure: Error, CustomStringConvertible { let description: String }

@MainActor
@main
enum TestMain {
    static var passed = 0
    static var failed = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String = "Expectation failed", file: String = #fileID, line: Int = #line) throws {
        if !condition() { throw TestFailure(description: "\(file):\(line): \(message)") }
    }
    static func wait(_ condition: () -> Bool, milliseconds: Int = 1000) async throws {
        for _ in 0..<milliseconds {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try expect(condition(), "Timed out waiting for expected state")
    }
    static func test(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); passed += 1; print("PASS \(name)") }
        catch { failed += 1; print("FAIL \(name): \(error)") }
    }

    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Diagnostics.shared.enabled = false
        for color in HeadphoneColor.allCases {
            if let image = NSImage(contentsOfFile: "Resources/\(color.imageName).png") { image.setName(NSImage.Name(color.imageName)) }
        }
        await protocolTests()
        await storeTests()
        await interfaceTests()
        await accessibilityTests()
        await popoverTests()
        await soundQualityTests()
        await nativeFieldTests()
        for color in [HeadphoneColor.black, .silver, .blue] {
            let name = HeadphoneModel.xm4.imageName(color: color)
            if let image = NSImage(contentsOfFile: "Resources/\(name).png") { image.setName(NSImage.Name(name)) }
        }
        await headphoneColorTests()
        await modelSupportTests()
        await xm4FeatureTests()
        print("\n\(passed) tests passed; \(failed) failed.")
        exit(failed == 0 ? 0 : 1)
    }

    static func protocolTests() async {
        await test("Wire fixtures, fragmentation, escaping, recovery and sleep policy") { CoreChecks.run() }
        await test("Reject illegal escape sequences and recover") {
            let parser = SonyMDRFrameParser()
            let valid = SonyMDRFraming.encode(SonyMDRPacket(dataType: 12, sequence: 0, payload: [0, 0]))
            try expect(parser.append(Data([62, 61, 0, 60])).isEmpty)
            try expect(parser.append(valid).count == 1)
        }
        await test("Parser handles every byte and every split boundary") {
            let payload = Array(UInt8.min...UInt8.max)
            let packet = SonyMDRPacket(dataType: 12, sequence: 1, payload: payload)
            let frame = SonyMDRFraming.encode(packet)
            for split in 0...frame.count {
                let parser = SonyMDRFrameParser()
                let found = parser.append(frame.prefix(split)) + parser.append(frame.suffix(frame.count - split))
                try expect(found == [packet], "Frame split \(split) failed")
            }
        }
        await test("Truncated or mismatched-length frames never publish state") {
            let parser = SonyMDRFrameParser()
            try expect(parser.append(Data([62, 12, 0, 0, 0, 0, 2, 0, 12, 60])).isEmpty)
            try expect(parser.append(Data([62, 12, 60])).isEmpty)
            parser.reset()
        }
        await test("Handshake loads model, battery, codec, mode and volume") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            try expect(rig.store.state.modelName == "WH-1000XM3")
            try expect(rig.store.state.batteryPercent == 88 && rig.store.state.codecName == "AAC")
            try expect(rig.store.state.noiseMode == .noiseCancellation && rig.store.state.volume == 9)
            try expect(rig.transport.sent.contains { $0.dataType == 1 }, "Device replies must be ACKed")
        }
        await test("Bad init version fails with useful error") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.transport.initReply = [1, 0]
            rig.client.connect(address: "test", deviceName: "WH-1000XM3")
            try await wait { if case .failed = rig.client.connectionState { return true }; return false }
        }
        await test("V2 headphones are rejected by the V1 adapter") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.transport.initReply = [1, 0, 0, 0, 0, 0, 0, 0]
            rig.client.connect(address: "test", deviceName: "WH-1000XM3")
            try await wait { if case .failed(let reason) = rig.client.connectionState { return reason.contains("V2") }; return false }
        }
        await test("Noise and ambient changes verified by readback; values clamped") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.setMode(.off)
            try await wait { rig.store.state.noiseMode == .off }
            rig.client.setAmbient(level: 500, focusOnVoice: true)
            try await wait { rig.store.state.noiseMode == .ambient && rig.store.state.focusOnVoice }
            try expect(rig.store.state.ambientLevel == 20)
            rig.client.setAmbient(level: -4, focusOnVoice: false)
            try await wait { rig.store.state.ambientLevel == 1 && !rig.store.state.focusOnVoice }
            rig.store.setMode(.noiseCancellation)
            try await wait { rig.store.state.noiseMode == .noiseCancellation }
        }
        await test("Short and wrong-subtype replies do not overwrite valid state") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            let original = rig.client.state
            for payload: [UInt8] in [[], [0x11], [0x11, 9, 0, 0], [0x67, 2], [0x67, 0, 0, 0, 0, 0, 0, 0], [0x19], [0xA7, 1, 0], [0x05, 1, 50]] { rig.transport.emit(payload) }
            try expect(rig.client.state == original)
        }
        await test("Hardware notifications update battery, codec and noise mode") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.transport.emit([0x13, 0, 75, 1])
            rig.transport.emit([0x1B, 0, 0x10])
            rig.transport.emit([0x69, 2, 1, 2, 1, 1, 0, 0])
            try expect(rig.store.state.batteryPercent == 75 && rig.store.state.isCharging == true)
            try expect(rig.store.state.codecName == "LDAC" && rig.store.state.noiseMode == .windReduction)
            for (code, name): (UInt8, String) in [(1,"SBC"),(2,"AAC"),(0x20,"aptX"),(0x21,"aptX HD")] {
                rig.transport.emit([0x19, 0, code]); try expect(rig.store.state.codecName == name)
            }
            rig.transport.emit([0x19, 0, 255]); try expect(rig.store.state.codecName == nil)
            rig.transport.emit([0x11, 0, 255, 2]); try expect(rig.store.state.batteryPercent == 100)
        }
        await test("Wrong ACK cannot release a queued command") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            rig.transport.autoRespond = false
            rig.client.setNoiseMode(.off)
            let sent = rig.transport.commands.count
            let flight = rig.transport.commands.last!
            rig.client.setNoiseMode(.ambient)
            rig.transport.emit([], type: 1, sequence: flight.sequence)
            try expect(rig.transport.commands.count == sent)
            rig.transport.ack(flight)
            try expect(rig.transport.commands.count == sent + 1)
        }
        await test("Rapid ambient changes coalesce to the latest request") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            rig.transport.autoRespond = false
            rig.client.setAmbient(level: 3, focusOnVoice: false)
            let flight = rig.transport.commands.last!
            rig.client.setAmbient(level: 8, focusOnVoice: false)
            rig.client.setAmbient(level: 17, focusOnVoice: true)
            rig.transport.ack(flight)
            try expect(rig.transport.commands.last?.payload == [0x68,2,0x11,2,0,1,1,17])
        }
        await test("Critical commands retry once and then fail") {
            let transport = FakeTransport(); transport.autoRespond = false
            let client = SonyV1Client(transport: transport, commandTimeout: .milliseconds(5))
            defer { client.disconnect() }
            client.connect(address: "test", deviceName: "WH-1000XM3")
            try await wait { if case .failed = client.connectionState { return true }; return false }
            try expect(transport.commands.count == 2 && transport.commands[0] == transport.commands[1])
        }
        await test("Write errors fail and disconnect the transport") {
            let transport = FakeTransport(); transport.writeFails = true
            let client = SonyV1Client(transport: transport); defer { client.disconnect() }
            client.connect(address: "test", deviceName: "WH-1000XM3")
            if case .failed(let reason) = client.connectionState { try expect(reason.contains("write")) }
            else { throw TestFailure(description: "Expected write failure") }
            try expect(transport.disconnectCount > 0)
        }
        await test("Disconnect cancels retries and clears cached device state") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.client.disconnect()
            let count = rig.transport.sent.count
            try await Task.sleep(for: .milliseconds(120))
            try expect(rig.transport.sent.count == count && rig.client.state == SonyV1State())
        }
        await test("Unknown opcodes are ACKed without changing state") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            let original = rig.client.state
            let ackCount = rig.transport.sent.filter { $0.dataType == 1 }.count
            rig.transport.emit([0xFE, 7, 8])
            try expect(rig.client.state == original)
            try expect(rig.transport.sent.filter { $0.dataType == 1 }.count == ackCount + 1)
        }
        await test("Extended Sony replies parse safely") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            for payload: [UInt8] in [[0x57,1,0xA1,6,12,10,11,12,13,14], [0x49,1,3], [0x49,2,0x11], [0xE9,2,0,1], [0xE9,1,0,1], [0xD9,0xD2,1,0], [0xF9,4,1,1,1], [0x85,1,0,1], [0x87,1,0,0,0,9]] { rig.transport.emit(payload) }
            try expect(rig.client.state.equalizerPreset == .custom1)
            try expect(rig.client.state.equalizerBands == [0,1,2,3,4,2])
            try expect(rig.client.state.surroundMode == .concertHall && rig.client.state.soundPosition == .rearLeft)
            try expect(rig.client.state.dseeEnabled == true && rig.client.state.touchSensorEnabled == false)
            try expect(rig.client.state.automaticPowerOff == .after30Minutes && rig.client.state.atmosphericPressure == 0.9)
        }
        await test("Known model profiles encode safe noise commands") {
            let profile = SonyV1DeviceProfile(deviceName: "WH-1000XM3")
            try expect(profile.features.contains(.equalizer))
            let off = profile.noisePayload(mode: .off, ambientLevel: 10, reportedNCType: 1, reportedASMType: 0, reportedASMID: 1)
            try expect(off == [0x68,2,0,2,0,1,0,0])
            let wind = profile.noisePayload(mode: .windReduction, ambientLevel: 10, reportedNCType: 1, reportedASMType: 0, reportedASMID: 1)
            try expect(wind == [0x68,2,0x11,2,1,1,0,0])
            let unknown = SonyV1DeviceProfile(deviceName: "other")
            try expect(unknown.features.isEmpty)
            try expect(unknown.noisePayload(mode: .ambient, ambientLevel: 100, reportedNCType: 1, reportedASMType: 1, reportedASMID: 1) == [0x68,2,0x11,1,0,1,1,20])
        }
        await test("Native transport rejects invalid addresses and idle writes") {
            let transport = SonyRFCOMMTransport()
            try expect(transport.send(Data([1])) == kIOReturnNotOpen)
            transport.connect(address: "invalid")
            if case .failed = transport.status {} else { throw TestFailure(description: "Invalid address accepted") }
            transport.disconnect(); try expect(transport.status == .idle)
        }
        await test("Noncritical command timeout advances the queue") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            rig.transport.autoRespond = false
            rig.client.setNoiseMode(.off)
            let flight = rig.transport.commands.last!
            rig.client.setAmbient(level: 6, focusOnVoice: false)
            try await wait { rig.transport.commands.contains { $0.payload == [0x68,2,0x11,2,0,1,0,6] } }
            try expect(rig.transport.commands.filter { $0 == flight }.count == 2)
        }
        await test("Disconnected client ignores setters and refresh requests") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.client.refresh(); rig.client.refreshBattery()
            rig.client.setNoiseMode(.off); rig.client.setAmbient(level: 2, focusOnVoice: true)
            rig.client.setAmbientLevel(4); rig.client.setVolume(22)
            try expect(rig.transport.sent.isEmpty)
        }
        await test("Sidetone research probe sends only explicit read inquiries") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            let count = rig.transport.commands.count
            rig.client.inspectCallCapabilities()
            try await wait { rig.transport.commands.count >= count + 6 }
            let inquiries = Array(rig.transport.commands.dropFirst(count)).map(\.payload)
            try expect(inquiries == [[6,0],[0xD0,0xD1,1],[0xD0,0xD2,1],[0xD0,0xD3,1],[0xF0,8],[0xF6,8]])
            try expect(!inquiries.contains { [0x68,0xD8,0xF8].contains($0.first ?? 0) })
        }
        await test("Sidetone inquiry is never run while disconnected or implicitly on refresh") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.client.inspectCallCapabilities(); try expect(rig.transport.sent.isEmpty)
            rig.client.connect(address: "test", deviceName: "WH-1000XM3")
            try await wait { rig.client.connectionState == .ready && rig.client.state.volume != nil }
            rig.client.refresh()
            try await Task.sleep(for: .milliseconds(20))
            try expect(!rig.transport.commands.contains { $0.payload == [6,0] || $0.payload.first == 0xD0 || $0.payload == [0xF6,8] })
        }
        await test("Extended setters use known payloads and verify after ACK") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            rig.client.setEqualizerPreset(.bright)
            rig.client.setEqualizerBands([-20, 0, 1, 5, 20, 4])
            rig.client.setSurroundMode(.arena); rig.client.setSoundPosition(.front)
            rig.client.setDSEE(enabled: true); rig.client.setSoundQualityMode(.prioritizeStableConnection)
            rig.client.setTouchSensor(enabled: false); rig.client.setAutomaticPowerOff(.after30Minutes)
            rig.client.setOptimizerRunning(true); rig.client.setAmbientLevel(5); rig.client.setVolume(99)
            try await wait { rig.transport.commands.contains { $0.payload == [0xA8, 1, 0x20, 30] } }
            let payloads = rig.transport.commands.map(\.payload)
            for expected: [UInt8] in [[0x58,1,0x10,0], [0x58,1,255,6,14,0,10,11,15,20], [0x48,1,2], [0x48,2,3], [0xE8,2,0,1], [0xE8,1,0,1], [0xD8,0xD2,1,0], [0xF8,4,1,1,1], [0x84,1,0,1]] {
                try expect(payloads.contains(expected), "Missing expected feature command \(expected)")
            }
        }
    }

    static func storeTests() async {
        await test("Default preferences and appearance fallback") {
            let rig = TestRig(); defer { rig.close() }
            try expect(rig.store.appearance == .device && rig.store.disconnectOnSleep && !rig.store.reconnectAfterUnlock && !rig.store.showBattery)
            try expect(AppAppearance(savedValue: "future-theme") == .device)
            try expect(AppAppearance.device.native == nil)
            try expect(AppAppearance.light.native?.name == .aqua && AppAppearance.dark.native?.name == .darkAqua)
        }
        await test("Appearance and toggles persist across store recreation") {
            let rig = TestRig(); defer { rig.close() }
            rig.store.appearance = .dark; rig.store.showBattery = true
            rig.store.disconnectOnSleep = false; rig.store.reconnectAfterUnlock = true
            rig.store.shutdown()
            let second = HeadphoneStore(defaults: rig.defaults, platform: FakePlatform(), client: SonyV1Client(transport: FakeTransport()))
            defer { second.shutdown() }
            try expect(second.appearance == .dark && second.showBattery && !second.disconnectOnSleep && second.reconnectAfterUnlock)
            second.appearance = .light
            try expect(rig.defaults.string(forKey: "appearance") == "light")
        }
        await test("Hardware volume notifications update state without writing back") {
            let rig = TestRig(); defer { rig.close() }
            rig.platform.externalVolume(0.73)
            try expect(rig.store.outputVolume == 0.73 && rig.platform.volumeWrites.isEmpty)
            rig.platform.externalVolume(nil)
            try expect(rig.store.outputVolume == nil)
        }
        await test("App volume writes use system readback and report failures") {
            let rig = TestRig(); defer { rig.close() }
            rig.store.setVolume(0.22)
            try expect(rig.platform.volume == 0.22 && rig.store.outputVolume == 0.22)
            rig.platform.writeSucceeds = false
            rig.store.setVolume(0.7)
            try expect(rig.store.outputVolume == 0.22 && rig.store.notice?.contains("volume") == true)
        }
        await test("Manual disconnect is respected; manual connect works") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.disconnect()
            let count = rig.transport.connectCount
            rig.platform.isConnected = true; rig.platform.onConnection?()
            try expect(rig.transport.connectCount == count)
            rig.store.connect()
            try await wait { rig.store.ready }
            try expect(rig.transport.connectCount == count + 1)
        }
        await test("Sleep disconnect blocks background reconnection until unlock") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.platform.onSleep?()
            try expect(!rig.platform.isConnected && rig.platform.disconnectCount == 1)
            let count = rig.transport.connectCount
            rig.platform.onWake?()
            rig.platform.isConnected = true; rig.platform.onConnection?()
            try expect(rig.platform.disconnectCount == 2 && rig.transport.connectCount == count)
            rig.platform.onUnlock?()
            try expect(rig.store.connectionLabel == "Disconnected after sleep")
            rig.store.connect(); try await wait { rig.store.ready }
        }
        await test("Optional reconnect happens once after unlock, never just wake") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.reconnectAfterUnlock = true
            let count = rig.transport.connectCount
            rig.platform.onSleep?(); rig.platform.onWake?()
            try expect(rig.transport.connectCount == count)
            rig.platform.onUnlock?(); try await wait { rig.store.ready }
            try expect(rig.transport.connectCount == count + 1)
            rig.platform.onUnlock?(); try expect(rig.transport.connectCount == count + 1)
        }
        await test("Unlock arriving before wake is handled") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.reconnectAfterUnlock = true
            rig.platform.onSleep?(); rig.platform.onUnlock?()
            try await wait { rig.store.ready }
            rig.platform.onWake?(); try expect(rig.store.ready)
        }
        await test("Disabling sleep disconnect preserves audio and pauses control work") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.disconnectOnSleep = false
            rig.platform.onSleep?()
            try expect(rig.platform.isConnected && rig.platform.disconnectCount == 0 && !rig.store.ready)
            rig.platform.onWake?(); try await wait { rig.store.ready }
        }
        await test("Sleep does not steal manually disconnected headphones") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.reconnectAfterUnlock = true; rig.store.disconnect()
            let count = rig.transport.connectCount
            rig.platform.onSleep?(); rig.platform.onWake?(); rig.platform.onUnlock?()
            try expect(rig.transport.connectCount == count)
        }
        await test("Disconnect errors are visible") {
            let rig = TestRig(); defer { rig.close() }
            rig.platform.disconnectResult = kIOReturnError
            rig.store.disconnect()
            try expect(rig.store.notice?.contains("Could not disconnect") == true)
        }
        await test("Unpaired device gets pairing guidance, no connection attempts") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.platform.isPaired = false; rig.platform.address = nil
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try expect(rig.store.notice?.contains("Pair WH-1000XM3") == true && rig.transport.connectCount == 0)
        }
        await test("Connect events discover an already paired offline headset") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.platform.isConnected = false
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client)
            try expect(rig.transport.connectCount == 0)
            rig.platform.isConnected = true; rig.platform.onConnection?()
            try await wait { rig.store.ready }
        }
        await test("Retries stop after the configured budget") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.transport.connectFails = true
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client, retryDelays: [.milliseconds(2), .milliseconds(3)])
            try await wait { rig.transport.connectCount == 3 }
            try await Task.sleep(for: .milliseconds(40))
            try expect(rig.transport.connectCount == 3)
            rig.transport.connectFails = false; rig.store.connect()
            try await wait { rig.store.ready }
        }
        await test("Sleep cancels pending retries") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.transport.connectFails = true
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client, retryDelays: [.milliseconds(20)])
            rig.platform.onSleep?()
            try await Task.sleep(for: .milliseconds(40))
            try expect(rig.transport.connectCount == 1)
        }
        await test("Idle connected app does no polling and sends no keepalive packets") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            let count = rig.transport.sent.count
            let checks = rig.store.connectionCheckCount
            try await Task.sleep(for: .milliseconds(200))
            try expect(rig.transport.sent.count == count && rig.store.connectionCheckCount == checks)
        }
        await test("Rapid ambient UI edits debounce to the latest value") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.setAmbient(level: 3); rig.store.setAmbient(level: 7); rig.store.setAmbient(level: 12)
            try await wait { rig.store.state.ambientLevel == 12 }
            try expect(rig.store.state.ambientLevel == 12)
            try expect(rig.transport.commands.filter { $0.payload.first == 0x68 }.count == 1)
        }
        await test("Mode switch cancels queued ambient slider edits") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.setAmbient(level: 15); rig.store.setMode(.off)
            try await Task.sleep(for: .milliseconds(250))
            try expect(rig.store.state.noiseMode == .off)
        }
        await test("Login setting reads actual status and errors are visible") {
            let rig = TestRig(); defer { rig.close() }
            rig.store.setLaunchAtLogin(true); try expect(rig.store.launchAtLogin)
            rig.store.setLaunchAtLogin(false); try expect(!rig.store.launchAtLogin)
            rig.platform.loginThrows = true; rig.store.setLaunchAtLogin(true)
            try expect(!rig.store.launchAtLogin && rig.store.notice?.contains("Login setting") == true)
        }
        await test("Shutdown removes subscriptions and cancels pending commands") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.setAmbient(level: 15); rig.store.shutdown(); rig.store.shutdown()
            let count = rig.transport.sent.count
            try await Task.sleep(for: .milliseconds(220))
            try expect(rig.platform.stopped && rig.platform.onConnection == nil && rig.platform.onVolume == nil)
            try expect(rig.transport.sent.count == count)
            rig.store.connect(); rig.store.refresh(); try expect(rig.transport.sent.count == count)
        }
        await test("Sleep cancels an unsent ambient command") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            rig.store.setAmbient(level: 15); rig.platform.onSleep?()
            try await Task.sleep(for: .milliseconds(220))
            try expect(!rig.transport.commands.contains { $0.payload.first == 0x68 })
        }
        await test("Refresh explicitly rereads status without a periodic timer") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.volume != nil }
            rig.platform.volume = 0.81
            let count = rig.transport.commands.count
            rig.store.refresh()
            try await wait { rig.transport.commands.count >= count + 4 }
            try expect(rig.store.outputVolume == 0.81)
        }
        await test("Manual disconnect cancels pending reconnection retries") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.transport.connectFails = true
            rig.store = HeadphoneStore(defaults: rig.defaults, platform: rig.platform, client: rig.client, retryDelays: [.milliseconds(20)])
            rig.store.disconnect()
            try await Task.sleep(for: .milliseconds(40))
            try expect(rig.transport.connectCount == 1)
        }
        await test("Normal operation does not collect diagnostic logs") {
            let count = Diagnostics.shared.entries.count
            Diagnostics.shared.log("not collected")
            try expect(Diagnostics.shared.entries.count == count)
        }
        await test("Microphone selector reads current input without changing it") {
            let rig = TestRig(); defer { rig.close() }
            try expect(rig.store.microphones.devices.count == 2 && rig.store.microphones.selectedID == 2)
            try expect(rig.platform.microphoneSelections.isEmpty)
        }
        await test("User can switch microphone in either direction") {
            let rig = TestRig(); defer { rig.close() }
            rig.store.selectMicrophone(1)
            try expect(rig.store.microphones.selectedID == 1 && rig.store.notice == nil)
            rig.store.selectMicrophone(2)
            try expect(rig.store.microphones.selectedID == 2 && rig.platform.microphoneSelections == [1, 2])
        }
        await test("External microphone changes update the selector without writing back") {
            let rig = TestRig(); defer { rig.close() }
            rig.platform.microphones.selectedID = 1
            rig.platform.onMicrophones?(rig.platform.microphones)
            try expect(rig.store.microphones.selectedID == 1 && rig.platform.microphoneSelections.isEmpty)
        }
        await test("Unavailable microphone is rejected and refreshed") {
            let rig = TestRig(); defer { rig.close() }
            rig.platform.microphones.devices.removeAll { $0.id == 2 }
            rig.platform.onMicrophones?(rig.platform.microphones)
            rig.store.selectMicrophone(2)
            try expect(rig.platform.microphoneSelections.isEmpty && rig.store.notice?.contains("no longer available") == true)
        }
        await test("Microphone write failure keeps the actual input selected") {
            let rig = TestRig(); defer { rig.close() }
            rig.platform.microphoneSelectionSucceeds = false
            rig.store.selectMicrophone(1)
            try expect(rig.store.microphones.selectedID == 2 && rig.store.notice?.contains("could not change") == true)
        }
        await test("Unconfirmed microphone change is reported instead of assumed") {
            let rig = TestRig(); defer { rig.close() }
            rig.platform.microphoneReadbackSucceeds = false
            rig.store.selectMicrophone(1)
            try expect(rig.store.microphones.selectedID == 2 && rig.store.notice?.contains("not confirmed") == true)
        }
        await test("Shutdown removes microphone observation and prevents routing changes") {
            let rig = TestRig(); defer { rig.close() }
            rig.store.shutdown(); rig.store.selectMicrophone(1)
            try expect(rig.platform.onMicrophones == nil && rig.platform.microphoneSelections.isEmpty)
        }
    }

    static func interfaceTests() async {
        await test("An existing panel follows live macOS appearance changes") {
            let rig = TestRig(); defer { rig.close(); NSApp.appearance = nil }
            let host = NSHostingView(rootView: HeadphonePanel(store: rig.store))
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 360,height: 750), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            NSApp.appearance = AppAppearance.dark.native
            try expect(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            NSApp.appearance = AppAppearance.light.native
            try expect(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
            NSApp.appearance = AppAppearance.device.native
            try expect(NSApp.appearance == nil)
            window.contentView = nil
        }
        await test("Light, Dark and Device settings and control panels render") {
            let rig = TestRig(); defer { rig.close(); NSApp.appearance = nil }
            try await wait { rig.store.ready }
            if let image = NSImage(contentsOfFile: "Resources/Headphones.png") { image.setName("Headphones") }
            try FileManager.default.createDirectory(atPath: "build/test-previews", withIntermediateDirectories: true)
            for mode in AppAppearance.allCases {
                rig.store.appearance = mode
                NSApp.appearance = mode.native
                for settings in [false, true] {
                    rig.store.settingsShown = settings
                    let host = NSHostingView(rootView: HeadphonePanel(store: rig.store))
                    let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 360,height: 750), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = mode.native
                    window.contentView = host
                    host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    try expect(abs(host.bounds.width - 360) < 1 && host.bounds.height > 200 && host.bounds.height < 800, "Invalid panel size for \(mode)")
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TestFailure(description: "Panel capture failed") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try expect(bitmap.pixelsWide >= 360 && bitmap.pixelsHigh > 0)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/test-previews/\(mode.rawValue)-\(settings ? "settings" : "controls").png"))
                    window.contentView = nil
                }
            }
        }
        await test("Disconnected, connecting, error and ambient states fit the panel") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready }
            for connection: SonyV1ClientConnectionState in [.disconnected, .connecting, .failed("Example failure"), .ready] {
                rig.store.connection = connection
                rig.store.state.noiseMode = .ambient
                rig.store.notice = "A representative error message that wraps across several lines."
                let host = NSHostingView(rootView: HeadphonePanel(store: rig.store))
                try expect(abs(host.fittingSize.width - 360) < 1 && host.fittingSize.height < 800)
            }
            rig.store.notice = nil
            for theme in [AppAppearance.light, .dark] {
                rig.store.appearance = theme
                for (index, mode) in [SonyV1NoiseMode.noiseCancellation, .ambient, .off].enumerated() {
                    rig.store.state.noiseMode = mode
                    let host = NSHostingView(rootView: HeadphonePanel(store: rig.store))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = theme.native
                    window.contentView = host
                    host.setFrameSize(host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw TestFailure(description: "Design preview failed") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "build/test-previews/design-\(theme.rawValue)-\(index).png"))
                    window.contentView = nil
                }
            }
        }
    }
}
