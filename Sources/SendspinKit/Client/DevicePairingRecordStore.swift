import Foundation

/// All connections belonging to a client share the device's serialized mutation queue.
struct DevicePairingRecordStore: PairingRecordStore, SendspinPersistenceProvider {
    let device: SendspinDevice

    func listRecords() async throws -> [PairingRecord] {
        try await device.listRecords()
    }

    func insertOrReplace(_ record: PairingRecord) async throws {
        try await device.insertOrReplace(record)
    }

    func insertOrReplaceAndProtect(_ record: PairingRecord) async throws -> PairingRecordProtectionLease {
        try await device.insertOrReplaceAndProtect(record)
    }

    func remove(pskId: String) async throws {
        try await device.remove(pskId: pskId)
    }

    func markUsed(pskId: String) async throws {
        try await device.markUsed(pskId: pskId)
    }

    func acquireProtection(pskId: String, serverId: String?) async throws -> PairingRecordProtectionLease {
        try await device.acquireProtection(pskId: pskId, serverId: serverId)
    }

    func releaseProtection(_ lease: PairingRecordProtectionLease) async throws {
        try await device.releaseProtection(lease)
    }

    func storageAccounting() async throws -> PairingStorageAccounting? {
        nil
    }

    func dynamicPairingRoundCount() async throws -> UInt32 {
        await device.dynamicPairingRoundCount()
    }

    func reserveDynamicPairingRound(limit: UInt32) async throws -> DynamicPairingRoundReservation {
        try await device.reserveDynamicPairingRound(limit: limit)
    }

    func resetDynamicPairingBudget() async throws {
        try await device.resetDynamicPairingBudget()
    }

    func loadLastPlayedServerId() async -> String? {
        await device.lastPlayedServerId()
    }

    func saveLastPlayedServerId(_ serverId: String) async {
        do {
            try await device.setLastPlayedServerId(serverId)
        } catch {
            Log.client.error("Failed to persist last-played server bookkeeping")
        }
    }
}
