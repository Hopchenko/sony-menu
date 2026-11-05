import AppKit
import IOBluetooth
import ServiceManagement

@MainActor
protocol HeadphonePlatform: AnyObject {
    var isPaired: Bool { get }
    var isConnected: Bool { get }
    var address: String? { get }
    var loginEnabled: Bool { get }
    var volumeEventCount: Int { get }
    func disconnect() -> IOReturn
    func readVolume() -> Double?
    func writeVolume(_ value: Double) -> Bool
    func setLogin(_ enabled: Bool) throws
    func start(connection: @escaping () -> Void, sleep: @escaping () -> Void, wake: @escaping () -> Void, unlock: @escaping () -> Void, volume: @escaping (Double?) -> Void)
    func refreshVolume()
    func stop()
}

/// Owns operating-system subscriptions. No repeating timers or audio polling.
@MainActor
final class MacHeadphonePlatform: NSObject, HeadphonePlatform {
    private var device: IOBluetoothDevice?
    private var connectedNotification: IOBluetoothUserNotification?
    private var disconnectedNotification: IOBluetoothUserNotification?
    private var observers: [NSObjectProtocol] = []
    private var unlockObserver: NSObjectProtocol?
    private var volumeObserver: HeadphoneVolumeObserver?
    private var onConnection: (() -> Void)?
    private var stopped = false

    override init() { super.init(); findDevice() }
    var isPaired: Bool { findDevice(); return device != nil }
    var isConnected: Bool { device?.isConnected() ?? false }
    var address: String? { device?.addressString }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var volumeEventCount: Int { volumeObserver?.volumeEventCount ?? 0 }
    func disconnect() -> IOReturn { device?.closeConnection() ?? kIOReturnNotFound }
    func readVolume() -> Double? { HeadphoneVolume.read() }
    func writeVolume(_ value: Double) -> Bool { HeadphoneVolume.write(value) }
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
        volumeObserver = HeadphoneVolumeObserver(onChange: volume)
    }

    private func findDevice() {
        guard device == nil else { return }
        device = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first { $0.name == "WH-1000XM3" }
    }

    private func watchDisconnect() {
        disconnectedNotification?.unregister()
        disconnectedNotification = nil
        if let device, device.isConnected() {
            disconnectedNotification = device.register(forDisconnectNotification: self, selector: #selector(didDisconnect(_:device:)))
        }
    }

    @objc nonisolated private func didConnect(_ notification: IOBluetoothUserNotification!, device connected: IOBluetoothDevice!) {
        guard let connected, connected.name == "WH-1000XM3" else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.device = connected
            self.watchDisconnect()
            self.refreshVolume()
            self.onConnection?()
        }
    }

    @objc nonisolated private func didDisconnect(_ notification: IOBluetoothUserNotification!, device disconnected: IOBluetoothDevice!) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            self.disconnectedNotification?.unregister()
            self.disconnectedNotification = nil
            self.refreshVolume()
            self.onConnection?()
        }
    }

    func refreshVolume() { volumeObserver?.refresh() }
    func stop() {
        stopped = true
        connectedNotification?.unregister(); connectedNotification = nil
        disconnectedNotification?.unregister(); disconnectedNotification = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
        unlockObserver = nil
        volumeObserver?.stop(); volumeObserver = nil
        onConnection = nil
    }
}
