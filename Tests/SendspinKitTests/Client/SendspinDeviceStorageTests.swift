import Foundation
import Security
@testable import SendspinKit
import Testing

struct SendspinDeviceStorageTests {
    @Test("a missing Keychain item loads as nil")
    func missingItemIsAbsent() async throws {
        let adapter = TestKeychainAdapter(copyResult: (errSecItemNotFound, nil))
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )

        #expect(try await storage.load() == nil)
        #expect(await adapter.operations == [.copy])
        #expect(await adapter.lastQuery == SendspinKeychainItemQuery(
            service: "test.service",
            account: "device",
            accessGroup: nil
        ))
    }

    @Test("an existing item is loaded without exposing its namespace or value in errors")
    func existingItemLoads() async throws {
        let stored = Data([1, 2, 3, 4])
        let adapter = TestKeychainAdapter(copyResult: (errSecSuccess, stored))
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            accessGroup: "TEAM.shared",
            adapter: adapter
        )

        #expect(try await storage.load() == stored)
        #expect(await adapter.lastQuery == SendspinKeychainItemQuery(
            service: "test.service",
            account: "device",
            accessGroup: "TEAM.shared"
        ))
    }

    @Test("a successful update does not add a second item")
    func saveUpdatesExistingItem() async throws {
        let adapter = TestKeychainAdapter(updateResult: errSecSuccess)
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            accessibility: .whenUnlockedThisDeviceOnly,
            adapter: adapter
        )
        let value = Data([7, 8, 9])

        try await storage.save(value)

        #expect(await adapter.operations == [.update])
        #expect(await adapter.updatedData == value)
        #expect(await adapter.updatedAccessibility == .whenUnlockedThisDeviceOnly)
        #expect(await adapter.addedItem == nil)
    }

    @Test("a missing item is added with the configured Keychain policy")
    func saveAddsMissingItem() async throws {
        let adapter = TestKeychainAdapter(updateResult: errSecItemNotFound, addResult: errSecSuccess)
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            accessibility: .whenUnlockedThisDeviceOnly,
            accessGroup: "TEAM.shared",
            adapter: adapter
        )
        let value = Data([10, 11])

        try await storage.save(value)

        #expect(await adapter.operations == [.update, .add])
        #expect(await adapter.addedItem?.data == value)
        #expect(await adapter.addedItem?.accessibility == .whenUnlockedThisDeviceOnly)
        #expect(await adapter.addedItem?.query.accessGroup == "TEAM.shared")
    }

    @Test("initial creation reports that an existing item won without overwriting it")
    func initialCreationRaceDoesNotOverwriteWinner() async throws {
        let adapter = TestKeychainAdapter(addResult: errSecDuplicateItem)
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )

        let created = try await storage.create(Data([12]))
        #expect(!created)
        #expect(await adapter.operations == [.add])
        #expect(await adapter.updatedData == nil)
    }

    @Test("initial creation propagates Keychain failures")
    func initialCreationFailureIsTyped() async throws {
        let adapter = TestKeychainAdapter(addResult: errSecAuthFailed)
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )

        let error = await #expect(throws: KeychainSendspinDeviceStorageError.self) {
            try await storage.create(Data([13]))
        }
        #expect(error == .keychain(operation: .add, status: errSecAuthFailed))
        #expect(await adapter.operations == [.add])
    }

    @Test("a successful load without data is invalid stored data")
    func successfulLoadWithoutDataIsInvalid() async throws {
        let adapter = TestKeychainAdapter(copyResult: (errSecSuccess, nil))
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )

        let error = await #expect(throws: KeychainSendspinDeviceStorageError.self) {
            try await storage.load()
        }
        #expect(error == .invalidStoredData)
        #expect(await adapter.operations == [.copy])
    }

    @Test("Keychain failures retain operation and OSStatus")
    func saveFailureIsTyped() async throws {
        let adapter = TestKeychainAdapter(updateResult: errSecAuthFailed)
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )

        let error = await #expect(throws: KeychainSendspinDeviceStorageError.self) {
            try await storage.save(Data([13]))
        }
        #expect(error == .keychain(operation: .update, status: errSecAuthFailed))
        #expect(await adapter.operations == [.update])
    }

    @Test("save reports add failures when the item is absent")
    func saveAddFailureIsTyped() async throws {
        let adapter = TestKeychainAdapter(updateResult: errSecItemNotFound, addResult: errSecAuthFailed)
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )

        let error = await #expect(throws: KeychainSendspinDeviceStorageError.self) {
            try await storage.save(Data([14]))
        }
        #expect(error == .keychain(operation: .add, status: errSecAuthFailed))
        #expect(await adapter.operations == [.update, .add])
    }

    @Test("save propagates a retry update failure")
    func saveRetryFailureIsTyped() async throws {
        let adapter = SaveCreationRaceAdapter(retryResult: errSecAuthFailed)
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )

        let error = await #expect(throws: KeychainSendspinDeviceStorageError.self) {
            try await storage.save(Data([14]))
        }
        #expect(error == .keychain(operation: .update, status: errSecAuthFailed))
        #expect(await adapter.operations == [.update, .add, .update])
    }

    @Test("save retries replacement when creation loses a race")
    func saveCreationRaceRetriesUpdate() async throws {
        let adapter = SaveCreationRaceAdapter(retryResult: errSecSuccess)
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            accessibility: .whenUnlockedThisDeviceOnly,
            adapter: adapter
        )
        let value = Data([14])

        try await storage.save(value)

        #expect(await adapter.operations == [.update, .add, .update])
        #expect(await adapter.updatedData == value)
        #expect(await adapter.updatedAccessibility == .whenUnlockedThisDeviceOnly)
    }

    @Test("concurrent initial creation installs exactly one winner")
    func concurrentInitialCreationDoesNotOverwriteWinner() async throws {
        let adapter = ConcurrentCreationAdapter()
        let first = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )
        let second = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )

        let results = try await withThrowingTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask { try await first.create(Data([21])) }
            group.addTask { try await second.create(Data([22])) }
            var values: [Bool] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        #expect(results.filter(\.self).count == 1)
        #expect(results.filter { !$0 }.count == 1)
        #expect(await adapter.operations == [.add, .add])
        let winner = await adapter.data
        #expect(winner == Data([21]) || winner == Data([22]))
    }

    @Test("delete failures retain operation and OSStatus")
    func deleteFailureIsTyped() async throws {
        let adapter = TestKeychainAdapter(deleteResult: errSecAuthFailed)
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )

        let error = await #expect(throws: KeychainSendspinDeviceStorageError.self) {
            try await storage.delete()
        }
        #expect(error == .keychain(operation: .delete, status: errSecAuthFailed))
        #expect(await adapter.operations == [.delete])
    }

    @Test("delete is explicit and treats an absent item as success")
    func deleteIsExplicit() async throws {
        let adapter = TestKeychainAdapter(deleteResult: errSecItemNotFound)
        let storage = try KeychainSendspinDeviceStorage(
            service: "test.service",
            account: "device",
            adapter: adapter
        )

        try await storage.delete()

        #expect(await adapter.operations == [.delete])
    }

    @Test("namespace identity is stable for the same app namespace")
    func namespaceIdentity() throws {
        let first = try KeychainSendspinDeviceStorage(service: "service", account: "account")
        let second = try KeychainSendspinDeviceStorage(service: "service", account: "account")
        let shared = try KeychainSendspinDeviceStorage(
            service: "service",
            account: "account",
            accessGroup: "TEAM.group"
        )

        #expect(first.backendNamespaceIdentifier == second.backendNamespaceIdentifier)
        #expect(first.backendNamespaceIdentifier != shared.backendNamespaceIdentifier)
    }

    @Test("structured namespaces distinguish delimiter-colliding components")
    func namespaceDelimiterCollisionIsDistinct() throws {
        let first = try KeychainSendspinDeviceStorage(service: "a:b", account: "c")
        let second = try KeychainSendspinDeviceStorage(service: "a", account: "b:c")

        #expect(first.backendNamespaceIdentifier != second.backendNamespaceIdentifier)
        #expect(first.backendNamespaceIdentifier == SendspinDeviceStorageNamespace(
            service: "a:b",
            account: "c",
            accessGroup: nil
        ))
    }

    @Test("empty namespace components are rejected")
    func invalidNamespaceIsRejected() {
        #expect(throws: KeychainSendspinDeviceStorageError.invalidConfiguration) {
            try KeychainSendspinDeviceStorage(service: "", account: "device")
        }
        #expect(throws: KeychainSendspinDeviceStorageError.invalidConfiguration) {
            try KeychainSendspinDeviceStorage(service: "service", account: "", accessGroup: "")
        }
    }
}

