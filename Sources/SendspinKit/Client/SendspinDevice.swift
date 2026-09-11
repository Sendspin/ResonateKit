import Foundation

/// Errors raised while opening or mutating a device.
public enum SendspinDeviceError: Error, Sendable, Equatable {
    case invalidSnapshot
    case unsupportedSnapshotVersion
    case invalidIdentity
    case invalidPairingSecret
    case invalidStaticCode
    case invalidServerId
    case duplicatePskId
    case duplicateServerRecord
    case reservedPskId
    case storageExhausted
    case recordProtected
    case deviceAlreadyOwned
    case invalidCapacity
    case invalidLease
    case namespaceAlreadyOpen
    case namespaceConfigurationMismatch
    case resetUnavailable
    case resetWhileActive
    case deviceReset
}

private final class SendspinDeviceNamespaceRegistry: @unchecked Sendable {
    static let shared = SendspinDeviceNamespaceRegistry()

    private struct Entry {
        let token: UUID
        var staticCode: String?
        let capacity: Int
    }

    private let lock = NSLock()
    private var entries: [SendspinDeviceStorageNamespace: Entry] = [:]

    func reserve(_ namespace: SendspinDeviceStorageNamespace, staticCode: String?, capacity: Int) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[namespace] {
            if entry.capacity != capacity || (staticCode != nil && entry.staticCode != staticCode) {
                throw SendspinDeviceError.namespaceConfigurationMismatch
            }
            throw SendspinDeviceError.namespaceAlreadyOpen
        }
        let token = UUID()
        entries[namespace] = Entry(token: token, staticCode: staticCode, capacity: capacity)
        return token
    }

    func release(_ namespace: SendspinDeviceStorageNamespace, token: UUID) {
        lock.lock()
        if entries[namespace]?.token == token {
            entries.removeValue(forKey: namespace)
        }
        lock.unlock()
    }
}

/// The library-owned enduring protocol state for one Sendspin client device.
/// One live client at a time may own a device; sequential reuse is supported.
/// Cross-process ownership is unsupported and cannot be detected here.
public final class SendspinDevice: @unchecked Sendable {
    public static let defaultCapacity = 16
    public static let minimumCapacity = 5

    private static let snapshotVersion = 1

    /// The immutable identity used to construct connection handshakes.
    let identity: SendspinIdentity
    /// The immutable client Pairing PSK used to construct connection handshakes.
    let pairingPsk: Psk
    /// The provisioned static code, when one is present.
    let staticCode: String?

    private let storage: (any SendspinDeviceStorage)?
    private let capacity: Int
    private let transactionMutex = AsyncTransactionMutex()
    private let stateLock = NSLock()
    private var state: DeviceState
    private var ownerLease: UUID?
    private var protectionLeases: [UUID: Set<String>] = [:]
    private var resetting = false
    private var invalidated = false
    private var namespace: SendspinDeviceStorageNamespace?
    private var namespaceReservation: UUID?

    private struct DeviceState: Sendable {
        var records: [PairingRecord]
        var dynamicRoundCount: UInt32
        var lastPlayedServerId: String?
    }

    private struct Snapshot: Codable, Sendable {
        let version: Int
        let identitySecret: Data
        let pairingPsk: Data
        let staticCode: String?
        let capacity: Int
        let records: [SnapshotRecord]
        let dynamicRoundCount: UInt32
        let lastPlayedServerId: String?
    }

    private struct SnapshotRecord: Codable, Sendable {
        let psk: Data
        let serverId: String?
        let used: Bool
    }

    deinit {
        if let namespace, let namespaceReservation {
            SendspinDeviceNamespaceRegistry.shared.release(namespace, token: namespaceReservation)
        }
    }

    private init(
        identity: SendspinIdentity,
        pairingPsk: Psk,
        staticCode: String?,
        records: [PairingRecord],
        dynamicRoundCount: UInt32,
        lastPlayedServerId: String?,
        storage: (any SendspinDeviceStorage)?,
        capacity: Int,
        namespace: SendspinDeviceStorageNamespace? = nil,
        namespaceReservation: UUID? = nil
    ) {
        self.identity = identity
        self.pairingPsk = pairingPsk
        self.staticCode = staticCode
        self.storage = storage
        self.capacity = capacity
        self.namespace = namespace
        self.namespaceReservation = namespaceReservation
        state = DeviceState(
            records: records,
            dynamicRoundCount: dynamicRoundCount,
            lastPlayedServerId: lastPlayedServerId
        )
    }

