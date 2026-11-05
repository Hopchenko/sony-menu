import AppKit

enum HeadphoneColor: String, CaseIterable, Identifiable, Sendable {
    case black, silver
    var id: String { rawValue }
    var title: String { self == .black ? "Black" : "Silver / white" }
    var imageName: String { self == .black ? "Headphones" : "HeadphonesSilver" }

    init?(sonyValue: UInt8) {
        switch sonyValue {
        case 0x01, 0x11: self = .black
        case 0x02, 0x03, 0x12, 0x13: self = .silver
        default: return nil
        }
    }
}

enum HeadphoneColorChoice: String, CaseIterable, Identifiable {
    case automatic, black, silver
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "Auto — match headphones"; case .black: return "Black"; case .silver: return "Silver / white" }
    }
    func resolve(reported: HeadphoneColor?, remembered: HeadphoneColor?) -> HeadphoneColor {
        switch self { case .automatic: return reported ?? remembered ?? .black; case .black: return .black; case .silver: return .silver }
    }
}

@MainActor
final class HeadphoneIconController {
    private(set) var appliedColor: HeadphoneColor?
    private(set) var finderIconUpdated = false
    private let image: @MainActor (HeadphoneColor) -> NSImage?
    private let applicationIcon: @MainActor (NSImage) -> Void
    private let finderIcon: @MainActor (NSImage) -> Bool

    init(image: @escaping @MainActor (HeadphoneColor) -> NSImage? = { NSImage(named: NSImage.Name($0.imageName)) },
         applicationIcon: @escaping @MainActor (NSImage) -> Void = { NSApp.applicationIconImage = $0 },
         finderIcon: @escaping @MainActor (NSImage) -> Bool = { NSWorkspace.shared.setIcon($0, forFile: Bundle.main.bundlePath, options: []) }) {
        self.image = image
        self.applicationIcon = applicationIcon
        self.finderIcon = finderIcon
    }

    func update(_ color: HeadphoneColor) {
        guard color != appliedColor, let artwork = image(color) else { return }
        applicationIcon(artwork)
        finderIconUpdated = finderIcon(artwork)
        appliedColor = color
    }
}

@MainActor
enum HeadphoneArtwork {
    /// Icon Services resizes images and rewrites their representations. Compare
    /// normalized pixels rather than encoded TIFF bytes or image dimensions.
    static func difference(_ first: NSImage?, _ second: NSImage?) -> Double? {
        func pixels(_ image: NSImage?) -> [UInt8]? {
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return Array(UnsafeBufferPointer(start: bytes, count: 64 * 64 * 4))
        }
        guard let a = pixels(first), let b = pixels(second) else { return nil }
        let total = zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(a.count * 255)
    }
    static func matches(_ first: NSImage?, _ second: NSImage?) -> Bool {
        difference(first, second).map { $0 < 0.03 } ?? false
    }
}
