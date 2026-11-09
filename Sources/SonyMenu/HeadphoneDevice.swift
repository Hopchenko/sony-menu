import Foundation

struct HeadphoneDevice: Equatable, Identifiable {
    let id: String
    let name: String
    let connected: Bool
    var model: HeadphoneModel? { HeadphoneModel(deviceName: name) }
}

enum HeadphoneModel: String, CaseIterable {
    case xm3 = "WH-1000XM3", xm4 = "WH-1000XM4"
    init?(deviceName: String) {
        let normalized = deviceName.uppercased().filter { $0.isLetter || $0.isNumber }
        switch normalized {
        case "WH1000XM3": self = .xm3
        case "WH1000XM4": self = .xm4
        default: return nil
        }
    }
    func color(sonyValue: UInt8) -> HeadphoneColor? {
        // Observed on the connected blue XM4 and physically confirmed by its owner.
        if self == .xm4 && sonyValue == 0x05 { return .blue }
        return HeadphoneColor(sonyValue: sonyValue)
    }
    var disconnectOnSleepByDefault: Bool { self == .xm3 }
    var colors: [HeadphoneColorChoice] { self == .xm4 ? [.automatic, .black, .silver, .blue] : [.automatic, .black, .silver] }
    func imageName(color: HeadphoneColor) -> String {
        self == .xm4 ? "HeadphonesXM4\(color.rawValue.capitalized)" : (color == .silver ? "HeadphonesSilver" : "Headphones")
    }
}

/// A connected current target wins over arrival order. Offline selection is
/// retained so its model/artwork remain visible after disconnection.
enum HeadphoneSelection {
    static func choose(_ devices: [HeadphoneDevice], preferred: String?, current: String?, remembered: String?) -> HeadphoneDevice? {
        let supported = devices.filter { $0.model != nil }
        if let preferred { return supported.first { $0.id == preferred } }
        if let currentDevice = supported.first(where: { $0.id == current && $0.connected }) { return currentDevice }
        let connected = supported.filter(\.connected)
        if let last = connected.first(where: { $0.id == remembered }) { return last }
        return connected.first ?? supported.first(where: { $0.id == current }) ?? supported.first(where: { $0.id == remembered }) ?? supported.first
    }
}
