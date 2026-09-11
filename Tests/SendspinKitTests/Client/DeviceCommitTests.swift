import Foundation
@testable import SendspinKit
import Testing

@Suite("Device pairing record commits")
struct DeviceCommitTests {
    @Test("Commit replaces a protected server slot without consuming the incumbent lease")
    func commitReplacesProtectedSlot() async throws {
        let device = SendspinDevice.ephemeral()
        let old = PairingRecord(psk: .generate(), serverId: deviceServerID(1))
        let replacement = PairingRecord(psk: .generate(), serverId: old.serverId, used: true)
        try await device.insertOrReplace(old)
        let oldLease = try await device.acquireProtection(pskId: old.pskId, serverId: old.serverId)

        let newLease = try await device.insertOrReplaceAndProtect(replacement)

        #expect(try await device.listRecords() == [replacement])
        try await device.releaseProtection(oldLease)
        try await device.releaseProtection(newLease)
    }

    @Test("A failed commit preserves the old record and its lease")
    func failedCommitRollsBackLeaseAndState() async throws {
        let storage = CommitTestStorage()
        let device = try await SendspinDevice.open(storage: storage)
        let old = PairingRecord(psk: .generate(), serverId: deviceServerID(2))
        let replacement = PairingRecord(psk: .generate(), serverId: old.serverId)
        try await device.insertOrReplace(old)
        let oldLease = try await device.acquireProtection(pskId: old.pskId, serverId: old.serverId)
        await storage.setFailSaves(true)

        await #expect(throws: CommitTestError.failed) {
            try await device.insertOrReplaceAndProtect(replacement)
        }

        #expect(try await device.listRecords() == [old])
        try await device.releaseProtection(oldLease)
    }

    @Test("Commit evicts only an unprotected record and protects the inserted record")
    func commitUsesEligibleEviction() async throws {
        let device = SendspinDevice.ephemeral(capacity: SendspinDevice.minimumCapacity)
        var records: [PairingRecord] = []
        for index in 0 ..< SendspinDevice.minimumCapacity {
            let record = PairingRecord(psk: .generate(), serverId: deviceServerID(index + 10))
            records.append(record)
            try await device.insertOrReplace(record)
        }
        var leases: [PairingRecordProtectionLease] = []
        for record in records.dropFirst(2) {
            try await leases.append(device.acquireProtection(pskId: record.pskId, serverId: record.serverId))
        }
        let inserted = PairingRecord(psk: .generate(), serverId: deviceServerID(20))

        let insertedLease = try await device.insertOrReplaceAndProtect(inserted)

        let current = try await device.listRecords()
        #expect(!current.contains(records[0]))
        #expect(current.contains(inserted))
        await #expect(throws: SendspinDeviceError.storageExhausted) {
            try await device.insertOrReplaceAndProtect(
                PairingRecord(psk: .generate(), serverId: deviceServerID(21))
            )
        }
        try await device.releaseProtection(insertedLease)
        for lease in leases {
            try await device.releaseProtection(lease)
        }
    }

    @Test("An atomic replacement remains protected until its lease is released")
    func replacementProtectionFencesEviction() async throws {
        let device = SendspinDevice.ephemeral(capacity: SendspinDevice.minimumCapacity)
        let old = PairingRecord(psk: .generate(), serverId: deviceServerID(30))
        try await device.insertOrReplace(old)

        var otherRecords: [PairingRecord] = []
        for index in 31 ..< 35 {
            let record = PairingRecord(psk: .generate(), serverId: deviceServerID(index))
            otherRecords.append(record)
            try await device.insertOrReplace(record)
        }
        var otherLeases: [PairingRecordProtectionLease] = []
        for record in otherRecords.dropLast() {
            try await otherLeases.append(
                device.acquireProtection(pskId: record.pskId, serverId: record.serverId)
            )
        }

        let replacement = PairingRecord(psk: .generate(), serverId: old.serverId)
        let replacementLease = try await device.insertOrReplaceAndProtect(replacement)
        let firstInsertion = PairingRecord(psk: .generate(), serverId: deviceServerID(40))
        try await device.insertOrReplace(firstInsertion)
        let whileProtected = try await device.listRecords()
        #expect(whileProtected.contains(replacement))
        #expect(whileProtected.contains(firstInsertion))

        try await device.releaseProtection(replacementLease)
        let secondInsertion = PairingRecord(psk: .generate(), serverId: deviceServerID(41))
        try await device.insertOrReplace(secondInsertion)
        let afterRelease = try await device.listRecords()
        #expect(!afterRelease.contains(replacement))
        #expect(afterRelease.contains(secondInsertion))

        for lease in otherLeases {
            try await device.releaseProtection(lease)
        }
    }

    @Test("Corrupt snapshots reject sentinel pairing PSKs and invalid bookkeeping")
    func corruptSnapshotBookkeepingIsRejected() async throws {
        let corruptions: [SnapshotCorruption] = [.sentinelPairingPSK, .excessiveRoundCount, .invalidLastPlayedServerID]

        for corruption in corruptions {
            let storage = CommitTestStorage()
            let device = try await SendspinDevice.open(storage: storage)
            _ = device
            try await storage.corrupt(corruption)

            await #expect(throws: SendspinDeviceError.self) {
                _ = try await SendspinDevice.open(storage: storage)
            }
        }
    }
}

private enum SnapshotCorruption: Sendable {
    case sentinelPairingPSK
    case excessiveRoundCount
    case invalidLastPlayedServerID
}

private actor CommitTestStorage: SendspinDeviceStorage {
    private var bytes: Data?
    private var failSaves = false

    func load() async throws -> Data? {
        bytes
    }

    func save(_ data: Data) async throws {
        if failSaves {
            throw CommitTestError.failed
        }
        bytes = data
    }

    func create(_ data: Data) async throws -> Bool {
        if failSaves {
            throw CommitTestError.failed
        }
        guard bytes == nil else { return false }
        bytes = data
        return true
    }

    func setFailSaves(_ value: Bool) {
        failSaves = value
    }

    func corrupt(_ corruption: SnapshotCorruption) throws {
        guard let bytes,
              var snapshot = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw CommitTestError.missingSnapshot
        }
        switch corruption {
        case .sentinelPairingPSK:
            snapshot["pairingPsk"] = Psk.sentinel.bytes.base64EncodedString()
        case .excessiveRoundCount:
            snapshot["dynamicRoundCount"] = Int(dynamicPairingRoundLimit + 1)
        case .invalidLastPlayedServerID:
            snapshot["lastPlayedServerId"] = "not-a-server-id"
        }
        self.bytes = try JSONSerialization.data(withJSONObject: snapshot)
    }
}

private enum CommitTestError: Error {
    case failed
    case missingSnapshot
}

private func deviceServerID(_ seed: Int) -> String {
    Base64URL.encode(Data(repeating: UInt8(seed & 0xFF), count: 32))
}