private actor SaveCreationRaceAdapter: SendspinKeychainItemAdapter {
    enum Operation: Sendable, Equatable {
        case update
        case add
    }

    private(set) var operations: [Operation] = []
    private(set) var updatedData: Data?
    private(set) var updatedAccessibility: KeychainStorageAccessibility?
    private let retryResult: OSStatus
    private var updateCount = 0

    init(retryResult: OSStatus) {
        self.retryResult = retryResult
    }

    func copyMatching(_: SendspinKeychainItemQuery) async -> (status: OSStatus, data: Data?) {
        (errSecItemNotFound, nil)
    }

    func update(
        _: SendspinKeychainItemQuery,
        data: Data,
        accessibility: KeychainStorageAccessibility
    ) async -> OSStatus {
        operations.append(.update)
        updateCount += 1
        updatedData = data
        updatedAccessibility = accessibility
        return updateCount == 1 ? errSecItemNotFound : retryResult
    }

    func add(_: SendspinKeychainItem) async -> OSStatus {
        operations.append(.add)
        return errSecDuplicateItem
    }

    func delete(_: SendspinKeychainItemQuery) async -> OSStatus {
        errSecSuccess
    }
}

private actor ConcurrentCreationAdapter: SendspinKeychainItemAdapter {
    enum Operation: Sendable, Equatable {
        case add
    }

    private(set) var operations: [Operation] = []
    private(set) var data: Data?

    func copyMatching(_: SendspinKeychainItemQuery) async -> (status: OSStatus, data: Data?) {
        guard let data else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func update(
        _: SendspinKeychainItemQuery,
        data: Data,
        accessibility _: KeychainStorageAccessibility
    ) async -> OSStatus {
        self.data = data
        return errSecSuccess
    }

    func add(_ item: SendspinKeychainItem) async -> OSStatus {
        operations.append(.add)
        guard data == nil else { return errSecDuplicateItem }
        data = item.data
        return errSecSuccess
    }

    func delete(_: SendspinKeychainItemQuery) async -> OSStatus {
        data = nil
        return errSecSuccess
    }
}

private actor TestKeychainAdapter: SendspinKeychainItemAdapter {
    enum Operation: Sendable, Equatable {
        case copy
        case update
        case add
        case delete
    }

    private let copyResult: (status: OSStatus, data: Data?)
    private let updateResult: OSStatus
    private let addResult: OSStatus
    private let deleteResult: OSStatus
    private(set) var operations: [Operation] = []
    private(set) var lastQuery: SendspinKeychainItemQuery?
    private(set) var updatedData: Data?
    private(set) var updatedAccessibility: KeychainStorageAccessibility?
    private(set) var addedItem: SendspinKeychainItem?

    init(
        copyResult: (OSStatus, Data?) = (errSecItemNotFound, nil),
        updateResult: OSStatus = errSecItemNotFound,
        addResult: OSStatus = errSecSuccess,
        deleteResult: OSStatus = errSecSuccess
    ) {
        self.copyResult = copyResult
        self.updateResult = updateResult
        self.addResult = addResult
        self.deleteResult = deleteResult
    }

    func copyMatching(_ query: SendspinKeychainItemQuery) async -> (status: OSStatus, data: Data?) {
        operations.append(.copy)
        lastQuery = query
        return copyResult
    }

    func update(
        _ query: SendspinKeychainItemQuery,
        data: Data,
        accessibility: KeychainStorageAccessibility
    ) async -> OSStatus {
        operations.append(.update)
        lastQuery = query
        updatedData = data
        updatedAccessibility = accessibility
        return updateResult
    }

    func add(_ item: SendspinKeychainItem) async -> OSStatus {
        operations.append(.add)
        lastQuery = item.query
        addedItem = item
        return addResult
    }

    func delete(_ query: SendspinKeychainItemQuery) async -> OSStatus {
        operations.append(.delete)
        lastQuery = query
        return deleteResult
    }
}
