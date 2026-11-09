import AppKit
import IOBluetooth
import ServiceManagement

@MainActor
protocol HeadphonePlatform: AnyObject {
    var devices: [HeadphoneDevice] { get }
    var modelName: String { get }
    var preferredDeviceID: String? { get }
    func selectDevice(_ id: String?)
    func lockSelection(_ locked: Bool)
    var isPaired: Bool { get }
    var isConnected: Bool { get }
    var address: String? { get }
    var loginEnabled: Bool { get }
    var volumeEventCount: Int { get }
    func disconnect() -> IOReturn
    func readVolume() -> Double?
    func writeVolume(_ value: Double) -> Bool
    func readMicrophones() -> MicrophoneState
    func selectMicrophone(_ id: UInt32) -> Bool
    func observeMicrophones(_ changed: @escaping (MicrophoneState) -> Void)
    func setLogin(_ enabled: Bool) throws
    func start(connection: @escaping () -> Void, sleep: @escaping () -> Void, wake: @escaping () -> Void, unlock: @escaping () -> Void, volume: @escaping (Double?) -> Void)
    func refreshVolume()
    func stop()
}

/// Owns operating-system subscriptions. No repeating timers or audio polling.
@MainActor
final class MacHeadphonePlatform: NSObject, HeadphonePlatform {
    private var device: IOBluetoothDevice?
    private var selectionLocked = false
    func lockSelection(_ locked: Bool) { selectionLocked = locked }
    private(set) var devices: [HeadphoneDevice] = []
    private let defaults = UserDefaults.standard
    var preferredDeviceID: String? { defaults.string(forKey: "selectedHeadphoneID") }
    var modelName: String { device?.name ?? defaults.string(forKey: "lastHeadphoneModel") ?? "WH-1000XM3" }
    func selectDevice(_ id: String?) {
        defaults.set(id, forKey: "selectedHeadphoneID")
        findDevice()
        watchDisconnect()
        refreshVolume()
        onConnection?()
    }
    private var connectedNotification: IOBluetoothUserNotification?
    private var disconnectedNotifications: [IOBluetoothUserNotification] = []
    private var observers: [NSObjectProtocol] = []
    private var unlockObserver: NSObjectProtocol?
    private var volumeObserver: HeadphoneVolumeObserver?
    private var microphoneObserver: MicrophoneObserver?
    private var onConnection: (() -> Void)?
    private var stopped = false

    override init() { super.init(); findDevice() }
    var isPaired: Bool { findDevice(); return device != nil }
    var isConnected: Bool { device?.isConnected() ?? false }
    var address: String? { device?.addressString }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var volumeEventCount: Int { volumeObserver?.volumeEventCount ?? 0 }
    func disconnect() -> IOReturn { device?.closeConnection() ?? kIOReturnNotFound }
    func readVolume() -> Double? { guard let id = device?.addressString else { return nil }; return HeadphoneVolume.read(target: id) }
    func writeVolume(_ value: Double) -> Bool { guard let id = device?.addressString else { return false }; return HeadphoneVolume.write(value, target: id) }
    func readMicrophones() -> MicrophoneState { MacMicrophone.read() }
    func selectMicrophone(_ id: UInt32) -> Bool { MacMicrophone.select(id) }
    func observeMicrophones(_ changed: @escaping (MicrophoneState) -> Void) { microphoneObserver = MicrophoneObserver(changed: changed) }
    func setLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    func start(connection: @escaping () -> Void, sleep: @escaping () -> Void, wake: @escaping () -> Void, unlock: @escaping () -> Void, volume: @escaping (Double?) -> Void) {
        onConnection = connection
        connectedNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(didConnect(_:device:)))
        watchDisconnect()
        let center = NSWorkspace.shared.notificationCenter
        for (name, callback) in [(NSWorkspace.willSleepNotification, sleep), (NSWorkspace.didWakeNotification, wake)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { callback() } })
        }
        unlockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in MainActor.assumeIsolated { unlock() } }
        volumeObserver = HeadphoneVolumeObserver(target: { [weak self] in self?.device?.addressString ?? "" }, onChange: volume)
    }

    private func findDevice() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { HeadphoneModel(deviceName: $0.name ?? "") != nil }
        devices = paired.compactMap { d in
            guard let id = d.addressString, let name = d.name else { return nil }
            return HeadphoneDevice(id: id, name: name, connected: d.isConnected())
        }
        if selectionLocked { return }
        let selected = HeadphoneSelection.choose(devices, preferred: preferredDeviceID,
            current: device?.addressString, remembered: defaults.string(forKey: "lastHeadphoneID"))
        device = paired.first { $0.addressString == selected?.id }
        if let selected {
            defaults.set(selected.id, forKey: "lastHeadphoneID")
            defaults.set(selected.name, forKey: "lastHeadphoneModel")
        }
    }

    private func watchDisconnect() {
        disconnectedNotifications.forEach { $0.unregister() }
        disconnectedNotifications.removeAll()
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        for candidate in paired where candidate.isConnected() && HeadphoneModel(deviceName: candidate.name ?? "") != nil {
            if let notification = candidate.register(forDisconnectNotification: self, selector: #selector(didDisconnect(_:device:))) {
                disconnectedNotifications.append(notification)
            }
        }
    }

    @objc nonisolated private func didConnect(_ notification: IOBluetoothUserNotification!, device connected: IOBluetoothDevice!) {
        guard let connected, HeadphoneModel(deviceName: connected.name ?? "") != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.findDevice()
            self.watchDisconnect()
            self.refreshVolume()
            self.onConnection?()
        }
    }

    @objc nonisolated private func didDisconnect(_ notification: IOBluetoothUserNotification!, device disconnected: IOBluetoothDevice!) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.findDevice()
            self.watchDisconnect()
            self.refreshVolume()
            self.onConnection?()
        }
    }

    func refreshVolume() { volumeObserver?.refresh() }
    func stop() {
        stopped = true
        connectedNotification?.unregister(); connectedNotification = nil
        disconnectedNotifications.forEach { $0.unregister() }; disconnectedNotifications.removeAll()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
        unlockObserver = nil
        volumeObserver?.stop(); volumeObserver = nil
        microphoneObserver?.stop(); microphoneObserver = nil
        onConnection = nil
    }
}
