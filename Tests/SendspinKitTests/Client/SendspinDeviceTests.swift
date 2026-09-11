import Foundation
@testable import SendspinKit
import Testing

@Suite("Sendspin device state")
struct SendspinDeviceTests {
    @Test("First durable open persists, and reload preserves identity and pairing")
    func firstOpenAndReload() async throws {
        let storage = DeviceTestStorage()
        let first = try await SendspinDevice.open(storage: storage)
        let clientID = first.clientId
        let token = first.makePairingToken()
        #expect(token.clientKey == first.identity.publicKeyBytes)
        #expect(token.clientKey != first.identity.secretKeyBytes)
        #expect(try PairingToken(string: token.string).clientKey == token.clientKey)
        #expect(await storage.saveCount == 1)

        let second = try await SendspinDevice.open(storage: storage)
        #expect(second.clientId == clientID)
        #expect(second.makePairingToken() == token)
    }

    @Test("Storage failure never installs an uncommitted mutation")
    func failedSaveRollsBack() async throws {
        let storage = DeviceTestStorage()
        let device = try await SendspinDevice.open(storage: storage)
        let record = PairingRecord(psk: .generate(), serverId: serverID(1))
        await storage.setFailSaves(true)

        await #expect(throws: TestStorageError.failed) {
            try await device.insertOrReplace(record)
        }
        #expect(try await device.listRecords().isEmpty)

