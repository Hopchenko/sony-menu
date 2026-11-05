import Foundation

enum CoreChecks {
    static func run() {
        // A captured Sony init envelope: verifies byte order and checksum
        // independently of our encoder/decoder agreement.
        let initFrame = Data([0x3E, 0x0C, 0, 0, 0, 0, 2, 0, 0, 0x0E, 0x3C])
        let expected = SonyMDRPacket(dataType: 0x0C, sequence: 0, payload: [0, 0])
        precondition(SonyMDRFraming.encode(expected) == initFrame)
        let parser = SonyMDRFrameParser(maximumPayloadLength: 100)
        var decoded: [SonyMDRPacket] = []
        for byte in initFrame { decoded += parser.append(Data([byte])) }
        precondition(decoded == [expected], "Fragmented callback must retain frame state")
        let escaped = SonyMDRPacket(dataType: 12, sequence: 1, payload: [60, 61, 62])
        let escapedFrame = SonyMDRFraming.encode(escaped)
        precondition(Array(escapedFrame).contains(0x2C))
        precondition(parser.append(escapedFrame + initFrame) == [escaped, expected], "Coalesced callbacks")
        var corrupt = Array(initFrame)
        corrupt[corrupt.count - 2] ^= 1
        precondition(parser.append(Data(corrupt)).isEmpty, "Reject checksum corruption")
        let oversize = SonyMDRPacket(dataType: 12, sequence: 0, payload: Array(repeating: 2, count: 200))
        precondition(parser.append(SonyMDRFraming.encode(oversize)).isEmpty)
        precondition(parser.append(initFrame) == [expected], "Recover after oversize frame")
        precondition(parser.append(Data([99, 23, 62, 4, 62]) + initFrame.dropFirst()) == [expected], "Resync after stream noise")

        var policy = SleepPolicy()
        precondition(policy.sleep(enabled: true, connected: true))
        precondition(policy.blocksAutomaticConnection)
        policy.wake()
        precondition(policy.blocksAutomaticConnection, "A background wake must not permit reconnect")
        precondition(policy.sleep(enabled: true, connected: false) == false)
        policy.wake()
        precondition(policy.unlock(reconnect: true), "Preserve disconnect ownership across repeated background wakes")
        precondition(!policy.unlock(reconnect: true), "Reconnect once")

        policy.manualDisconnect()
        _ = policy.sleep(enabled: true, connected: false)
        policy.wake()
        precondition(!policy.unlock(reconnect: true), "Never undo manual disconnect")
        precondition(policy.blocksAutomaticConnection)
        policy.manualConnect()
        precondition(!policy.blocksAutomaticConnection)
        _ = policy.sleep(enabled: true, connected: true)
        policy.wake()
        precondition(!policy.unlock(reconnect: false), "Respect manual reconnect preference")

        var disabled = SleepPolicy()
        precondition(!disabled.sleep(enabled: false, connected: true))
        disabled.wake()
        precondition(!disabled.blocksAutomaticConnection)
        precondition(!disabled.unlock(reconnect: true))

        let profile = SonyV1DeviceProfile(deviceName: "WH-1000XM3")
        precondition(profile.noisePayload(mode: .noiseCancellation, ambientLevel: 10, reportedNCType: 2, reportedASMType: 1, reportedASMID: 0) == [0x68, 2, 0x11, 2, 2, 1, 0, 0])
        print("Passed: Sony wire fixture, fragmented/combined frames, escaping, corruption/oversize recovery, XM3 command, sleep/background-wake/unlock/manual-disconnect policy.")
    }
}
