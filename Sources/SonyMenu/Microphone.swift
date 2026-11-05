import CoreAudio
import Foundation

struct MicrophoneDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}

struct MicrophoneState: Equatable {
    var devices: [MicrophoneDevice] = []
    var selectedID: AudioDeviceID = kAudioObjectUnknown
}

/// Changes routing only. No audio is captured, recorded, or streamed here.
enum MacMicrophone {
    static func read() -> MicrophoneState {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var selected = AudioDeviceID(kAudioObjectUnknown)
        var selectedSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var selectedAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(system, &selectedAddress, 0, nil, &selectedSize, &selected)
        var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr, size > 0 else { return MicrophoneState() }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return MicrophoneState() }
        let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { return MicrophoneState() }
        let inputs = ids.compactMap { id -> MicrophoneDevice? in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return nil }
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr, let name else { return nil }
            return MicrophoneDevice(id: id, name: name.takeRetainedValue() as String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return MicrophoneState(devices: inputs, selectedID: selected)
    }

    static func select(_ id: AudioDeviceID) -> Bool {
        guard read().devices.contains(where: { $0.id == id }) else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var selected = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &selected) == noErr
    }
}

@MainActor
final class MicrophoneObserver {
    private struct Listener {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var listeners: [Listener] = []
    private var stopped = false
    private let changed: (MicrophoneState) -> Void

    init(changed: @escaping (MicrophoneState) -> Void) {
        self.changed = changed
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
                listeners.append(Listener(address: address, block: block))
            }
        }
        refresh()
    }
    func refresh() { if !stopped { changed(MacMicrophone.read()) } }
    func stop() {
        stopped = true
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listener.address, .main, listener.block)
        }
        listeners.removeAll()
    }
}
