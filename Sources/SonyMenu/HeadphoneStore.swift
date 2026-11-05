import AppKit
import Combine
import IOBluetooth

@MainActor
final class HeadphoneStore: ObservableObject {
    @Published var state = SonyV1State()
    @Published var connection: SonyV1ClientConnectionState = .disconnected
    @Published var settingsShown = false
    @Published var notice: String?
    @Published var bluetoothConnected = false
    @Published var outputVolume: Double?
    @Published var microphones = MicrophoneState()
    @Published var sleepStatus: String?
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    @Published var disconnectOnSleep: Bool {
        didSet { defaults.set(disconnectOnSleep, forKey: "disconnectOnSleep") }
    }
    @Published var reconnectAfterUnlock: Bool {
        didSet { defaults.set(reconnectAfterUnlock, forKey: "reconnectAfterUnlock") }
    }
    @Published var showBattery: Bool {
        didSet { defaults.set(showBattery, forKey: "showBattery") }
    }
    @Published var launchAtLogin = false
    private let defaults: UserDefaults
    let client: SonyV1Client
    private let platform: any HeadphonePlatform
    var volumeEventCount: Int { platform.volumeEventCount }
    private var policy = SleepPolicy()
    private var disconnecting = false
    private var stopped = false
    private var pendingControl: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private let retryDelays: [Duration]
    private(set) var connectionCheckCount = 0

    var ready: Bool { connection == .ready }
    var connectionLabel: String {
        if let sleepStatus { return sleepStatus }
        switch connection {
        case .ready: return "Connected"
        case .connecting: return "Connecting…"
        case .failed: return bluetoothConnected ? "Controls unavailable" : "Disconnected"
        case .disconnected: return "Disconnected"
        }
    }

