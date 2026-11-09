import AppKit
import Foundation
import IOBluetooth

@MainActor
final class FakeTransport: SonyRFCOMMTransporting {
    var onStatusChange: ((SonyRFCOMMStatus) -> Void)?
    var onData: ((Data) -> Void)?
    var status = SonyRFCOMMStatus.idle
    var sent: [SonyMDRPacket] = []
    var connectCount = 0
    var disconnectCount = 0
    var autoRespond = true
    var connectFails = false
    var writeFails = false
    var onConnect: (() -> Void)?
    var initReply: [UInt8] = [1, 0, 0x40, 0x10]
    var modelName = "WH-1000XM3"
    var colorReply: [UInt8]? = [5, 3, 0, 1]
    var xm4FeaturesRespond = false
    var featureWritesApply = true
    var speakToChat = true
    var conversationOptions = SonyConversationOptions()
    var wearDetection = true
    var wearPowerOff = true
    var dsee = false
    var multipoint = true
    var multipointSlot: UInt8 = 0xD2
    var dropConnectionOnMultipoint = false
    var multipointConfirmationSubscribed = false
    var requestedMultipoint: Bool?
    var soundQuality: UInt8 = 0
    var qualityWritesApply = true
    var qualityReplies = true
    var noise: [UInt8] = [0x67, 2, 1, 2, 2, 1, 0, 0]
    var sequence: UInt8 = 0
    private var generation = 0

    func connect(address: String) {
        connectCount += 1
        generation += 1
        status = .connecting; onStatusChange?(status)
        if connectFails { status = .failed("simulated failure") }
        else { onConnect?(); status = .connected }
        onStatusChange?(status)
    }

    func disconnect() {
        multipointConfirmationSubscribed = false; requestedMultipoint = nil
        disconnectCount += 1
        generation += 1
        status = .idle; onStatusChange?(status)
    }

    func send(_ data: Data) -> IOReturn {
        guard !writeFails else { return kIOReturnError }
        let packets = SonyMDRFrameParser().append(data)
        sent += packets
        for packet in packets where packet.dataType != SonyMDRPacket.ackType {
            if autoRespond {
                let expected = generation
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, self.generation == expected else { return }
                    self.ack(packet)
                    self.respond(packet.payload)
                }
            }
        }
        return kIOReturnSuccess
    }

    var commands: [SonyMDRPacket] { sent.filter { $0.dataType != SonyMDRPacket.ackType } }
    func ack(_ packet: SonyMDRPacket) { emit([], type: 1, sequence: packet.sequence ^ 1) }
    func emit(_ payload: [UInt8], type: UInt8 = 12, sequence specified: UInt8? = nil) {
        let number = specified ?? sequence
        sequence ^= 1
        onData?(SonyMDRFraming.encode(SonyMDRPacket(dataType: type, sequence: number, payload: payload)))
    }

    private func respond(_ payload: [UInt8]) {
        guard let opcode = payload.first else { return }
        switch opcode {
        case 0x00: emit(initReply)
        case 0x04:
            if payload == [4, 1] { emit([5, 1, UInt8(modelName.utf8.count)] + Array(modelName.utf8)) }
            else if payload == [4, 3], let colorReply { emit(colorReply) }
        case 0x10: emit([0x11, 0, 88, 0])
        case 0x18: emit([0x19, 0, 2])
        case 0x66: emit(noise)
        case 0x68:
            noise = payload; noise[0] = 0x69; emit(noise); noise[0] = 0x67
        case 0xA6: emit([0xA7, 1, 0x20, 9])
        case 0xF0 where xm4FeaturesRespond:
            if payload == [0xF0,3] { emit([0xF1,3,0]) }
            if payload == [0xF0,4] { emit([0xF1,4,2,0x10,0x11]) }
            if payload == [0xF0,5] { emit([0xF1,5,0,1,0,0,0,0,15,30,60,0]) }
        case 0xF6 where xm4FeaturesRespond:
            if payload == [0xF6,3] { emit([0xF7,3,0,wearDetection ? 1 : 0]) }
            if payload == [0xF6,4] { emit([0xF7,4,1,wearPowerOff ? 0x10 : 0x11,0]) }
            if payload == [0xF6,5] { emit([0xF7,5,0,speakToChat ? 1 : 0]) }
        case 0xFA where xm4FeaturesRespond:
            emit([0xFB] + conversationOptions.payload.dropFirst())
        case 0xFC where xm4FeaturesRespond:
            if featureWritesApply, let options = SonyConversationOptions(reply: [0xFB] + payload.dropFirst()) { conversationOptions = options }
            emit([0xFD] + conversationOptions.payload.dropFirst())
        case 0xF8 where xm4FeaturesRespond:
            if featureWritesApply, payload.count == 4 {
                if payload[1] == 3 && payload[2] == 0 { wearDetection = payload[3] == 1 }
                if payload[1] == 5 && payload[2] == 1 { speakToChat = payload[3] == 1 }
            }
            if featureWritesApply, payload.count == 5 && payload[1] == 4 { wearPowerOff = payload[3] == 0x10 }
        case 0xE0 where xm4FeaturesRespond:
            if payload == [0xE0,2] { emit([0xE1,2,2,0]) }
        case 0xD0 where xm4FeaturesRespond:
            if payload.count == 3 && payload[1] == multipointSlot {
                let name = Array("MULTIPOINT_SETTING".utf8), summary = Array("MULTIPOINT_SETTING_SUMMARY".utf8)
                emit([0xD1,multipointSlot,2,UInt8(name.count)] + name + [UInt8(summary.count)] + summary + [1,0])
            }
        case 0xD6 where xm4FeaturesRespond:
            if payload == [0xD6,multipointSlot] { emit([0xD7,multipointSlot,1,multipoint ? 1 : 0]) }
        case 0x94 where xm4FeaturesRespond:
            if payload == [0x94,1,0] { multipointConfirmationSubscribed = true }
        case 0x98 where xm4FeaturesRespond:
            if let desired = requestedMultipoint, payload == [0x98,1,desired ? 6 : 7,1] {
                requestedMultipoint = nil
                if featureWritesApply { multipoint = desired }
                if dropConnectionOnMultipoint {
                    dropConnectionOnMultipoint = false
                    status = .failed("Headset reconnecting after multipoint change"); onStatusChange?(status)
                } else { emit([0xD9,multipointSlot,1,multipoint ? 1 : 0]) }
            }
        case 0xD8 where xm4FeaturesRespond:
            if payload.count == 4 && payload[1] == multipointSlot && payload[2] == 1 {
                let desired = payload[3] == 1
                if multipointConfirmationSubscribed && multipoint != desired {
                    requestedMultipoint = desired
                    emit([0x99,1,desired ? 6 : 7,1])
                } else { emit([0xD9,multipointSlot,1,multipoint ? 1 : 0]) }
            }
        case 0xE6:
            if payload == [0xE6,2], xm4FeaturesRespond { emit([0xE7,2,0,dsee ? 1 : 0]) }
            if payload == [0xE6, 1], qualityReplies { emit([0xE7, 1, 0, soundQuality]) }
        case 0xE8:
            if payload.count == 4, payload[1] == 2, xm4FeaturesRespond {
                if featureWritesApply { dsee = payload[3] == 1 }
                emit([0xE9,2,0,dsee ? 1 : 0])
            }
            if payload.count == 4, payload[1] == 1, payload[2] == 0, qualityWritesApply { soundQuality = payload[3] }
        default: break
        }
    }
}

