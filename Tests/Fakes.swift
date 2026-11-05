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
        case 0x04: emit([5, 1, 10] + Array("WH-1000XM3".utf8))
        case 0x10: emit([0x11, 0, 88, 0])
        case 0x18: emit([0x19, 0, 2])
        case 0x66: emit(noise)
        case 0x68:
            noise = payload; noise[0] = 0x69; emit(noise); noise[0] = 0x67
        case 0xA6: emit([0xA7, 1, 0x20, 9])
        default: break
        }
    }
}

@MainActor
final class FakePlatform: HeadphonePlatform {
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
