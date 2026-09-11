import Foundation
import Security

/// Durable storage for the opaque device-state snapshot owned by SendspinKit.
/// Storage reports absence and I/O failures; implementations must create atomically.
/// Hosts must keep one live device owner per namespace; atomic creation does not serialize existing opens.
public protocol SendspinDeviceStorage: Sendable {
    /// Loads the stored device-state snapshot, or `nil` when no snapshot exists.
    func load() async throws -> Data?

    /// Atomically installs `data` only when the snapshot is absent.
    /// Returns `true` only when durably created; `false` never replaces existing data.
    /// On `false`, the caller must load the existing snapshot before constructing.
    func create(_ data: Data) async throws -> Bool

    /// Replaces the complete device-state snapshot durably before returning.
    func save(_ data: Data) async throws
}

struct SendspinDeviceStorageNamespace: Sendable, Hashable {
    let service: String
    let account: String
    let accessGroup: String?
}

/// Optional reset capability kept separate from ordinary storage replacement.
public protocol SendspinDeviceStorageDeletion: SendspinDeviceStorage {
    /// Deletes the snapshot. Deleting an already-missing snapshot succeeds.
    func delete() async throws
}

/// Keychain accessibility policies supported by ``KeychainSendspinDeviceStorage``.
public enum KeychainStorageAccessibility: Sendable, Equatable {
    /// Available after the first device unlock and not migrated to another device.
    case afterFirstUnlockThisDeviceOnly
    /// Available only while the device is unlocked and not migrated to another device.
    case whenUnlockedThisDeviceOnly

    fileprivate var keychainValue: CFString {
        switch self {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedThisDeviceOnly:
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

/// The Keychain operation associated with a typed Keychain failure.
public enum KeychainSendspinDeviceStorageOperation: Sendable, Equatable {
    case load
    case update
    case add
    case delete
}

/// Errors raised by ``KeychainSendspinDeviceStorage``.
///
/// OSStatus values distinguish access failures without fallback or secret data in errors.
public enum KeychainSendspinDeviceStorageError: Error, Sendable, Equatable {
    /// The service, account, or access group was empty or otherwise not usable.
    case invalidConfiguration
    /// The Keychain returned an unexpected successful result without data.
    case invalidStoredData
    /// A Keychain operation failed.
    case keychain(operation: KeychainSendspinDeviceStorageOperation, status: OSStatus)
}

extension KeychainSendspinDeviceStorageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The Keychain storage service, account, or access group is invalid."
        case .invalidStoredData:
            "The Keychain item did not contain data."
        case let .keychain(operation, status):
            "Keychain \(operation.description) failed with OSStatus \(status)."
        }
    }
}

extension KeychainSendspinDeviceStorageOperation: CustomStringConvertible {
    public var description: String {
        switch self {
        case .load: "load"
        case .update: "update"
        case .add: "add"
        case .delete: "delete"
        }
    }
}

/// App-namespaced storage using device-only, non-synchronizable data-protection Keychain items.
/// Accessibility and an entitled access group are configurable.
public struct KeychainSendspinDeviceStorage: SendspinDeviceStorageDeletion, Sendable {
    private let service: String
    private let account: String
    private let accessibility: KeychainStorageAccessibility
    private let accessGroup: String?
    private let adapter: any SendspinKeychainItemAdapter

    /// `service`/`account` identify the item; an explicit `accessGroup` requires entitlements.
    /// `nil` uses the app's default group, but queries may search any group accessible to the app.
    /// Choose one canonical configuration: `nil`, or an explicit entitled group for scoping.
    public init(
        service: String,
        account: String,
        accessibility: KeychainStorageAccessibility = .afterFirstUnlockThisDeviceOnly,
        accessGroup: String? = nil
    ) throws {
        guard !service.isEmpty, !account.isEmpty, accessGroup.map({ !$0.isEmpty }) ?? true else {
            throw KeychainSendspinDeviceStorageError.invalidConfiguration
        }
        self.service = service
        self.account = account
        self.accessibility = accessibility
        self.accessGroup = accessGroup
        adapter = SystemSendspinKeychainItemAdapter()
    }

    /// Structured fields prevent delimiter collisions between distinct namespaces.
    var backendNamespaceIdentifier: SendspinDeviceStorageNamespace {
        SendspinDeviceStorageNamespace(service: service, account: account, accessGroup: accessGroup)
    }