@MainActor
final class FakePlatform: HeadphonePlatform {
    var devices: [HeadphoneDevice] = []
    var selectionLocked = false
    func lockSelection(_ locked: Bool) { selectionLocked = locked }
    var modelName = "WH-1000XM3"
    var preferredDeviceID: String?
    func selectDevice(_ id: String?) { preferredDeviceID = id; onConnection?() }
    var isPaired = true
    var isConnected = true
    var address: String? = "00-11-22-33-44-55"
    var loginEnabled = false
    var volumeEventCount = 0
    var volume: Double? = 0.4
    var volumeWrites: [Double] = []
    var writeSucceeds = true
    var microphones = MicrophoneState(devices: [MicrophoneDevice(id: 1, name: "MacBook Pro Microphone"), MicrophoneDevice(id: 2, name: "WH-1000XM3")], selectedID: 2)
    var microphoneSelections: [UInt32] = []
    var microphoneSelectionSucceeds = true
    var microphoneReadbackSucceeds = true
    var onMicrophones: ((MicrophoneState) -> Void)?
    var disconnectResult: IOReturn = 0
    var disconnectCount = 0
    var loginThrows = false
    var stopped = false
    var onConnection: (() -> Void)?
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    var onUnlock: (() -> Void)?
    var onVolume: ((Double?) -> Void)?

    func disconnect() -> IOReturn {
        disconnectCount += 1
        if disconnectResult == 0 { isConnected = false }
        return disconnectResult
    }
    func readVolume() -> Double? { volume }
    func writeVolume(_ value: Double) -> Bool {
        guard writeSucceeds else { return false }
        volume = min(1, max(0, value)); volumeWrites.append(value)
        onVolume?(volume)
        return true
    }
    func setLogin(_ enabled: Bool) throws {
        if loginThrows { throw NSError(domain: "Login", code: 1) }
        loginEnabled = enabled
    }
    func readMicrophones() -> MicrophoneState { microphones }
    func observeMicrophones(_ changed: @escaping (MicrophoneState) -> Void) { onMicrophones = changed; changed(microphones) }
    func selectMicrophone(_ id: UInt32) -> Bool {
        guard microphoneSelectionSucceeds else { return false }
        microphoneSelections.append(id)
        if microphoneReadbackSucceeds { microphones.selectedID = id; onMicrophones?(microphones) }
        return true
    }
    func start(connection: @escaping () -> Void, sleep: @escaping () -> Void, wake: @escaping () -> Void, unlock: @escaping () -> Void, volume: @escaping (Double?) -> Void) {
        onConnection = connection; onSleep = sleep; onWake = wake; onUnlock = unlock; onVolume = volume
        volume(self.volume)
    }
    func refreshVolume() { onVolume?(volume) }
    func stop() { stopped = true; onConnection = nil; onSleep = nil; onWake = nil; onUnlock = nil; onVolume = nil; onMicrophones = nil }
    func externalVolume(_ value: Double?) { volume = value; volumeEventCount += 1; onVolume?(value) }
}

@MainActor
final class TestRig {
    let transport = FakeTransport()
    let platform = FakePlatform()
    let defaults: UserDefaults
    let suite = "local.sonymenu.tests.\(UUID().uuidString)"
    var client: SonyV1Client!
    var store: HeadphoneStore!
    init(start: Bool = true, retryDelays: [Duration] = [.milliseconds(3), .milliseconds(5)], commandTimeout: Duration = .milliseconds(300)) {
        defaults = UserDefaults(suiteName: suite)!
        transport.onConnect = { [weak platform] in platform?.isConnected = true }
        client = SonyV1Client(transport: transport, commandTimeout: commandTimeout)
        if start { store = HeadphoneStore(defaults: defaults, platform: platform, client: client, retryDelays: retryDelays) }
    }
    func close() { store?.shutdown(); client.disconnect(); defaults.removePersistentDomain(forName: suite) }
}