        await storage.setFailSaves(false)
        try await device.insertOrReplace(record)
        #expect(try await device.listRecords() == [record])
    }

    @Test("Same server is replaced while duplicate PSK IDs are rejected")
    func replacementAndUniqueness() async throws {
        let device = SendspinDevice.ephemeral()
        let first = PairingRecord(psk: .generate(), serverId: serverID(2))
        let replacement = PairingRecord(psk: .generate(), serverId: serverID(2), used: true)
        try await device.insertOrReplace(first)
        try await device.insertOrReplace(replacement)
        #expect(try await device.listRecords() == [replacement])

        await #expect(throws: SendspinDeviceError.duplicatePskId) {
            try await device.insertOrReplace(PairingRecord(psk: replacement.psk, serverId: serverID(3)))
        }
        await #expect(throws: SendspinDeviceError.reservedPskId) {
            try await device.insertOrReplace(PairingRecord(psk: device.pairingPsk, serverId: serverID(4)))
        }
    }

    @Test("Capacity evicts an eligible record but never a protected record")
    func evictionAndProtectedRecords() async throws {
        let device = SendspinDevice.ephemeral(capacity: SendspinDevice.minimumCapacity)
        var records: [PairingRecord] = []
        for index in 0 ..< SendspinDevice.minimumCapacity {
            let record = PairingRecord(psk: .generate(), serverId: serverID(index + 10))
            records.append(record)
            try await device.insertOrReplace(record)
        }
        let leases = try await device.acquireProtection(pskId: records[1].pskId, serverId: records[1].serverId)
        let leases2 = try await device.acquireProtection(pskId: records[2].pskId, serverId: records[2].serverId)
        let leases3 = try await device.acquireProtection(pskId: records[3].pskId, serverId: records[3].serverId)
        let leases4 = try await device.acquireProtection(pskId: records[4].pskId, serverId: records[4].serverId)
        let newRecord = PairingRecord(psk: .generate(), serverId: serverID(20))
        try await device.insertOrReplace(newRecord)
        let current = try await device.listRecords()
        #expect(!current.contains(records[0]))
        #expect(current.contains(newRecord))

        await #expect(throws: SendspinDeviceError.storageExhausted) {
            _ = try await device.acquireProtection(pskId: newRecord.pskId, serverId: newRecord.serverId)
        }
        try await device.releaseProtection(leases)
        try await device.releaseProtection(leases2)
        try await device.releaseProtection(leases3)
        try await device.releaseProtection(leases4)
        try await device.remove(pskId: records[1].pskId)
        let afterRemoval = try await device.listRecords()
        #expect(!afterRemoval.contains(records[1]))
    }

    @Test("Global dynamic budget reservations are serialized")
    func budgetRaces() async throws {
        let device = SendspinDevice.ephemeral()
        let results = await withTaskGroup(of: DynamicPairingRoundReservation.self, returning: [DynamicPairingRoundReservation].self) { group in
            for _ in 0 ..< 30 {
                group.addTask {
                    await (try? device.reserveDynamicPairingRound(limit: dynamicPairingRoundLimit)) ?? .exhausted
                }
            }
            var values: [DynamicPairingRoundReservation] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        let reserved = results.compactMap { reservation -> UInt32? in
            guard case let .reserved(round, _) = reservation else { return nil }
            return round
        }
        #expect(reserved.count == Int(dynamicPairingRoundLimit))
        #expect(Set(reserved).count == Int(dynamicPairingRoundLimit))
        #expect(await device.dynamicPairingRoundCount() == dynamicPairingRoundLimit)

        try await device.resetDynamicPairingBudget()
        #expect(await device.dynamicPairingRoundCount() == 0)
    }

    @Test("Last played server is durable")
    func lastPlayedServer() async throws {
        let storage = DeviceTestStorage()
        let device = try await SendspinDevice.open(storage: storage)
        try await device.setLastPlayedServerId(serverID(30))
        let reloaded = try await SendspinDevice.open(storage: storage)
        #expect(await reloaded.lastPlayedServerId() == serverID(30))
        try await reloaded.setLastPlayedServerId(nil)
        #expect(await reloaded.lastPlayedServerId() == nil)
    }

    @Test("Invalid last played server IDs fail before persistence")
    func invalidLastPlayedServerDoesNotSave() async throws {
        let storage = DeviceTestStorage()
        let device = try await SendspinDevice.open(storage: storage)
        let savesBefore = await storage.saveCount

        await #expect(throws: SendspinDeviceError.invalidServerId) {
            try await device.setLastPlayedServerId("not-a-server-id")
        }

        #expect(await storage.saveCount == savesBefore)
        #expect(await device.lastPlayedServerId() == nil)
    }

    @Test("Capacity equal to the stored record count reloads successfully")
    func exactCapacityReload() async throws {
        let storage = DeviceTestStorage()
        let device = try await SendspinDevice.open(storage: storage, capacity: SendspinDevice.minimumCapacity)
        for index in 0 ..< SendspinDevice.minimumCapacity {
            try await device.insertOrReplace(PairingRecord(psk: .generate(), serverId: serverID(index)))
        }

        let reloaded = try await SendspinDevice.open(storage: storage, capacity: SendspinDevice.minimumCapacity)
        #expect(try await reloaded.listRecords().count == SendspinDevice.minimumCapacity)
    }

    @Test("Invalid stored bytes fail without regeneration")
    func invalidSnapshotDoesNotRegenerate() async throws {
        let storage = DeviceTestStorage(initial: Data([0x01, 0x02, 0x03]))
        await #expect(throws: SendspinDeviceError.invalidSnapshot) {
            _ = try await SendspinDevice.open(storage: storage)
        }
        #expect(await storage.saveCount == 0)
    }

    @Test("Reset requires an idle device and invalidates it after deletion")
    func resetLifecycle() async throws {
        let storage = ResettableDeviceTestStorage()
        let device = try await SendspinDevice.open(storage: storage)
        try await device.reset()
        #expect(await storage.deleteCount == 1)
        await #expect(throws: SendspinDeviceError.deviceReset) {
            _ = try await device.listRecords()
        }
        #expect(throws: SendspinDeviceError.deviceReset) {
            _ = try device.acquire()
        }
    }

    @Test("Reset prevents a later dynamic budget reset from recreating storage")
    func resetThenBudgetResetStaysInvalidated() async throws {
        let storage = ResettableDeviceTestStorage()
        let device = try await SendspinDevice.open(storage: storage)
        _ = try await device.reserveDynamicPairingRound(limit: 1)
        let savesBeforeReset = await storage.saveCount

        try await device.reset()
        await #expect(throws: SendspinDeviceError.deviceReset) {
            try await device.resetDynamicPairingBudget()
        }

        #expect(await storage.saveCount == savesBeforeReset)
        #expect(await storage.hasData == false)
    }

    @Test("Duplicate namespace opens reject pending opens and release after deinit")
    func namespaceOwnershipLifetime() async throws {
        let firstStorage = try KeychainSendspinDeviceStorage(
            service: "device-registry-test",
            account: UUID().uuidString,
            adapter: RegistryKeychainAdapter()
        )
        let namespace = firstStorage.backendNamespaceIdentifier
        let secondStorage = try KeychainSendspinDeviceStorage(
            service: namespace.service,
            account: namespace.account,
            accessGroup: namespace.accessGroup,
            adapter: RegistryKeychainAdapter()
        )
        do {
            let first = try await SendspinDevice.open(storage: firstStorage)
            await #expect(throws: SendspinDeviceError.namespaceAlreadyOpen) {
                _ = try await SendspinDevice.open(storage: secondStorage)
            }
            _ = first
        }
        let reopened = try await SendspinDevice.open(storage: secondStorage)
        #expect(reopened.clientId.count == 43)
    }

    @Test("A pending namespace open blocks a duplicate before backend load")
    func pendingNamespaceOpen() async throws {
        let account = UUID().uuidString
        let firstAdapter = RegistryKeychainAdapter(blockCopy: true)
        let firstStorage = try KeychainSendspinDeviceStorage(
            service: "device-pending-test",
            account: account,
            adapter: firstAdapter
        )
        let secondStorage = try KeychainSendspinDeviceStorage(
            service: "device-pending-test",
            account: account,
            adapter: RegistryKeychainAdapter()
        )
        let pending = Task {
            try await SendspinDevice.open(storage: firstStorage)
        }
        #expect(await firstAdapter.waitUntilCopyStarted())
        await #expect(throws: SendspinDeviceError.namespaceAlreadyOpen) {
            _ = try await SendspinDevice.open(storage: secondStorage)
        }
        await firstAdapter.finishCopy()
        _ = try await pending.value
    }

    @Test("Namespace configuration mismatch is rejected while open")
    func namespaceConfigurationMismatch() async throws {
        let account = UUID().uuidString
        let storage = try KeychainSendspinDeviceStorage(
            service: "device-config-test",
            account: account,
            adapter: RegistryKeychainAdapter()
        )
        let device = try await SendspinDevice.open(storage: storage, capacity: SendspinDevice.minimumCapacity)
        let sameNamespace = try KeychainSendspinDeviceStorage(
            service: "device-config-test",
            account: account,
            adapter: RegistryKeychainAdapter()
        )
        await #expect(throws: SendspinDeviceError.namespaceConfigurationMismatch) {
            _ = try await SendspinDevice.open(storage: sameNamespace, capacity: 6)
        }
        _ = device
    }

    @Test("Ownership is synchronous, exclusive, and lease-scoped")
    func ownership() throws {
        let device = SendspinDevice.ephemeral()
        let lease = try device.acquire()
        #expect(throws: SendspinDeviceError.deviceAlreadyOwned) {
            _ = try device.acquire()
        }
        #expect(throws: SendspinDeviceError.invalidLease) {
            try device.release(UUID())
        }
        try device.release(lease)
        _ = try device.acquire()
    }
}