    init(defaults: UserDefaults = .standard, platform: (any HeadphonePlatform)? = nil, client: SonyV1Client? = nil, retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]) {
        self.defaults = defaults
        self.platform = platform ?? MacHeadphonePlatform()
        self.client = client ?? SonyV1Client()
        self.retryDelays = retryDelays
        defaults.register(defaults: ["disconnectOnSleep": true, "reconnectAfterUnlock": false])
        disconnectOnSleep = defaults.bool(forKey: "disconnectOnSleep")
        reconnectAfterUnlock = defaults.bool(forKey: "reconnectAfterUnlock")
        showBattery = defaults.bool(forKey: "showBattery")
        appearance = AppAppearance(savedValue: defaults.string(forKey: "appearance"))
        launchAtLogin = self.platform.loginEnabled
        self.client.onStateChange = { [weak self] state in
            guard let self, self.state != state else { return }
            self.state = state
        }
        self.client.onConnectionStateChange = { [weak self] connection in
            guard let self, !self.stopped else { return }
            self.connection = connection
            if case .failed(let reason) = connection {
                self.notice = reason
                self.scheduleRetry()
            }
            if connection == .ready {
                self.notice = nil
                self.bluetoothConnected = self.platform.isConnected
                self.platform.refreshVolume()
                self.retryTask?.cancel(); self.retryTask = nil
                self.retryAttempt = 0
            }
            Diagnostics.shared.log("Connection: \(connection)")
        }
        self.client.onTransportLog = { direction, message in Diagnostics.shared.log("\(direction.rawValue): \(message)") }
        self.platform.start(
            connection: { [weak self] in self?.connectionChanged() },
            sleep: { [weak self] in self?.prepareForSleep() },
            wake: { [weak self] in self?.handleWake() },
            unlock: { [weak self] in self?.handleUnlock() },
            volume: { [weak self] value in
                guard let self, !self.stopped, self.outputVolume != value else { return }
                self.outputVolume = value
            }
        )
        self.platform.observeMicrophones { [weak self] state in
            guard let self, !self.stopped, self.microphones != state else { return }
            self.microphones = state
        }
        checkConnection()
    }

    private func connectionChanged() {
        retryAttempt = 0
        retryTask?.cancel(); retryTask = nil
        checkConnection()
    }

    func checkConnection() {
        guard !stopped else { return }
        connectionCheckCount += 1
        guard platform.isPaired else {
            notice = "Pair WH-1000XM3 in macOS Bluetooth settings first."
            return
        }
        bluetoothConnected = platform.isConnected
        if policy.isSleeping || policy.waitingForUnlock {
            if disconnectOnSleep && bluetoothConnected { disconnectHeadphones() }
            return
        }
        if !bluetoothConnected {
            retryTask?.cancel(); retryTask = nil
            if ready { client.disconnect() }
            return
        }
        guard !policy.blocksAutomaticConnection else { return }
        if !ready && connection != .connecting { connectControlChannel() }
    }

    private func connectControlChannel() {
        guard !stopped, let address = platform.address else { return }
        sleepStatus = nil
        notice = nil
        client.connect(address: address, deviceName: "WH-1000XM3")
    }

    private func scheduleRetry() {
        guard !stopped, !disconnecting, !policy.blocksAutomaticConnection,
              platform.isConnected, retryTask == nil, retryAttempt < retryDelays.count else { return }
        let delay = retryDelays[retryAttempt]
        retryAttempt += 1
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.checkConnection()
        }
    }

    func connect() {
        guard !stopped, !policy.isSleeping else { return }
        policy.manualConnect()
        retryTask?.cancel(); retryTask = nil
        retryAttempt = 0
        connectControlChannel()
    }

    func disconnect() {
        policy.manualDisconnect()
        sleepStatus = nil
        disconnectHeadphones()
    }

    private func disconnectHeadphones() {
        guard !disconnecting else { return }
        disconnecting = true
        retryTask?.cancel(); retryTask = nil
        pendingControl?.cancel()
        client.disconnect()
        if platform.isConnected {
            let result = platform.disconnect()
            Diagnostics.shared.log("Headphone disconnect result: \(result)")
            if result != kIOReturnSuccess { notice = "Could not disconnect the headphones (\(result))." }
        }
        bluetoothConnected = platform.isConnected
        disconnecting = false
    }

    func setMode(_ mode: SonyV1NoiseMode) {
        pendingControl?.cancel()
        if mode == .ambient { client.setAmbient(level: state.ambientLevel, focusOnVoice: state.focusOnVoice) }
        else { client.setNoiseMode(mode) }
    }

    func setAmbient(level: Int? = nil, voice: Bool? = nil) {
        let desiredLevel = level ?? state.ambientLevel
        let desiredVoice = voice ?? state.focusOnVoice
        pendingControl?.cancel()
        pendingControl = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.client.setAmbient(level: desiredLevel, focusOnVoice: desiredVoice)
        }
    }

    func setVolume(_ value: Double) {
        guard platform.writeVolume(value) else { notice = "macOS could not change the headphone volume."; return }
        outputVolume = platform.readVolume()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try platform.setLogin(enabled)
            launchAtLogin = platform.loginEnabled
            if enabled && !launchAtLogin { notice = "Allow Sony Menu in System Settings → General → Login Items." }
        } catch { notice = "Login setting could not be changed: \(error.localizedDescription)" }
    }

    func selectMicrophone(_ id: UInt32) {
        guard !stopped else { return }
        guard microphones.devices.contains(where: { $0.id == id }) else {
            microphones = platform.readMicrophones()
            notice = "That microphone is no longer available."
            return
        }
        guard platform.selectMicrophone(id) else {
            microphones = platform.readMicrophones()
            notice = "macOS could not change the microphone."
            return
        }
        microphones = platform.readMicrophones()
        if microphones.selectedID != id { notice = "The microphone change was not confirmed by macOS." }
        else { notice = nil }
    }

    func refresh() {
        guard !stopped else { return }
        if ready { client.refresh() }
        else { retryAttempt = 0; checkConnection() }
        platform.refreshVolume()
        microphones = platform.readMicrophones()
        launchAtLogin = platform.loginEnabled
    }

    func prepareForSleep() {
        guard !stopped else { return }
        let shouldDisconnect = policy.sleep(enabled: disconnectOnSleep, connected: platform.isConnected)
        Diagnostics.shared.log("Will sleep. Disconnect requested: \(shouldDisconnect)")
        pendingControl?.cancel()
        retryTask?.cancel(); retryTask = nil
        if shouldDisconnect { disconnectHeadphones() }
        else { client.disconnect() }
        if disconnectOnSleep { sleepStatus = "Disconnected for sleep" }
    }

    private func handleWake() {
        guard !stopped else { return }
        policy.wake()
        platform.refreshVolume()
        checkConnection()
    }

    private func handleUnlock() {
        guard !stopped else { return }
        // Unlock proves the Mac is awake even if the wake callback arrives later.
        policy.wake()
        let shouldReconnect = policy.unlock(reconnect: reconnectAfterUnlock)
        if shouldReconnect { connect() }
        else if sleepStatus != nil {
            sleepStatus = "Disconnected after sleep"
            if !reconnectAfterUnlock { policy.manualDisconnect() }
        }
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        pendingControl?.cancel()
        retryTask?.cancel(); retryTask = nil
        platform.stop()
        client.disconnect()
    }

    func verifySleepDisconnect() async -> Bool {
        let preference = disconnectOnSleep
        disconnectOnSleep = true
        prepareForSleep()
        for _ in 0..<40 {
            if !platform.isConnected { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let disconnected = !platform.isConnected
        handleWake()
        _ = policy.unlock(reconnect: false)
        disconnectOnSleep = preference
        connect()
        return disconnected
    }
}