    public func load() async throws -> Data? {
        let result = await adapter.copyMatching(query)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data else {
                throw KeychainSendspinDeviceStorageError.invalidStoredData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainSendspinDeviceStorageError.keychain(operation: .load, status: result.status)
        }
    }

    public func create(_ data: Data) async throws -> Bool {
        let status = await adapter.add(
            SendspinKeychainItem(query: query, data: data, accessibility: accessibility)
        )
        switch status {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        default:
            throw KeychainSendspinDeviceStorageError.keychain(operation: .add, status: status)
        }
    }

    public func save(_ data: Data) async throws {
        let updateStatus = await adapter.update(query, data: data, accessibility: accessibility)
        guard updateStatus == errSecItemNotFound else {
            guard updateStatus == errSecSuccess else {
                throw KeychainSendspinDeviceStorageError.keychain(operation: .update, status: updateStatus)
            }
            return
        }

        let addStatus = await adapter.add(
            SendspinKeychainItem(query: query, data: data, accessibility: accessibility)
        )
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Another creator won between update and add. Retry the replacement so
            // save remains a durable replacement rather than a creation-race error.
            let retryStatus = await adapter.update(query, data: data, accessibility: accessibility)
            guard retryStatus == errSecSuccess else {
                throw KeychainSendspinDeviceStorageError.keychain(operation: .update, status: retryStatus)
            }
        default:
            throw KeychainSendspinDeviceStorageError.keychain(operation: .add, status: addStatus)
        }
    }

    public func delete() async throws {
        let status = await adapter.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSendspinDeviceStorageError.keychain(operation: .delete, status: status)
        }
    }

    private var query: SendspinKeychainItemQuery {
        SendspinKeychainItemQuery(service: service, account: account, accessGroup: accessGroup)
    }

    /// Internal injection point for deterministic tests and future platform-specific adapters.
    init(
        service: String,
        account: String,
        accessibility: KeychainStorageAccessibility = .afterFirstUnlockThisDeviceOnly,
        accessGroup: String? = nil,
        adapter: any SendspinKeychainItemAdapter
    ) throws {
        guard !service.isEmpty, !account.isEmpty, accessGroup.map({ !$0.isEmpty }) ?? true else {
            throw KeychainSendspinDeviceStorageError.invalidConfiguration
        }
        self.service = service
        self.account = account
        self.accessibility = accessibility
        self.accessGroup = accessGroup
        self.adapter = adapter
    }
}

struct SendspinKeychainItemQuery: Sendable, Equatable {
    let service: String
    let account: String
    let accessGroup: String?
}

struct SendspinKeychainItem: Sendable {
    let query: SendspinKeychainItemQuery
    let data: Data
    let accessibility: KeychainStorageAccessibility
}

protocol SendspinKeychainItemAdapter: Sendable {
    func copyMatching(_ query: SendspinKeychainItemQuery) async -> (status: OSStatus, data: Data?)
    func update(
        _ query: SendspinKeychainItemQuery,
        data: Data,
        accessibility: KeychainStorageAccessibility
    ) async -> OSStatus
    func add(_ item: SendspinKeychainItem) async -> OSStatus
    func delete(_ query: SendspinKeychainItemQuery) async -> OSStatus
}

private struct SystemSendspinKeychainItemAdapter: SendspinKeychainItemAdapter {
    func copyMatching(_ query: SendspinKeychainItemQuery) async -> (status: OSStatus, data: Data?) {
        var itemQuery = baseDictionary(for: query)
        itemQuery[kSecReturnData as String] = true
        itemQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(itemQuery as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(
        _ query: SendspinKeychainItemQuery,
        data: Data,
        accessibility: KeychainStorageAccessibility
    ) async -> OSStatus {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.keychainValue
        ]
        return SecItemUpdate(
            baseDictionary(for: query) as CFDictionary,
            attributes as CFDictionary
        )
    }

    func add(_ item: SendspinKeychainItem) async -> OSStatus {
        var attributes = baseDictionary(for: item.query)
        attributes[kSecValueData as String] = item.data
        attributes[kSecAttrAccessible as String] = item.accessibility.keychainValue
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ query: SendspinKeychainItemQuery) async -> OSStatus {
        SecItemDelete(baseDictionary(for: query) as CFDictionary)
    }

    private func baseDictionary(for query: SendspinKeychainItemQuery) -> [String: Any] {
        var dictionary: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: query.service,
            kSecAttrAccount as String: query.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let accessGroup = query.accessGroup {
            dictionary[kSecAttrAccessGroup as String] = accessGroup
        }
        return dictionary
    }
}