private actor DeviceTestStorage: SendspinDeviceStorage {
    private var bytes: Data?
    private var failLoads = false
    private var failSaves = false
    private(set) var saveCount = 0

    init(initial: Data? = nil) {
        bytes = initial
    }

    func load() async throws -> Data? {
        if failLoads {
            throw TestStorageError.failed
        }
        return bytes
    }

    func save(_ data: Data) async throws {
        if failSaves {
            throw TestStorageError.failed
        }
        bytes = data
        saveCount += 1
    }

    func create(_ data: Data) async throws -> Bool {
        if failSaves {
            throw TestStorageError.failed
        }
        guard bytes == nil else { return false }
        bytes = data
        saveCount += 1
        return true
    }

    func setFailLoads(_ value: Bool) {
        failLoads = value
    }

    func setFailSaves(_ value: Bool) {
        failSaves = value
    }
}

private enum TestStorageError: Error {
    case failed
}

private actor ResettableDeviceTestStorage: SendspinDeviceStorageDeletion {
    private var bytes: Data?
    private(set) var deleteCount = 0
    private(set) var saveCount = 0

    var hasData: Bool {
        bytes != nil
    }

    func load() async throws -> Data? {
        bytes
    }

    func save(_ data: Data) async throws {
        bytes = data
        saveCount += 1
    }

    func create(_ data: Data) async throws -> Bool {
        guard bytes == nil else { return false }
        bytes = data
        saveCount += 1
        return true
    }

    func delete() async throws {
        bytes = nil
        deleteCount += 1
    }
}

private actor RegistryKeychainAdapter: SendspinKeychainItemAdapter {
    private var bytes: Data?
    private var blockCopy: Bool
    private var copyStarted = false
    private var copyWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockCopy: Bool = false) {
        self.blockCopy = blockCopy
    }

    func waitUntilCopyStarted() async -> Bool {
        if copyStarted {
            return true
        }
        await withCheckedContinuation { continuation in
            copyWaiters.append(continuation)
        }
        return true
    }

    func finishCopy() {
        blockCopy = false
        let waiters = copyWaiters
        copyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func copyMatching(_: SendspinKeychainItemQuery) async -> (status: OSStatus, data: Data?) {
        copyStarted = true
        let waiters = copyWaiters
        copyWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if blockCopy {
            await withCheckedContinuation { continuation in
                copyWaiters.append(continuation)
            }
        }
        return bytes.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
    }

    func update(
        _: SendspinKeychainItemQuery,
        data: Data,
        accessibility _: KeychainStorageAccessibility
    ) async -> OSStatus {
        bytes = data
        return errSecSuccess
    }

    func add(_ item: SendspinKeychainItem) async -> OSStatus {
        guard bytes == nil else { return errSecDuplicateItem }
        bytes = item.data
        return errSecSuccess
    }

    func delete(_: SendspinKeychainItemQuery) async -> OSStatus {
        bytes = nil
        return errSecSuccess
    }
}

private func serverID(_ seed: Int) -> String {
    Base64URL.encode(Data(repeating: UInt8(seed & 0xFF), count: 32))
}
