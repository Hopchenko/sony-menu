// Adapted from HeadBridge (MIT). See Resources/ThirdPartyNotices.txt.
import Foundation
import IOBluetooth
import OSLog

enum SonyV1ClientConnectionState: Equatable {
    case disconnected
    case connecting
    case ready
    case failed(String)
}

/// Pure Swift Sony MDR V1 client.
///
/// The client is deliberately event-driven. RFCOMM callbacks feed the parser,
/// every device packet is acknowledged immediately, and outgoing commands use
/// one stop-and-wait queue. There is no background polling loop.
@MainActor
final class SonyV1Client {
    var onConnectionStateChange: ((SonyV1ClientConnectionState) -> Void)?
    var onStateChange: ((SonyV1State) -> Void)?
    var onTransportLog: ((TransportLogEntry.Direction, String) -> Void)?

    private struct QueuedCommand {
        let dataType: UInt8
        let payload: [UInt8]
        let label: String
        let coalescingKey: String?
        let isCritical: Bool
        let completion: (() -> Void)?
    }

    private struct InFlightCommand {
        let command: QueuedCommand
        let sequence: UInt8
        var attempt: Int
    }

    private let transport: any SonyRFCOMMTransporting
    private let commandTimeout: Duration
    private let parser = SonyMDRFrameParser()
    private let logger = Logger(subsystem: "local.sonymenu.app", category: "SonyV1")

    private(set) var connectionState: SonyV1ClientConnectionState = .disconnected
    private(set) var state = SonyV1State()

    private var deviceName = "Sony Headphones"
    private var profile = SonyV1DeviceProfile(deviceName: "Sony Headphones")
    private var commandQueue: [QueuedCommand] = []
    private var inFlight: InFlightCommand?
    private var nextSequence: UInt8 = 0
    private var commandTimeoutTask: Task<Void, Never>?
    private var handshakeFallbackTask: Task<Void, Never>?
    private var readyFallbackTask: Task<Void, Never>?
    private var handshakeComplete = false
    private var initialQueriesQueued = false
    private var requestedMultipoint: Bool?
    private var multipointAlertConfirmed = false
    private var multipointRequestExpiry: Task<Void, Never>?
    private var reportedNCType: UInt8 = 0x02
    private var reportedASMType: UInt8 = 0x01
    private var reportedASMID: UInt8 = 0x00
    private var lastSubmittedVolume: Int?
    private var generation = 0
    private static let maximumQueuedCommands = 128

    convenience init() {
        self.init(transport: SonyRFCOMMTransport())
    }

    init(transport: any SonyRFCOMMTransporting, commandTimeout: Duration = .milliseconds(1500)) {
        self.transport = transport
        self.commandTimeout = commandTimeout
        transport.onStatusChange = { [weak self] status in
            self?.handleTransportStatus(status)
        }
        transport.onData = { [weak self] data in
            self?.handleIncoming(data)
        }
    }

    func connect(address: String, deviceName: String) {
        resetSession(keepConnectionState: true)
        generation &+= 1
        self.deviceName = deviceName
        profile = SonyV1DeviceProfile(deviceName: deviceName)
        updateConnectionState(.connecting)
        transport.connect(address: address)
    }

    func disconnect() {
        generation &+= 1
        resetSession(keepConnectionState: true)
        transport.disconnect()
        updateConnectionState(.disconnected)
    }

    func refresh() {
        guard handshakeComplete, transport.status == .connected else { return }
        enqueueStateQueries()
    }

    func refreshBattery() {
        guard handshakeComplete, transport.status == .connected else { return }
        enqueue([SonyV1Opcode.batteryGet, 0x00], label: "Battery sample")
    }

    /// Explicit read-only research probe. Never used during normal idle work.
    /// V1 general-setting slots can describe their function in the response.
    func inspectCallCapabilities() {
        guard connectionState == .ready else { return }
        enqueue([0x06, 0x00], label: "Supported functions inquiry")
        for slot: UInt8 in [0xD1, 0xD2, 0xD3] {
            enqueue([0xD0, slot, 0x01], label: "General setting capability \(slot)")
        }
        // The documented newer call-setting inquiry uses the same GET opcodes.
        // Reading reserved type 0x08 tests for an unadvertised backport; no SET
        // is sent and no response is treated as support without validation.
        enqueue([0xF0, 0x08], label: "Call settings capability inquiry")
        enqueue([0xF6, 0x08], label: "Call settings parameter inquiry")
    }

