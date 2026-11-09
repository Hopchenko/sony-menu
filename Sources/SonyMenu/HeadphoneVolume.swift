import CoreAudio
import Foundation

/// Only touches the Sony output device, even when another output is default.
enum HeadphoneVolume {
    fileprivate static func output(target: String? = nil) -> AudioDeviceID? {
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
            guard HeadphoneModel(deviceName: name.takeRetainedValue() as String) != nil else { return false }
            if let target {
                var uid: Unmanaged<CFString>?
                var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return false }
                let normalizedUID = (uid.takeRetainedValue() as String).lowercased().filter { $0.isHexDigit }
                let normalizedTarget = target.lowercased().filter { $0.isHexDigit }
                guard !normalizedTarget.isEmpty, normalizedUID.contains(normalizedTarget) else { return false }
            }
            var streamAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }

    static func read(target: String? = nil) -> Double? {
        guard let device = output(target: target) else { return nil }
        for element: UInt32 in [0, 1] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return Double(value) }
        }
        return nil
    }

    static func write(_ value: Double, target: String? = nil) -> Bool {
        guard let device = output(target: target) else { return false }
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
    private let target: () -> String?
    private(set) var volumeEventCount = 0

    init(target: @escaping () -> String? = { nil }, onChange: @escaping (Double?) -> Void) {
        self.target = target
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
        let device = HeadphoneVolume.output(target: target())
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
                            self.onChange(HeadphoneVolume.read(target: self.target()))
                        }
                    }
                    if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                        deviceListeners.append(Listener(object: device, address: address, block: block))
                    }
                }
            }
        }
        onChange(HeadphoneVolume.read(target: self.target()))
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