    /// Open a durable device, generating and durably installing state only when
    /// the backend reports that no snapshot exists.
    public static func open(
        storage: any SendspinDeviceStorage,
        staticCode: String? = nil,
        capacity: Int = SendspinDevice.defaultCapacity
    ) async throws -> SendspinDevice {
        guard capacity >= minimumCapacity else { throw SendspinDeviceError.invalidCapacity }
        if let staticCode, !PairingManagementConfiguration.isValidStaticPairingCode(staticCode) {
            throw SendspinDeviceError.invalidStaticCode
        }
        let namespace = (storage as? KeychainSendspinDeviceStorage)?.backendNamespaceIdentifier
        let reservation = try namespace.map {
            try SendspinDeviceNamespaceRegistry.shared.reserve($0, staticCode: staticCode, capacity: capacity)
        }
        do {
            let data = try await storage.load()
            if let data {
                let snapshot = try decodeSnapshot(data)
                if let staticCode, staticCode != snapshot.staticCode {
                    throw SendspinDeviceError.namespaceConfigurationMismatch
                }
                guard snapshot.capacity == capacity else { throw SendspinDeviceError.namespaceConfigurationMismatch }
                guard snapshot.records.count <= capacity else { throw SendspinDeviceError.invalidSnapshot }
                return try makeDevice(
                    from: snapshot,
                    storage: storage,
                    capacity: capacity,
                    namespace: namespace,
                    namespaceReservation: reservation
                )
            }

            let identity = SendspinIdentity.generate()
            let pairingPsk = Psk.generate()
            let device = SendspinDevice(
                identity: identity,
                pairingPsk: pairingPsk,
                staticCode: staticCode,
                records: [],
                dynamicRoundCount: 0,
                lastPlayedServerId: nil,
                storage: storage,
                capacity: capacity,
                namespace: namespace,
                namespaceReservation: reservation
            )
            let snapshot = try device.encodedSnapshot()
            if try await storage.create(snapshot) {
                return device
            }

            guard let winnerData = try await storage.load() else {
                throw SendspinDeviceError.invalidSnapshot
            }
            let winner = try decodeSnapshot(winnerData)
            if let staticCode, staticCode != winner.staticCode {
                throw SendspinDeviceError.namespaceConfigurationMismatch
            }
            guard winner.capacity == capacity else { throw SendspinDeviceError.namespaceConfigurationMismatch }
            guard winner.records.count <= capacity else { throw SendspinDeviceError.invalidSnapshot }
            return try makeDevice(
                from: winner,
                storage: storage,
                capacity: capacity,
                namespace: namespace,
                namespaceReservation: reservation
            )
        } catch {
            if let namespace, let reservation {
                SendspinDeviceNamespaceRegistry.shared.release(namespace, token: reservation)
            }
            throw error
        }
    }

    /// Create a deliberately non-persistent device. State is retained until this
    /// object is released; no implicit backend or process-global namespace exists.
    public static func ephemeral(
        staticCode: String? = nil,
        capacity: Int = SendspinDevice.defaultCapacity
    ) -> SendspinDevice {
        precondition(capacity >= minimumCapacity, "SendspinDevice capacity must be at least five")
        if let staticCode {
            precondition(PairingManagementConfiguration.isValidStaticPairingCode(staticCode), "SendspinDevice static code must be eight digits")
        }
        return SendspinDevice(
            identity: .generate(),
            pairingPsk: .generate(),
            staticCode: staticCode,
            records: [],
            dynamicRoundCount: 0,
            lastPlayedServerId: nil,
            storage: nil,
            capacity: capacity
        )
    }

    /// Public identifier; the identity secret is intentionally not exposed here.
    public var clientId: String {
        identity.clientId
    }

    /// Deliberately export the secret-bearing setup token for an intentional pairing
    /// presentation flow. Callers should treat the returned value as a secret.
    public func makePairingToken() -> PairingToken {
        PairingToken(clientKey: identity.publicKeyBytes, pairingPsk: pairingPsk)
    }

    /// Acquire this device for one live client. This method is synchronous so a
    /// throwing client initializer can establish ownership before it returns.
    func acquire() throws -> UUID {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !invalidated, !resetting else { throw SendspinDeviceError.deviceReset }
        guard ownerLease == nil else { throw SendspinDeviceError.deviceAlreadyOwned }
        let lease = UUID()
        ownerLease = lease
        return lease
    }