    private var isXM4: Bool { HeadphoneModel(deviceName: state.modelName ?? deviceName) == .xm4 }

    @discardableResult func setSpeakToChat(_ enabled: Bool) -> Bool {
        guard isXM4, connectionState == .ready, state.xm4.speakToChatAvailable, state.xm4.speakToChatEnabled != nil else { return false }
        enqueue([0xF8,5,1,enabled ? 1 : 0], label: "Speak-to-Chat set", coalescingKey: "speak-to-chat") { [weak self] in
            self?.enqueue([0xF6,5], label: "Speak-to-Chat verify")
        }
        return true
    }

    @discardableResult func setConversationOptions(_ options: SonyConversationOptions) -> Bool {
        guard isXM4, connectionState == .ready, state.xm4.speakToChatAvailable, state.xm4.conversationOptions != nil else { return false }
        enqueue(options.payload, label: "Conversation settings set", coalescingKey: "conversation-settings") { [weak self] in
            self?.enqueue([0xFA,5], label: "Conversation settings verify")
        }
        return true
    }

    @discardableResult func setWearDetection(_ enabled: Bool) -> Bool {
        guard isXM4, connectionState == .ready, state.xm4.wearDetectionAvailable, state.xm4.wearDetectionEnabled != nil else { return false }
        enqueue([0xF8,3,0,enabled ? 1 : 0], label: "Wear detection set") { [weak self] in
            self?.enqueue([0xF6,3], label: "Wear detection verify")
        }
        return true
    }

    @discardableResult func setWearPowerOff(_ enabled: Bool) -> Bool {
        guard isXM4, connectionState == .ready, state.xm4.wearPowerOffAvailable, state.xm4.wearPowerOffEnabled != nil,
              let timer = state.xm4.wearPowerOffTimer else { return false }
        enqueue([0xF8,4,1,enabled ? 0x10 : 0x11,timer], label: "Wear power off set") { [weak self] in
            self?.enqueue([0xF6,4], label: "Wear power off verify")
        }
        return true
    }

