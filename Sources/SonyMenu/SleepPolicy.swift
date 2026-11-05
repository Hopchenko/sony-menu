import Foundation

/// Tracks intent across real sleep and partial/background wakes. A wake by
/// itself never grants permission to reconnect.
struct SleepPolicy {
    private(set) var isSleeping = false
    private(set) var waitingForUnlock = false
    private(set) var disconnectedForSleep = false
    private(set) var manuallyDisconnected = false

    var blocksAutomaticConnection: Bool {
        isSleeping || waitingForUnlock || manuallyDisconnected
    }

    mutating func sleep(enabled: Bool, connected: Bool) -> Bool {
        isSleeping = true
        if enabled {
            waitingForUnlock = true
            disconnectedForSleep = disconnectedForSleep || connected
        }
        return enabled && connected
    }

    mutating func wake() { isSleeping = false }

    mutating func unlock(reconnect: Bool) -> Bool {
        guard !isSleeping else { return false }
        let shouldConnect = waitingForUnlock && disconnectedForSleep && reconnect && !manuallyDisconnected
        waitingForUnlock = false
        disconnectedForSleep = false
        return shouldConnect
    }

    mutating func manualDisconnect() { manuallyDisconnected = true }
    mutating func manualConnect() {
        manuallyDisconnected = false
        waitingForUnlock = false
        disconnectedForSleep = false
    }
}