    /// Release ownership only for the lease that acquired the device.
    func release(_ lease: UUID) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard ownerLease == lease else { throw SendspinDeviceError.invalidLease }
        ownerLease = nil
    }

    public func reset() async throws {
        guard let deletionStorage = storage as? any SendspinDeviceStorageDeletion else {
            throw SendspinDeviceError.resetUnavailable
        }
        try await transactionMutex.withLock {
            let active = stateLock.withLock { ownerLease != nil || !protectionLeases.isEmpty || resetting || invalidated }
            guard !active else { throw SendspinDeviceError.resetWhileActive }
            stateLock.withLock { resetting = true }
            do {
                try await deletionStorage.delete()
            } catch {
                stateLock.withLock { resetting = false }
                throw error
            }
            stateLock.withLock {
                invalidated = true
                resetting = false
                ownerLease = nil
                protectionLeases.removeAll()
            }
            if let namespace, let namespaceReservation {
                SendspinDeviceNamespaceRegistry.shared.release(namespace, token: namespaceReservation)
                self.namespaceReservation = nil
            }
        }
    }

    func acquireProtection(pskId: String, serverId: String?) async throws -> PairingRecordProtectionLease {
        try await transactionMutex.withLock {
            let snapshot = stateLock.withLock { (state, invalidated, resetting, protectionLeases) }
            guard !snapshot.1, !snapshot.2 else { throw SendspinDeviceError.deviceReset }
            guard let record = snapshot.0.records.first(where: { $0.pskId == pskId }),
                  record.serverId == serverId else { throw PairingRecordStoreError.pskLookupMiss }
            guard snapshot.3.count < capacity - 1 else { throw SendspinDeviceError.storageExhausted }
            let lease = PairingRecordProtectionLease(id: UUID(), pskIds: [pskId])
            stateLock.withLock { protectionLeases[lease.id] = [pskId] }
            return lease
        }
    }

    func releaseProtection(_ lease: PairingRecordProtectionLease) async throws {
        try await transactionMutex.withLock {
            guard stateLock.withLock({ protectionLeases.removeValue(forKey: lease.id) != nil }) else {
                throw SendspinDeviceError.invalidLease
            }
        }
    }

    /// Return the current records for handshake candidate construction.
    func listRecords() async throws -> [PairingRecord] {
        try await transactionMutex.withLock {
            guard !stateLock.withLock({ invalidated || resetting }) else { throw SendspinDeviceError.deviceReset }
            return stateLock.withLock { state.records }
        }
    }

    /// Insert a record, replacing the record for the same non-nil server ID.
    /// A new record evicts the oldest eligible record when at capacity.
    func insertOrReplace(_ record: PairingRecord) async throws {
        try validateRecord(record)
        try await transactionMutex.withLock {
            guard !stateLock.withLock({ invalidated || resetting }) else { throw SendspinDeviceError.deviceReset }
            let protected = Set(stateLock.withLock { protectionLeases.values.flatMap(\.self) })
            var next = stateLock.withLock { state }
            let reserved = reservedPskIds
            guard !reserved.contains(record.pskId) else { throw SendspinDeviceError.reservedPskId }

            if let serverId = record.serverId,
               let index = next.records.firstIndex(where: { $0.serverId == serverId }) {
                guard next.records[index] != record else {
                    return
                }
                if next.records.contains(where: { $0.pskId == record.pskId && $0.serverId != serverId }) {
                    throw SendspinDeviceError.duplicatePskId
                }
                next.records[index] = record
            } else {
                guard !next.records.contains(where: { $0.pskId == record.pskId }) else {
                    throw SendspinDeviceError.duplicatePskId
                }
                if next.records.count >= capacity {
                    guard let eviction = next.records.firstIndex(where: { !protected.contains($0.pskId) }) else {
                        throw SendspinDeviceError.storageExhausted
                    }
                    next.records.remove(at: eviction)
                }
                next.records.append(record)
            }
            try await commit(next)
        }
    }

    /// Persist a record and protect it before releasing the transaction mutex.
    func insertOrReplaceAndProtect(_ record: PairingRecord) async throws -> PairingRecordProtectionLease {
        try validateRecord(record)
        return try await transactionMutex.withLock {
            let snapshot = stateLock.withLock { (state, invalidated, resetting, protectionLeases) }
            guard !snapshot.1, !snapshot.2 else { throw SendspinDeviceError.deviceReset }
            guard !reservedPskIds.contains(record.pskId) else { throw SendspinDeviceError.reservedPskId }
            var next = snapshot.0
            let protected = Set(snapshot.3.values.flatMap(\.self))
            let replacesServerRecord = record.serverId.map { serverId in
                next.records.contains { $0.serverId == serverId }
            } ?? false
            if !replacesServerRecord {
                guard snapshot.3.count < max(1, capacity - 1) else { throw SendspinDeviceError.storageExhausted }
            }

            if let serverId = record.serverId,
               let index = next.records.firstIndex(where: { $0.serverId == serverId }) {
                if next.records.contains(where: { $0.pskId == record.pskId && $0.serverId != serverId }) {
                    throw SendspinDeviceError.duplicatePskId
                }
                next.records[index] = record
            } else {
                guard !next.records.contains(where: { $0.pskId == record.pskId }) else {
                    throw SendspinDeviceError.duplicatePskId
                }
                if next.records.count >= capacity {
                    guard let eviction = next.records.firstIndex(where: { !protected.contains($0.pskId) }) else {
                        throw SendspinDeviceError.storageExhausted
                    }
                    next.records.remove(at: eviction)
                }
                next.records.append(record)
            }

            let lease = PairingRecordProtectionLease(id: UUID(), pskIds: [record.pskId])
            try await commit(next)
            stateLock.withLock {
                protectionLeases[lease.id] = lease.pskIds
            }
            return lease
        }
    }

    /// Remove a record explicitly. Explicit unpairing is allowed even while a
    /// connection protects the record from capacity eviction.
    func remove(pskId: String) async throws {
        try await transactionMutex.withLock {
            guard !stateLock.withLock({ invalidated || resetting }) else { throw SendspinDeviceError.deviceReset }
            var next = stateLock.withLock { state }
            guard let index = next.records.firstIndex(where: { $0.pskId == pskId }) else { return }
            next.records.remove(at: index)
            try await commit(next)
        }
    }

    /// Mark a record as authenticated and persist that change before returning.
    func markUsed(pskId: String) async throws {
        try await transactionMutex.withLock {
            guard !stateLock.withLock({ invalidated || resetting }) else { throw SendspinDeviceError.deviceReset }
            var next = stateLock.withLock { state }
            guard let index = next.records.firstIndex(where: { $0.pskId == pskId }) else { return }
            guard !next.records[index].used else { return }
            next.records[index].used = true
            try await commit(next)
        }
    }

    /// Atomically reserve one global dynamic pairing round and persist it before
    /// reporting success.
    func reserveDynamicPairingRound(limit: UInt32 = dynamicPairingRoundLimit) async throws -> DynamicPairingRoundReservation {
        try await transactionMutex.withLock {
            guard !stateLock.withLock({ invalidated || resetting }) else { throw SendspinDeviceError.deviceReset }
            let current = stateLock.withLock { state }
            guard current.dynamicRoundCount < limit else { return .exhausted }
            var next = current
            next.dynamicRoundCount += 1
            try await commit(next)
            return .reserved(round: next.dynamicRoundCount, remaining: limit - next.dynamicRoundCount)
        }
    }

    func resetDynamicPairingBudget() async throws {
        try await transactionMutex.withLock {
            guard !stateLock.withLock({ invalidated || resetting }) else { throw SendspinDeviceError.deviceReset }
            var next = stateLock.withLock { state }
            next.dynamicRoundCount = 0
            try await commit(next)
        }
    }

    func dynamicPairingRoundCount() async -> UInt32 {
        stateLock.withLock { state.dynamicRoundCount }
    }

    func lastPlayedServerId() async -> String? {
        stateLock.withLock { state.lastPlayedServerId }
    }

    func setLastPlayedServerId(_ serverId: String?) async throws {
        if let serverId, Base64URL.decode(serverId, count: 32) == nil {
            throw SendspinDeviceError.invalidServerId
        }
        try await transactionMutex.withLock {
            guard !stateLock.withLock({ invalidated || resetting }) else { throw SendspinDeviceError.deviceReset }
            var next = stateLock.withLock { state }
            next.lastPlayedServerId = serverId
            try await commit(next)
        }
    }

    private func commit(_ next: DeviceState) async throws {
        let data = try encodedSnapshot(for: next)
        if let storage {
            try await storage.save(data)
        }
        stateLock.withLock {
            state = next
        }
    }

    private func encodedSnapshot() throws -> Data {
        try encodedSnapshot(for: stateLock.withLock { state })
    }

    private func encodedSnapshot(for state: DeviceState) throws -> Data {
        let snapshot = Snapshot(
            version: Self.snapshotVersion,
            identitySecret: identity.secretKeyBytes,
            pairingPsk: pairingPsk.bytes,
            staticCode: staticCode,
            capacity: capacity,
            records: state.records.map { SnapshotRecord(psk: $0.psk.bytes, serverId: $0.serverId, used: $0.used) },
            dynamicRoundCount: state.dynamicRoundCount,
            lastPlayedServerId: state.lastPlayedServerId
        )
        do {
            return try JSONEncoder().encode(snapshot)
        } catch {
            throw SendspinDeviceError.invalidSnapshot
        }
    }

    private func validateRecord(_ record: PairingRecord) throws {
        guard let serverId = record.serverId,
              Base64URL.decode(serverId, count: 32) != nil else {
            throw SendspinDeviceError.invalidServerId
        }
    }

    private var reservedPskIds: Set<String> {
        [Psk.sentinel.pskId, pairingPsk.pskId]
    }

    private static func decodeSnapshot(_ data: Data) throws -> Snapshot {
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == snapshotVersion else { throw SendspinDeviceError.unsupportedSnapshotVersion }
            return snapshot
        } catch let error as SendspinDeviceError {
            throw error
        } catch {
            throw SendspinDeviceError.invalidSnapshot
        }
    }

    private static func makeDevice(
        from snapshot: Snapshot,
        storage: any SendspinDeviceStorage,
        capacity: Int,
        namespace: SendspinDeviceStorageNamespace?,
        namespaceReservation: UUID?
    ) throws -> SendspinDevice {
        guard let identity = SendspinIdentity(secretKeyBytes: snapshot.identitySecret) else {
            throw SendspinDeviceError.invalidIdentity
        }
        guard let pairingPsk = Psk(bytes: snapshot.pairingPsk), pairingPsk != .sentinel else {
            throw SendspinDeviceError.invalidPairingSecret
        }
        guard snapshot.dynamicRoundCount <= dynamicPairingRoundLimit else {
            throw SendspinDeviceError.invalidSnapshot
        }
        if let lastPlayedServerId = snapshot.lastPlayedServerId,
           Base64URL.decode(lastPlayedServerId, count: 32) == nil {
            throw SendspinDeviceError.invalidSnapshot
        }
        if let staticCode = snapshot.staticCode, !PairingManagementConfiguration.isValidStaticPairingCode(staticCode) {
            throw SendspinDeviceError.invalidStaticCode
        }
        let reserved = Set([Psk.sentinel.pskId, pairingPsk.pskId])
        var seenPskIds = reserved
        var seenServers = Set<String>()
        var records: [PairingRecord] = []
        for value in snapshot.records {
            guard let psk = Psk(bytes: value.psk) else { throw SendspinDeviceError.invalidSnapshot }
            guard seenPskIds.insert(psk.pskId).inserted else { throw SendspinDeviceError.duplicatePskId }
            guard let serverId = value.serverId,
                  Base64URL.decode(serverId, count: 32) != nil else {
                throw SendspinDeviceError.invalidServerId
            }
            guard seenServers.insert(serverId).inserted else {
                throw SendspinDeviceError.duplicateServerRecord
            }
            records.append(PairingRecord(psk: psk, serverId: serverId, used: value.used))
        }
        return SendspinDevice(
            identity: identity,
            pairingPsk: pairingPsk,
            staticCode: snapshot.staticCode,
            records: records,
            dynamicRoundCount: snapshot.dynamicRoundCount,
            lastPlayedServerId: snapshot.lastPlayedServerId,
            storage: storage,
            capacity: capacity,
            namespace: namespace,
            namespaceReservation: namespaceReservation
        )
    }
}

private final class AsyncTransactionMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !held {
                held = true
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            held = false
            lock.unlock()
            return
        }
        let continuation = waiters.removeFirst()
        lock.unlock()
        continuation.resume()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