    @discardableResult func setMultipoint(_ enabled: Bool) -> Bool {
        guard isXM4, connectionState == .ready, let slot = state.xm4.multipointSlot, state.xm4.multipointEnabled != nil else { return false }
        requestedMultipoint = enabled
        multipointAlertConfirmed = false
        multipointRequestExpiry?.cancel()
        let expectedGeneration = generation
        multipointRequestExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, self.generation == expectedGeneration else { return }
            self.cancelMultipointRequest()
        }
        // The headset refuses a reconnecting change unless the client has
        // subscribed to Sony's fixed-message confirmation exchange.
        enqueue([0x94,1,0], label: "Subscribe to multipoint confirmation")
        enqueue([0xD8,slot,1,enabled ? 1 : 0], label: "Multipoint set", coalescingKey: "multipoint") { [weak self] in
            guard let self else { return }
            self.enqueue([0xD6,slot], label: "Multipoint verify")
            self.enqueue([0x18,0], label: "Codec after multipoint change")
        }
        return true
    }

    func cancelMultipointRequest() {
        requestedMultipoint = nil
        multipointAlertConfirmed = false
        multipointRequestExpiry?.cancel(); multipointRequestExpiry = nil
    }

    @discardableResult func setXM4DSEE(_ enabled: Bool) -> Bool {
        guard isXM4, connectionState == .ready, state.xm4.dseeAvailable, state.dseeEnabled != nil else { return false }
        setDSEE(enabled: enabled)
        return true
    }

    /// Read replies establish availability; ACKs never change setting values.
    private func parseXM4Setting(_ p: [UInt8]) -> Bool {
        guard let opcode = p.first else { return false }
        switch opcode {
        case 0x99:
            guard p.count == 4, p[1] == 1, p[3] <= 1, let desired = requestedMultipoint,
                  p[2] == (desired ? 6 : 7), !multipointAlertConfirmed else { return true }
            // Confirm only the exact connection change explicitly requested by
            // this session. Never accept unrelated or unsolicited alerts.
            multipointAlertConfirmed = true
            enqueue([0x98,1,p[2],1], label: "Confirm requested multipoint change") { [weak self] in
                guard let self, let slot = self.state.xm4.multipointSlot else { return }
                self.enqueue([0xD6,slot], label: "Multipoint after confirmation")
            }
        case 0xF1:
            guard p.count >= 3 else { return true }
            switch p[1] {
            case 3 where p.count == 3 && p[2] == 0:
                state.xm4.wearDetectionAvailable = true
                enqueue([0xF6,3], label: "Wear detection get")
            case 4 where p.count >= 3 && p.count == Int(p[2]) + 3 && p.dropFirst(3).contains(0x10) && p.dropFirst(3).contains(0x11):
                state.xm4.wearPowerOffAvailable = true
                enqueue([0xF6,4], label: "Wear power off get")
            case 5 where p.count == 12 && p[2] == 0 && p[3] <= 1 && p[4] == 0 && p[5] == 0 && p[6] == 0:
                state.xm4.speakToChatAvailable = true
                enqueue([0xF6,5], label: "Speak-to-Chat get")
                enqueue([0xFA,5], label: "Conversation settings get")
            default: break
            }
        case 0xE1:
            guard p.count == 4, p[1] == 2, p[2] == 2, p[3] == 0 else { return false }
            state.xm4.dseeAvailable = true
            enqueue([0xE6,2], label: "DSEE Extreme get")
        case 0xD1:
            guard let slot = SonyXM4Settings.multipointSlot(from: p) else { return true }
            state.xm4.multipointSlot = slot
            enqueue([0xD6,slot], label: "Multipoint get")
        case 0xD7, 0xD9:
            guard p.count == 4, p[1] == state.xm4.multipointSlot, p[2] == 1, p[3] <= 1 else { return false }
            state.xm4.multipointEnabled = p[3] == 1
            if state.xm4.multipointEnabled == requestedMultipoint { cancelMultipointRequest() }
        case 0xF7, 0xF9:
            guard p.count >= 4 else { return true }
            switch p[1] {
            case 3 where p.count == 4 && p[2] == 0 && p[3] <= 1 && state.xm4.wearDetectionAvailable:
                state.xm4.wearDetectionEnabled = p[3] == 1
            case 4 where p.count == 5 && p[2] == 1 && [0x10,0x11].contains(p[3]) && state.xm4.wearPowerOffAvailable:
                state.xm4.wearPowerOffEnabled = p[3] == 0x10
                state.xm4.wearPowerOffTimer = p[4]
            case 5 where p.count == 4 && p[2] <= 1 && p[3] <= 1 && state.xm4.speakToChatAvailable:
                state.xm4.speakToChatEnabled = p[3] == 1
            default: return false
            }
        case 0xFB, 0xFD:
            guard state.xm4.speakToChatAvailable, let options = SonyConversationOptions(reply: p) else { return true }
            state.xm4.conversationOptions = options
        default: return false
        }
        publishState()
        return true
    }

    func setNoiseMode(_ mode: SonyV1NoiseMode, ambientLevel: Int? = nil) {
        guard connectionState == .ready else { return }
        let payload = profile.noisePayload(
            mode: mode,
            ambientLevel: ambientLevel ?? state.ambientLevel,
            reportedNCType: reportedNCType,
            reportedASMType: reportedASMType,
            reportedASMID: reportedASMID
        )

        enqueue(
            payload,
            label: "NCASM set \(String(describing: mode))",
            coalescingKey: "noise-set"
        ) { [weak self] in
            self?.enqueue([SonyV1Opcode.noiseGet, 0x02], label: "NCASM verify")
        }
    }

    func setAmbient(level: Int, focusOnVoice: Bool) {
        guard connectionState == .ready else { return }
        enqueue([0x68, 0x02, 0x11, 0x02, 0x00, 0x01, focusOnVoice ? 1 : 0, UInt8(clamping: min(20, max(1, level)))], label: "Ambient and voice set", coalescingKey: "noise-set") { [weak self] in
            self?.enqueue([0x66, 0x02], label: "Ambient verify")
        }
    }

    func setAmbientLevel(_ level: Int) {
        guard connectionState == .ready else { return }
        let desiredLevel = min(20, max(1, level))

        let payload = profile.noisePayload(
            mode: .ambient,
            ambientLevel: desiredLevel,
            reportedNCType: reportedNCType,
            reportedASMType: reportedASMType,
            reportedASMID: reportedASMID
        )
        enqueue(
            payload,
            label: "NCASM ambient level \(desiredLevel)",
            coalescingKey: "noise-set"
        ) { [weak self] in
            self?.enqueue([SonyV1Opcode.noiseGet, 0x02], label: "NCASM verify")
        }
    }

    func setVolume(_ volume: Int) {
        guard connectionState == .ready else { return }
        let volume = min(30, max(0, volume))
        guard lastSubmittedVolume != volume else { return }
        lastSubmittedVolume = volume
        enqueue(
            [SonyV1Opcode.playbackSet, 0x01, 0x20, UInt8(volume)],
            label: "Volume set \(volume)",
            coalescingKey: "volume-set"
        )
    }

    func setEqualizerPreset(_ preset: SonyV1EqualizerPreset) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.equalizerPreset(preset), label: "Equalizer preset \(preset.title)") { [weak self] in
            self?.enqueue([SonyV1Opcode.equalizerGet, 0x01], label: "Equalizer verify")
        }
    }

    func setEqualizerBands(_ values: [Int]) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.equalizerBands(values), label: "Equalizer custom bands") { [weak self] in
            self?.enqueue([SonyV1Opcode.equalizerGet, 0x01], label: "Equalizer verify")
        }
    }

    func setSurroundMode(_ mode: SonyV1SurroundMode) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.surroundMode(mode), label: "VPT \(mode.title)") { [weak self] in
            self?.enqueue([SonyV1Opcode.virtualSoundGet, 0x01], label: "VPT verify")
        }
    }

    func setSoundPosition(_ position: SonyV1SoundPosition) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.soundPosition(position), label: "Sound position \(position.title)") { [weak self] in
            self?.enqueue([SonyV1Opcode.virtualSoundGet, 0x02], label: "Sound position verify")
        }
    }

    func setDSEE(enabled: Bool) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.dsee(enabled: enabled), label: "DSEE \(enabled ? "on" : "off")") { [weak self] in
            self?.enqueue([SonyV1Opcode.audioSettingGet, 0x02], label: "DSEE verify")
        }
    }

    func setSoundQualityMode(_ mode: SonyV1SoundQualityMode) {
        guard connectionState == .ready, profile.features.contains(.soundQualityMode), state.soundQualityMode != nil else { return }
        let pending = commandQueue + (inFlight.map { [$0.command] } ?? [])
        let changing = pending.contains { $0.coalescingKey == "sound-quality-set" || $0.label == "Sound quality verify" }
        guard state.soundQualityMode != mode || changing else { return }
        enqueue(SonyV1Payloads.soundQuality(mode), label: "Sound quality \(mode.title)", coalescingKey: "sound-quality-set") { [weak self] in
            self?.enqueue([SonyV1Opcode.audioSettingGet, 0x01], label: "Sound quality verify")
            self?.enqueue([SonyV1Opcode.codecGet, 0x00], label: "Codec after quality change")
        }
    }

    func setTouchSensor(enabled: Bool) {
        guard connectionState == .ready, !isXM4 else { return }
        enqueue(SonyV1Payloads.touchSensor(enabled: enabled), label: "Touch sensor \(enabled ? "on" : "off")") {
            [weak self] in
            self?.enqueue([SonyV1Opcode.touchSensorGet, 0xD2], label: "Touch sensor verify")
        }
    }

    func setAutomaticPowerOff(_ mode: SonyV1AutomaticPowerOff) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.automaticPowerOff(mode), label: "Automatic power off \(mode.title)") { [weak self] in
            self?.enqueue([SonyV1Opcode.systemSettingGet, 0x04], label: "Automatic power off verify")
        }
    }

    func setOptimizerRunning(_ running: Bool) {
        guard connectionState == .ready else { return }
        enqueue(SonyV1Payloads.optimizer(start: running), label: running ? "NC optimizer start" : "NC optimizer cancel")
    }

    private func handleTransportStatus(_ status: SonyRFCOMMStatus) {
        switch status {
        case .idle:
            if connectionState != .disconnected {
                resetSession(keepConnectionState: true)
                updateConnectionState(.disconnected)
            }

        case .connecting:
            updateConnectionState(.connecting)

        case .connected:
            beginHandshake()

        case .failed(let message):
            resetSession(keepConnectionState: true)
            updateConnectionState(.failed(message))
        }
    }

    private func beginHandshake() {
        resetProtocolState()
        updateConnectionState(.connecting)
        enqueue(
            [SonyV1Opcode.initGet, 0x00],
            label: "Protocol init",
            isCritical: true
        )

        let expectedGeneration = generation
        handshakeFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self,
                !Task.isCancelled,
                self.generation == expectedGeneration,
                self.transport.status == .connected,
                !self.handshakeComplete
            else { return }
            self.logger.notice("Sony init reply omitted; continuing with V1 state queries")
            self.completeHandshake()
        }
    }

    private func completeHandshake() {
        guard !handshakeComplete else { return }
        handshakeComplete = true
        handshakeFallbackTask?.cancel()
        handshakeFallbackTask = nil
        enqueueInitialQueries()

        let expectedGeneration = generation
        readyFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self,
                !Task.isCancelled,
                self.generation == expectedGeneration,
                self.transport.status == .connected,
                self.connectionState == .connecting
            else { return }
            self.logger.notice("Sony initial state was partial; exposing available controls")
            self.markReady()
        }
    }

    private func enqueueInitialQueries() {
        guard !initialQueriesQueued else { return }
        initialQueriesQueued = true

        enqueue([SonyV1Opcode.modelGet, 0x01], label: "Model get")
        enqueue([SonyV1Opcode.modelGet, 0x03], label: "Series and color get")
        enqueue([SonyV1Opcode.batteryGet, 0x00], label: "Battery get")
        enqueue([SonyV1Opcode.codecGet, 0x00], label: "Codec get")
        enqueue([SonyV1Opcode.noiseCapabilityGet, 0x02], label: "NCASM capability get")
        enqueue([SonyV1Opcode.noiseGet, 0x02], label: "NCASM get")
        enqueueSoundQualityQuery()
        enqueue(
            [SonyV1Opcode.playbackGet, 0x01, 0x20],
            label: "Volume get"
        ) { [weak self] in
            self?.markReady()
        }
        if isXM4 {
            for payload: [UInt8] in [[0xF0,3], [0xF0,4], [0xF0,5], [0xE0,2], [0xD0,0xD1,1], [0xD0,0xD2,1]] {
                enqueue(payload, label: "XM4 capability inquiry")
            }
        }
    }

    private func enqueueStateQueries() {
        if state.color == nil { enqueue([SonyV1Opcode.modelGet, 0x03], label: "Series and color refresh", coalescingKey: "color-get") }
        enqueue([SonyV1Opcode.batteryGet, 0x00], label: "Battery refresh")
        enqueue([SonyV1Opcode.codecGet, 0x00], label: "Codec refresh")
        enqueue([SonyV1Opcode.noiseGet, 0x02], label: "NCASM refresh")
        enqueue([SonyV1Opcode.playbackGet, 0x01, 0x20], label: "Volume refresh")
        enqueueSoundQualityQuery()
        if isXM4 {
            if state.xm4.speakToChatAvailable { enqueue([0xF6,5], label: "Speak-to-Chat refresh"); enqueue([0xFA,5], label: "Conversation settings refresh") }
            if state.xm4.wearDetectionAvailable { enqueue([0xF6,3], label: "Wear detection refresh") }
            if state.xm4.wearPowerOffAvailable { enqueue([0xF6,4], label: "Wear power off refresh") }
            if state.xm4.dseeAvailable { enqueue([0xE6,2], label: "DSEE Extreme refresh") }
            if let slot = state.xm4.multipointSlot { enqueue([0xD6,slot], label: "Multipoint refresh") }
        }
    }

    private func enqueueSoundQualityQuery() {
        guard profile.features.contains(.soundQualityMode) else { return }
        enqueue([SonyV1Opcode.audioSettingGet, 0x01], label: "Sound quality get", coalescingKey: "sound-quality-get")
    }

    private func enqueueExtendedStateQueriesIfSupported() {
        let features = profile.features
        if features.contains(.equalizer) {
            enqueue([SonyV1Opcode.equalizerGet, 0x01], label: "Equalizer get")
        }
        if features.contains(.virtualSound) {
            enqueue([SonyV1Opcode.virtualSoundGet, 0x01], label: "VPT get")
            enqueue([SonyV1Opcode.virtualSoundGet, 0x02], label: "Sound position get")
        }
        if features.contains(.soundQualityMode) {
            enqueue([SonyV1Opcode.audioSettingGet, 0x01], label: "Sound quality get")
        }
        if features.contains(.audioUpsampling) {
            enqueue([SonyV1Opcode.audioSettingGet, 0x02], label: "DSEE get")
        }
        if features.contains(.touchSensor) {
            enqueue([SonyV1Opcode.touchSensorGet, 0xD2], label: "Touch sensor get")
        }
        if features.contains(.noiseOptimizer) {
            enqueue([SonyV1Opcode.optimizerStateGet, 0x01], label: "NC optimizer state get")
        }
        if features.contains(.automaticPowerOff) {
            enqueue([SonyV1Opcode.systemSettingGet, 0x04], label: "Automatic power off get")
        }
    }

    private func markReady() {
        guard transport.status == .connected else { return }
        readyFallbackTask?.cancel()
        readyFallbackTask = nil
        updateConnectionState(.ready)
        publishState()
    }

    private func enqueue(
        _ payload: [UInt8],
        dataType: UInt8 = SonyMDRPacket.commandType,
        label: String,
        coalescingKey: String? = nil,
        isCritical: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard transport.status == .connected else { return }
        let command = QueuedCommand(
            dataType: dataType,
            payload: payload,
            label: label,
            coalescingKey: coalescingKey,
            isCritical: isCritical,
            completion: completion
        )

        if let coalescingKey,
            let existing = commandQueue.lastIndex(where: { $0.coalescingKey == coalescingKey })
        {
            commandQueue[existing] = command
        } else if commandQueue.count < Self.maximumQueuedCommands {
            commandQueue.append(command)
        } else {
            logger.error("Dropping Sony command because the queue is full: \(label, privacy: .public)")
            return
        }
        sendNextCommandIfPossible()
    }

    private func sendNextCommandIfPossible() {
        guard transport.status == .connected,
            inFlight == nil,
            !commandQueue.isEmpty
        else { return }

        let command = commandQueue.removeFirst()
        let sequence = nextSequence
        nextSequence ^= 1
        inFlight = InFlightCommand(command: command, sequence: sequence, attempt: 1)
        sendInFlight()
    }

    private func sendInFlight() {
        guard let inFlight else { return }
        let packet = SonyMDRPacket(
            dataType: inFlight.command.dataType,
            sequence: inFlight.sequence,
            payload: inFlight.command.payload
        )
        let frame = SonyMDRFraming.encode(packet)
        let result = transport.send(frame)
        guard result == kIOReturnSuccess else {
            fail("Sony command write failed (\(result))")
            return
        }

        onTransportLog?(.outgoing, "\(inFlight.command.label)  \(frame.hexString)")
        logger.debug("TX \(inFlight.command.label, privacy: .public)")
        scheduleCommandTimeout()
    }

    private func scheduleCommandTimeout() {
        commandTimeoutTask?.cancel()
        let expectedGeneration = generation
        commandTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.commandTimeout ?? .milliseconds(1500))
            guard let self,
                !Task.isCancelled,
                self.generation == expectedGeneration,
                var inFlight = self.inFlight
            else { return }

            if inFlight.attempt < 2 {
                inFlight.attempt += 1
                self.inFlight = inFlight
                self.logger.notice("Retrying Sony command \(inFlight.command.label, privacy: .public)")
                self.sendInFlight()
                return
            }

            self.logger.error("Sony command timed out: \(inFlight.command.label, privacy: .public)")
            self.inFlight = nil
            if inFlight.command.isCritical {
                self.fail("Sony protocol handshake timed out")
            } else {
                self.sendNextCommandIfPossible()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        for packet in parser.append(data) {
            onTransportLog?(
                .incoming,
                "type=\(String(format: "%02X", packet.dataType)) seq=\(packet.sequence)  "
                    + SonyMDRFraming.encode(packet).hexString
            )
            if packet.dataType == SonyMDRPacket.ackType {
                handleAcknowledgement(packet)
                continue
            }

            acknowledge(packet)
            if !handshakeComplete, packet.payload.first != SonyV1Opcode.initReturn {
                completeHandshake()
            }
            interpret(packet.payload)
        }
    }

    private func acknowledge(_ packet: SonyMDRPacket) {
        let acknowledgement = SonyMDRPacket(
            dataType: SonyMDRPacket.ackType,
            sequence: packet.sequence ^ 1,
            payload: []
        )
        let frame = SonyMDRFraming.encode(acknowledgement)
        let result = transport.send(frame)
        if result != kIOReturnSuccess {
            logger.error("Could not ACK Sony packet: \(result)")
        } else {
            onTransportLog?(.outgoing, "ACK  \(frame.hexString)")
        }
    }

    private func handleAcknowledgement(_ packet: SonyMDRPacket) {
        guard let inFlight,
            packet.sequence == (inFlight.sequence ^ 1)
        else { return }
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        self.inFlight = nil
        inFlight.command.completion?()
        sendNextCommandIfPossible()
    }

    private func interpret(_ payload: [UInt8]) {
        guard let opcode = payload.first else { return }

        if isXM4 && parseXM4Setting(payload) { return }
        switch opcode {
        case SonyV1Opcode.initReturn:
            guard let version = SonyMDRProtocolVersion.detect(fromInitReply: payload) else {
                fail("Unrecognized Sony MDR init reply")
                return
            }
            guard version == .v1 else {
                fail("Sony MDR V2 requires the V2 protocol adapter")
                return
            }
            completeHandshake()

        case SonyV1Opcode.modelReturn:
            parseModel(payload)

        case SonyV1Opcode.batteryReturn, SonyV1Opcode.batteryNotify:
            parseBattery(payload)

        case SonyV1Opcode.codecReturn, SonyV1Opcode.codecNotify:
            parseCodec(payload)

        case SonyV1Opcode.noiseReturn, SonyV1Opcode.noiseNotify:
            parseNoiseControl(payload)

        case SonyV1Opcode.playbackReturn, SonyV1Opcode.playbackNotify:
            parsePlayback(payload)

        case SonyV1Opcode.equalizerReturn, SonyV1Opcode.equalizerNotify:
            parseEqualizer(payload)

        case SonyV1Opcode.virtualSoundReturn, SonyV1Opcode.virtualSoundNotify:
            parseVirtualSound(payload)

        case SonyV1Opcode.audioSettingReturn, SonyV1Opcode.audioSettingNotify:
            parseAudioSetting(payload)

        case SonyV1Opcode.touchSensorReturn, SonyV1Opcode.touchSensorNotify:
            parseTouchSensor(payload)

        case SonyV1Opcode.optimizerStatus:
            parseOptimizerStatus(payload)

        case SonyV1Opcode.optimizerStateReturn, SonyV1Opcode.optimizerStateNotify:
            parseOptimizerState(payload)

        case SonyV1Opcode.systemSettingReturn, SonyV1Opcode.systemSettingNotify:
            parseSystemSetting(payload)

        default:
            break
        }
    }

    private func parseModel(_ payload: [UInt8]) {
        if payload.count >= 4, payload[1] == 0x03 {
            let model = HeadphoneModel(deviceName: state.modelName ?? deviceName)
            guard let color = model?.color(sonyValue: payload[3]) ?? HeadphoneColor(sonyValue: payload[3]) else { return }
            state.color = color
            publishState()
            return
        }
        guard payload.count >= 3, payload[1] == 0x01 else { return }
        let length = Int(payload[2])
        guard length > 0, payload.count >= length + 3 else { return }
        let name = String(bytes: payload[3..<(3 + length)], encoding: .utf8)
        guard let name, !name.isEmpty else { return }
        state.modelName = name
        profile = SonyV1DeviceProfile(deviceName: name)
        publishState()
    }

    private func parseBattery(_ payload: [UInt8]) {
        guard payload.count >= 4, payload[1] == 0x00 else { return }
        state.batteryPercent = min(100, Int(payload[2]))
        state.isCharging = payload[3] == 0x01 || payload[3] == 0x02
        publishState()
    }

    private func parseCodec(_ payload: [UInt8]) {
        guard payload.count >= 3, payload[1] == 0x00 else { return }
        state.codecName =
            switch payload[2] {
            case 0x01: "SBC"
            case 0x02: "AAC"
            case 0x10: "LDAC"
            case 0x20: "aptX"
            case 0x21: "aptX HD"
            default: nil
            }
        publishState()
    }

    private func parseNoiseControl(_ payload: [UInt8]) {
        guard payload.count >= 8, payload[1] == 0x02 else { return }
        let effect = payload[2]
        reportedNCType = payload[3]
        state.windReductionSupported = reportedNCType == 0x02
        let ncValue = payload[4]
        reportedASMType = payload[5]
        reportedASMID = payload[6]
        state.focusOnVoice = payload[6] == 1
        let level = Int(payload[7])

        state.noiseMode = SonyV1NoiseMode.decode(
            effect: effect,
            ncSettingType: reportedNCType,
            ncValue: ncValue,
            ambientLevel: level
        )
        if state.noiseMode == .ambient {
            state.ambientLevel = level
        }
        publishState()
    }

    private func parsePlayback(_ payload: [UInt8]) {
        guard payload.count >= 4,
            payload[1] == 0x01,
            payload[2] == 0x20
        else { return }
        let volume = min(30, Int(payload[3]))
        state.volume = volume
        lastSubmittedVolume = volume
        publishState()
    }

    private func parseEqualizer(_ payload: [UInt8]) {
        guard payload.count >= 10, payload[1] == 0x01 else { return }
        state.equalizerPreset =
            SonyV1EqualizerPreset(rawValue: payload[2])
            ?? (payload[2] == 0xFF ? .manual : nil)
        state.equalizerBands = (0..<5).map { min(10, max(-10, Int(payload[5 + $0]) - 10)) }
        state.equalizerBands.append(min(10, max(-10, Int(payload[4]) - 10)))
        publishState()
    }

    private func parseVirtualSound(_ payload: [UInt8]) {
        guard payload.count >= 3 else { return }
        switch payload[1] {
        case 0x01:
            state.surroundMode = SonyV1SurroundMode(rawValue: payload[2])
        case 0x02:
            state.soundPosition = SonyV1SoundPosition(rawValue: payload[2])
        default:
            return
        }
        publishState()
    }

    private func parseAudioSetting(_ payload: [UInt8]) {
        guard payload.count >= 4 else { return }
        switch payload[1] {
        case 0x01:
            guard payload[2] == 0x00, let mode = SonyV1SoundQualityMode(rawValue: payload[3]) else { return }
            state.soundQualityMode = mode
        case 0x02:
            guard payload[2] == 0x00, payload[3] <= 0x01 else { return }
            state.dseeEnabled = payload[3] == 0x01
        default:
            return
        }
        publishState()
    }

    private func parseTouchSensor(_ payload: [UInt8]) {
        guard payload.count >= 4,
            payload[1] == 0xD2,
            payload[3] <= 0x01
        else { return }
        state.touchSensorEnabled = payload[3] == 0x01
        publishState()
    }

    private func parseOptimizerStatus(_ payload: [UInt8]) {
        guard payload.count >= 4,
            let status = SonyV1OptimizerStatus(rawValue: payload[3])
        else { return }
        state.optimizerStatus = status
        publishState()
        if status == .finished {
            enqueue([SonyV1Opcode.optimizerStateGet, 0x01], label: "NC optimizer result get")
        }
    }

    private func parseOptimizerState(_ payload: [UInt8]) {
        guard payload.count >= 6 else { return }
        let pressure = Double(payload[5]) / 10.0
        guard pressure > 0, pressure <= 1.0 else { return }
        state.atmosphericPressure = pressure
        publishState()
    }

    private func parseSystemSetting(_ payload: [UInt8]) {
        guard payload.count >= 5,
            payload[1] == 0x04,
            let mode = SonyV1AutomaticPowerOff(first: payload[3], second: payload[4])
        else { return }
        state.automaticPowerOff = mode
        publishState()
    }

    private func publishState() {
        onStateChange?(state)
    }

    private func updateConnectionState(_ newState: SonyV1ClientConnectionState) {
        guard connectionState != newState else { return }
        connectionState = newState
        onConnectionStateChange?(newState)
    }

    private func fail(_ message: String) {
        logger.error("Sony V1 client failed: \(message, privacy: .public)")
        resetSession(keepConnectionState: true)
        transport.disconnect()
        updateConnectionState(.failed(message))
    }

    private func resetSession(keepConnectionState: Bool) {
        resetProtocolState()
        state = SonyV1State()
        lastSubmittedVolume = nil
        publishState()
        if !keepConnectionState {
            updateConnectionState(.disconnected)
        }
    }

    private func resetProtocolState() {
        cancelMultipointRequest()
        commandTimeoutTask?.cancel()
        handshakeFallbackTask?.cancel()
        readyFallbackTask?.cancel()
        commandTimeoutTask = nil
        handshakeFallbackTask = nil
        readyFallbackTask = nil
        commandQueue.removeAll(keepingCapacity: true)
        inFlight = nil
        nextSequence = 0
        parser.reset()
        handshakeComplete = false
        initialQueriesQueued = false
        reportedNCType = 0x02
        reportedASMType = 0x01
        reportedASMID = 0x00
    }
}
