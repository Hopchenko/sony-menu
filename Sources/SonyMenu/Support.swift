import Foundation

enum TransportLogEntry {
    enum Direction: String { case incoming, outgoing }
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// Bounded in-memory diagnostics, explicitly saved only by a diagnostic run.
@MainActor
final class Diagnostics {
    static let shared = Diagnostics()
    var enabled = CommandLine.arguments.contains("--diagnose")
    private(set) var entries: [String] = []
    func log(_ message: String) {
        guard enabled else { return }
        entries.append("\(ISO8601DateFormatter().string(from: Date())) \(message)")
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }
}
