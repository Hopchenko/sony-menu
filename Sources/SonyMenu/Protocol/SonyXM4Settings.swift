import Foundation

enum SonyConversationSensitivity: UInt8, CaseIterable, Sendable {
    case automatic = 0, high = 1, low = 2
    var title: String { switch self { case .automatic: return "Auto"; case .high: return "High"; case .low: return "Low" } }
}

enum SonyConversationTimeout: UInt8, CaseIterable, Sendable {
    case short = 0, standard = 1, long = 2, never = 3
    var title: String { switch self { case .short: return "15 seconds"; case .standard: return "30 seconds"; case .long: return "1 minute"; case .never: return "Manual only" } }
}

struct SonyConversationOptions: Equatable, Sendable {
    var sensitivity: SonyConversationSensitivity
    var focusOnVoice: Bool
    var timeout: SonyConversationTimeout
    var payload: [UInt8] { [0xFC, 0x05, 0x00, sensitivity.rawValue, focusOnVoice ? 1 : 0, timeout.rawValue] }
    init(sensitivity: SonyConversationSensitivity = .automatic, focusOnVoice: Bool = false, timeout: SonyConversationTimeout = .standard) {
        self.sensitivity = sensitivity; self.focusOnVoice = focusOnVoice; self.timeout = timeout
    }
    init?(reply: [UInt8]) {
        guard reply.count == 6, [0xFB, 0xFD].contains(reply[0]), reply[1] == 5, reply[2] == 0,
              let sensitivity = SonyConversationSensitivity(rawValue: reply[3]), reply[4] <= 1,
              let timeout = SonyConversationTimeout(rawValue: reply[5]) else { return nil }
        self.init(sensitivity: sensitivity, focusOnVoice: reply[4] == 1, timeout: timeout)
    }
}

struct SonyXM4Settings: Equatable, Sendable {
    var speakToChatAvailable = false
    var wearDetectionAvailable = false
    var wearPowerOffAvailable = false
    var dseeAvailable = false
    var multipointSlot: UInt8?
    var speakToChatEnabled: Bool?
    var conversationOptions: SonyConversationOptions?
    var wearDetectionEnabled: Bool?
    var wearPowerOffEnabled: Bool?
    var wearPowerOffTimer: UInt8?
    var multipointEnabled: Bool?

    /// The slot is discovered by its reported subject. On XM3, D2 means touch
    /// controls; on the tested XM4, the same slot means multipoint.
    static func multipointSlot(from capability: [UInt8]) -> UInt8? {
        guard capability.count >= 5, capability[0] == 0xD1, capability[2] == 2 else { return nil }
        let nameEnd = 4 + Int(capability[3])
        guard capability.count > nameEnd,
              String(bytes: capability[4..<nameEnd], encoding: .utf8) == "MULTIPOINT_SETTING" else { return nil }
        let summaryEnd = nameEnd + 1 + Int(capability[nameEnd])
        guard capability.count == summaryEnd + 2, capability[summaryEnd] == 1, capability[summaryEnd + 1] == 0 else { return nil }
        return capability[1]
    }
}

enum SonyXM4SettingChange: String, Equatable {
    case speakToChat = "Speak-to-Chat", conversation = "Conversation settings"
    case multipoint = "Multipoint", wearDetection = "Automatic pause and resume"
    case wearPowerOff = "Power off when removed", dsee = "DSEE Extreme"
}
