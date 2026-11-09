import Foundation
import IOBluetooth

/// A Bluetooth connect notification can precede Sony's service records. Keep
/// that short discovery window inside the connection attempt, with no idle scan.
@MainActor
final class SonyControlServiceDiscovery {
    private let tryOpen: () -> Bool
    private let query: () -> IOReturn
    private let failure: (String) -> Void
    private let retryDelays: [Duration]
    private var retryIndex = 0
    private var waitingForQuery = false
    private var stopped = false
    private var retryTask: Task<Void, Never>?

    init(retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
         tryOpen: @escaping () -> Bool, query: @escaping () -> IOReturn,
         failure: @escaping (String) -> Void) {
        self.retryDelays = retryDelays
        self.tryOpen = tryOpen; self.query = query; self.failure = failure
    }

    deinit { retryTask?.cancel() }

    func start() {
        guard !stopped else { return }
        if tryOpen() { cancel(); return }
        requestQuery()
    }

    private func requestQuery() {
        guard !stopped, !waitingForQuery else { return }
        waitingForQuery = true
        let result = query()
        if result != kIOReturnSuccess { completed(status: result) }
    }

    func completed(status: IOReturn) {
        guard !stopped, waitingForQuery else { return }
        waitingForQuery = false
        if status == kIOReturnSuccess && tryOpen() { cancel(); return }
        let reason = status == kIOReturnSuccess
            ? "No supported Sony MDR control service was found"
            : "Sony service discovery failed (\(status))"
        guard retryIndex < retryDelays.count else {
            cancel(); failure(reason); return
        }
        let delay = retryDelays[retryIndex]
        retryIndex += 1
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.retryTask = nil
            self.requestQuery()
        }
    }

    func cancel() {
        stopped = true
        waitingForQuery = false
        retryTask?.cancel(); retryTask = nil
    }
}
