import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case device, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .device: return "Device"; case .light: return "Light"; case .dark: return "Dark" }
    }
    var native: NSAppearance? {
        switch self { case .device: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
    init(savedValue: String?) { self = savedValue.flatMap(Self.init(rawValue:)) ?? .device }
}
