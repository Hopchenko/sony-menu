import AppKit
import SwiftUI

extension TestMain {
    static func soundQualityTests() async {
        await test("Sound quality loads from the XM3 and refreshes explicitly") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.soundQualityMode == .prioritizeSoundQuality }
            rig.transport.soundQuality = 1
            rig.store.refresh()
            try await wait { rig.store.state.soundQualityMode == .prioritizeStableConnection }
        }
        await test("Both sound quality modes use documented payloads and verify by GET") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.soundQualityMode != nil }
            for mode in [SonyV1SoundQualityMode.prioritizeStableConnection, .prioritizeSoundQuality] {
                let start = rig.transport.commands.count
                rig.store.setSoundQualityMode(mode)
                try await wait { rig.store.state.soundQualityMode == mode }
                let sent = Array(rig.transport.commands.dropFirst(start)).map(\.payload)
                try expect(sent.contains([0xE8, 1, 0, mode.rawValue]))
                try expect(sent.contains([0xE6, 1]), "Setting was not read back after ACK")
            }
        }
        await test("Rapid quality selection can return to the original mode before readback") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.soundQualityMode != nil && rig.store.state.volume != nil }
            rig.transport.autoRespond = false
            rig.store.setSoundQualityMode(.prioritizeStableConnection)
            let first = rig.transport.commands.last!
            rig.store.setSoundQualityMode(.prioritizeSoundQuality)
            rig.transport.soundQuality = 1
            rig.transport.autoRespond = true
            rig.transport.ack(first)
            try await wait { rig.transport.commands.contains { $0.payload == [0xE8, 1, 0, 0] } }
            try await wait { rig.transport.soundQuality == 0 && rig.store.state.soundQualityMode == .prioritizeSoundQuality }
        }
        await test("A rejected sound quality write never changes displayed state optimistically") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.soundQualityMode != nil }
            rig.transport.qualityWritesApply = false
            let count = rig.transport.commands.filter { $0.payload == [0xE6, 1] }.count
            rig.store.setSoundQualityMode(.prioritizeStableConnection)
            try await wait { rig.transport.commands.filter { $0.payload == [0xE6, 1] }.count > count }
            try expect(rig.store.state.soundQualityMode == .prioritizeSoundQuality)
        }
        await test("Phone notifications update sound quality and malformed values are ignored") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.soundQualityMode != nil }
            rig.transport.emit([0xE9, 1, 0, 1])
            try expect(rig.store.state.soundQualityMode == .prioritizeStableConnection)
            for payload: [UInt8] in [[0xE9,1], [0xE7,1,1,0], [0xE9,1,0,255]] { rig.transport.emit(payload) }
            try expect(rig.store.state.soundQualityMode == .prioritizeStableConnection)
        }
        await test("Unreported sound quality and unsupported models cannot send setting writes") {
            let rig = TestRig(start: false); defer { rig.close() }
            rig.transport.qualityReplies = false
            rig.client.connect(address: "test", deviceName: "WH-1000XM3")
            try await wait { rig.client.connectionState == .ready }
            rig.client.setSoundQualityMode(.prioritizeStableConnection)
            try expect(!rig.transport.commands.contains { $0.payload.first == 0xE8 })
            rig.client.disconnect()
            rig.transport.modelName = "Other"
            let count = rig.transport.commands.count
            rig.client.connect(address: "test", deviceName: "Other")
            try await wait { rig.client.connectionState == .ready }
            rig.client.setSoundQualityMode(.prioritizeStableConnection)
            try expect(!rig.transport.commands.dropFirst(count).contains { $0.payload.first == 0xE6 || $0.payload.first == 0xE8 })
        }
        await test("Unchanged, disconnected and stopped sound quality controls send no writes") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.soundQualityMode != nil }
            rig.store.setSoundQualityMode(.prioritizeSoundQuality)
            rig.store.connection = .disconnected
            rig.store.setSoundQualityMode(.prioritizeStableConnection)
            rig.store.shutdown()
            rig.store.setSoundQualityMode(.prioritizeStableConnection)
            try expect(!rig.transport.commands.contains { $0.payload.first == 0xE8 })
        }
        await test("Sound quality state clears on disconnect and uses the new session readback") {
            let rig = TestRig(); defer { rig.close() }
            try await wait { rig.store.ready && rig.store.state.soundQualityMode != nil }
            rig.client.disconnect()
            try expect(rig.store.state.soundQualityMode == nil)
            rig.transport.soundQuality = 1
            rig.store.connect()
            try await wait { rig.store.ready && rig.store.state.soundQualityMode == .prioritizeStableConnection }
        }
    }
}
