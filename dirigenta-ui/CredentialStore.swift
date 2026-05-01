import Foundation

/// Abstraction over credential persistence so AppState can be tested without
/// touching the real Keychain. Production code injects `KeychainCredentialStore`
/// (which wraps `KeychainService`); tests inject `InMemoryCredentialStore`.
protocol CredentialStore: AnyObject {
    func get(_ key: String) throws -> String?
    func set(_ value: String, for key: String) throws
    func delete(_ key: String) throws
}

final class KeychainCredentialStore: CredentialStore {
    func get(_ key: String) throws -> String? { try KeychainService.get(key) }
    func set(_ value: String, for key: String) throws { try KeychainService.set(value, for: key) }
    func delete(_ key: String) throws { try KeychainService.delete(key) }
}

final class InMemoryCredentialStore: CredentialStore {
    private var items: [String: String] = [:]

    func get(_ key: String) throws -> String? { items[key] }
    func set(_ value: String, for key: String) throws { items[key] = value }
    func delete(_ key: String) throws { items.removeValue(forKey: key) }
}
