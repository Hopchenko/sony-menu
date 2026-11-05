import CoreAudio
import Foundation

/// Only touches the Sony output device, even when another output is default.
enum HeadphoneVolume {
    fileprivate static func output() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty else { return nil }
        let status = devices.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return nil }
        return devices.first { device in
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let name else { return false }
            guard (name.takeRetainedValue() as String) == "WH-1000XM3" else { return false }
            var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }

    static func read() -> Double? {
        guard let device = output() else { return nil }
        for element: UInt32 in [0, 1] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return Double(value) }
        }
        return nil
    }

    static func write(_ value: Double) -> Bool {
        guard let device = output() else { return false }
        var wrote = false
        for element: UInt32 in [0, 1, 2] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var scalar = Float32(min(1, max(0, value)))
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar) == noErr { wrote = true }
            if element == 0 && wrote { break }
        }
        return wrote
    }
}

/// Read-only notifications keep macOS, AVRCP changes, and the panel in sync
/// without writing a stale value back to the headphones.
@MainActor
final class HeadphoneVolumeObserver {
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var systemListener: Listener?
    private var deviceListeners: [Listener] = []
    private var observedDevice: AudioDeviceID?
    private var stopped = false
    private let onChange: (Double?) -> Void
    private(set) var volumeEventCount = 0

    init(onChange: @escaping (Double?) -> Void) {
        self.onChange = onChange
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        if AudioObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr {
            systemListener = Listener(object: system, address: address, block: block)
        }
        refresh()
    }

    func refresh() {
        guard !stopped else { return }
        let device = HeadphoneVolume.output()
        if observedDevice != device || deviceListeners.isEmpty {
            removeDeviceListeners()
            observedDevice = device
            if let device {
                for element: UInt32 in [0, 1, 2] {
                    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
                    guard AudioObjectHasProperty(device, &address) else { continue }
                    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                        Task { @MainActor [weak self] in
                            guard let self, !self.stopped else { return }
                            self.volumeEventCount += 1
                            self.onChange(HeadphoneVolume.read())
                        }
                    }
                    if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                        deviceListeners.append(Listener(object: device, address: address, block: block))
                    }
                }
            }
        }
        onChange(HeadphoneVolume.read())
    }

    func stop() {
        stopped = true
        removeDeviceListeners()
        if var listener = systemListener {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        systemListener = nil
        observedDevice = nil
    }

    private func removeDeviceListeners() {
        for var listener in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        deviceListeners.removeAll()
    }
}
