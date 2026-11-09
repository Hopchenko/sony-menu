import AppKit
import Combine
import IOBluetooth

@MainActor
final class HeadphoneStore: ObservableObject {
    @Published private(set) var model: HeadphoneModel = .xm3
    @Published private(set) var devices: [HeadphoneDevice] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var preferredDeviceID: String?
    var modelName: String { model.rawValue }
    var artworkName: String { model.imageName(color: headphoneColor) }
    var colorChoices: [HeadphoneColorChoice] { model.colors }
    private func preferenceKey(_ base: String) -> String {
        // Keep the original XM3 preference keys as the migration source only.
        guard let selectedDeviceID else { return base }
        return "headphone.\(selectedDeviceID).\(base)"
    }
    func selectDevice(_ id: String?) {
        guard !policy.isSleeping && !policy.waitingForUnlock && pendingXM4Change == nil else { return }
        platform.selectDevice(id)
    }
    @Published private(set) var pendingXM4Change: SonyXM4SettingChange?
    @Published private(set) var xm4ChangeStatus: String?
    private var xm4ChangeTask: Task<Void, Never>?
    var canEditXM4Settings: Bool { ready && model == .xm4 && pendingXM4Change == nil }
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
        didSet { defaults.set(disconnectOnSleep, forKey: preferenceKey("disconnectOnSleep")) }
    }
    @Published var reconnectAfterUnlock: Bool {
        didSet { defaults.set(reconnectAfterUnlock, forKey: preferenceKey("reconnectAfterUnlock")) }
    }
    @Published var showBattery: Bool {
        didSet { defaults.set(showBattery, forKey: "showBattery") }
    }
    @Published var colorChoice: HeadphoneColorChoice {
        didSet { defaults.set(colorChoice.rawValue, forKey: preferenceKey("headphoneColorChoice")) }
    }
    @Published private(set) var lastDetectedColor: HeadphoneColor?
    var headphoneColor: HeadphoneColor {
        let color = colorChoice.resolve(reported: state.color, remembered: lastDetectedColor)
        return model == .xm3 && color == .blue ? .black : color
    }
    var headphoneColorDetail: String {
        if colorChoice != .automatic { return "Uses the same picture in the panel and app icon." }
        if let color = state.color { return "Detected: \(color.title)." }
        if let color = lastDetectedColor { return "Last detected: \(color.title). Connect to detect again." }
        return "Detects when connected. Choose a color if unavailable."
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
        colorChoice = defaults.string(forKey: "headphoneColorChoice").flatMap(HeadphoneColorChoice.init(rawValue:)) ?? .automatic
        lastDetectedColor = defaults.string(forKey: "detectedHeadphoneColor").flatMap(HeadphoneColor.init(rawValue:))
        launchAtLogin = self.platform.loginEnabled
        self.client.onStateChange = { [weak self] state in
            guard let self, self.state != state else { return }
            self.state = state
            if let color = state.color, self.lastDetectedColor != color {
                self.lastDetectedColor = color
                self.defaults.set(color.rawValue, forKey: self.preferenceKey("detectedHeadphoneColor"))
            }
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
        let paired = platform.isPaired
        synchronizeDevice()
        bluetoothConnected = platform.isConnected
        guard paired else {
            retryTask?.cancel(); retryTask = nil
            if connection != .disconnected { client.disconnect() }
            notice = "Pair WH-1000XM3 or WH-1000XM4 in macOS Bluetooth settings first."
            return
        }
        if policy.isSleeping || policy.waitingForUnlock {
            if disconnectOnSleep && bluetoothConnected { disconnectHeadphones() }
            return
        }
        if !bluetoothConnected {
            retryTask?.cancel(); retryTask = nil
            if connection != .disconnected { client.disconnect() }
            return
        }
        guard !policy.blocksAutomaticConnection else { return }
        if !ready && connection != .connecting { connectControlChannel() }
    }

    private func synchronizeDevice() {
        devices = platform.devices
        preferredDeviceID = platform.preferredDeviceID
        guard selectedDeviceID != platform.address else { return }
        let wasSleeping = policy.isSleeping || policy.waitingForUnlock
        pendingControl?.cancel()
        cancelXM4Change()
        retryTask?.cancel(); retryTask = nil; retryAttempt = 0
        client.disconnect()
        selectedDeviceID = platform.address
        model = HeadphoneModel(deviceName: platform.modelName) ?? .xm3
        if !wasSleeping { policy = SleepPolicy(); sleepStatus = nil }
        notice = nil; outputVolume = nil
        let choiceKey = preferenceKey("headphoneColorChoice")
        let detectedKey = preferenceKey("detectedHeadphoneColor")
        if model == .xm3 && !defaults.bool(forKey: "xm3ColorMigrated") {
            if defaults.object(forKey: choiceKey) == nil { defaults.set(defaults.string(forKey: "headphoneColorChoice"), forKey: choiceKey) }
            if defaults.object(forKey: detectedKey) == nil { defaults.set(defaults.string(forKey: "detectedHeadphoneColor"), forKey: detectedKey) }
            for key in ["disconnectOnSleep", "reconnectAfterUnlock"] {
                let destination = preferenceKey(key)
                if defaults.object(forKey: destination) == nil { defaults.set(defaults.bool(forKey: key), forKey: destination) }
            }
            defaults.set(true, forKey: "xm3ColorMigrated")
        }
        colorChoice = defaults.string(forKey: choiceKey).flatMap(HeadphoneColorChoice.init(rawValue:)) ?? .automatic
        if !colorChoices.contains(colorChoice) { colorChoice = .automatic }
        lastDetectedColor = defaults.string(forKey: detectedKey).flatMap(HeadphoneColor.init(rawValue:))
        disconnectOnSleep = defaults.object(forKey: preferenceKey("disconnectOnSleep")) as? Bool ?? model.disconnectOnSleepByDefault
        reconnectAfterUnlock = defaults.object(forKey: preferenceKey("reconnectAfterUnlock")) as? Bool ?? false
        platform.refreshVolume()
    }

    private func connectControlChannel() {
        guard !stopped, platform.isPaired, let address = platform.address else { return }
        synchronizeDevice()
        sleepStatus = nil
        notice = nil
        client.connect(address: address, deviceName: modelName)
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
        cancelXM4Change()
        platform.lockSelection(false)
        policy.manualConnect()
        retryTask?.cancel(); retryTask = nil
        retryAttempt = 0
        connectControlChannel()
    }

    func disconnect() {
        cancelXM4Change()
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

    private func cancelXM4Change() {
        xm4ChangeTask?.cancel(); xm4ChangeTask = nil
        client.cancelMultipointRequest()
        if pendingXM4Change == .multipoint && !policy.isSleeping && !policy.waitingForUnlock { platform.lockSelection(false) }
        pendingXM4Change = nil
        xm4ChangeStatus = nil
    }

    private func changeXM4(_ feature: SonyXM4SettingChange, send: () -> Bool, confirmed: @escaping (SonyV1State) -> Bool) {
        guard !stopped, canEditXM4Settings else { return }
        if feature == .multipoint { platform.lockSelection(true) }
        guard send() else {
            if feature == .multipoint { platform.lockSelection(false) }
            xm4ChangeStatus = "This setting is not available from the connected headset."
            return
        }
        pendingXM4Change = feature
        xm4ChangeStatus = feature == .multipoint ? "Updating multipoint. The headphones may reconnect…" : "Updating \(feature.rawValue)…"
        let target = selectedDeviceID
        xm4ChangeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var matched = false
            let verificationSteps = feature == .multipoint ? 450 : 100
            for step in 0..<verificationSteps {
                guard !Task.isCancelled, !self.stopped, self.selectedDeviceID == target else { return }
                if self.ready && confirmed(self.state) { matched = true; break }
                if feature == .multipoint && [60,190,320].contains(step) && !self.ready && self.connection != .connecting && !self.policy.blocksAutomaticConnection {
                    self.connectControlChannel()
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, !self.stopped, self.selectedDeviceID == target else { return }
            self.client.cancelMultipointRequest()
            self.pendingXM4Change = nil
            self.xm4ChangeTask = nil
            self.xm4ChangeStatus = matched ? "\(feature.rawValue) updated." : "The headphones did not confirm \(feature.rawValue). Reconnect in Bluetooth settings, then refresh."
            if feature == .multipoint {
                if !self.policy.isSleeping && !self.policy.waitingForUnlock { self.platform.lockSelection(false) }
                self.checkConnection()
            }
        }
    }

    func setSpeakToChat(_ enabled: Bool) {
        changeXM4(.speakToChat, send: { client.setSpeakToChat(enabled) }, confirmed: { $0.xm4.speakToChatEnabled == enabled })
    }
    func setConversationOptions(sensitivity: SonyConversationSensitivity? = nil, focusOnVoice: Bool? = nil, timeout: SonyConversationTimeout? = nil) {
        guard var options = state.xm4.conversationOptions else { return }
        if let sensitivity { options.sensitivity = sensitivity }
        if let focusOnVoice { options.focusOnVoice = focusOnVoice }
        if let timeout { options.timeout = timeout }
        changeXM4(.conversation, send: { client.setConversationOptions(options) }, confirmed: { $0.xm4.conversationOptions == options })
    }
    func setMultipoint(_ enabled: Bool) {
        changeXM4(.multipoint, send: { client.setMultipoint(enabled) }, confirmed: { $0.xm4.multipointEnabled == enabled })
    }
    func setWearDetection(_ enabled: Bool) {
        changeXM4(.wearDetection, send: { client.setWearDetection(enabled) }, confirmed: { $0.xm4.wearDetectionEnabled == enabled })
    }
    func setWearPowerOff(_ enabled: Bool) {
        changeXM4(.wearPowerOff, send: { client.setWearPowerOff(enabled) }, confirmed: { $0.xm4.wearPowerOffEnabled == enabled })
    }
    func setDSEE(_ enabled: Bool) {
        changeXM4(.dsee, send: { client.setXM4DSEE(enabled) }, confirmed: { $0.dseeEnabled == enabled })
    }

    func setSoundQualityMode(_ mode: SonyV1SoundQualityMode) {
        guard !stopped, ready, state.soundQualityMode != nil else { return }
        client.setSoundQualityMode(mode)
    }

    func setVolume(_ value: Double) {
        guard platform.writeVolume(value) else { notice = "macOS could not change the headphone volume."; return }
        outputVolume = platform.readVolume()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try platform.setLogin(enabled)
            launchAtLogin = platform.loginEnabled
            if enabled && !launchAtLogin { notice = "Allow \(AppIdentity.displayName) in System Settings → General → Login Items." }
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
        platform.lockSelection(true)
        let shouldDisconnect = policy.sleep(enabled: disconnectOnSleep, connected: platform.isConnected)
        cancelXM4Change()
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
        if !policy.waitingForUnlock { platform.lockSelection(false) }
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
        platform.lockSelection(false)
        checkConnection()
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        cancelXM4Change()
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
