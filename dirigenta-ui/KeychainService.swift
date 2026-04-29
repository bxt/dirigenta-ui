import Foundation
import Security

enum KeychainService {
    private static let service: String = {
        guard let id = Bundle.main.bundleIdentifier else {
            preconditionFailure("Bundle identifier is missing — cannot scope Keychain items safely")
        }
        return id
    }()

    enum KeychainError: LocalizedError {
        case encodingFailed
        case decodingFailed
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encodingFailed: return "Failed to encode value for Keychain"
            case .decodingFailed: return "Failed to decode value from Keychain"
            case .unexpectedStatus(let s):
                return "Keychain error (OSStatus \(s))"
            }
        }
    }

    private static func makeQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    static func set(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let query = makeQuery(for: key)
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess:
            let attrs: [String: Any] = [kSecValueData as String: data]
            let s = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard s == errSecSuccess else {
                throw KeychainError.unexpectedStatus(s)
            }
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlock
            let s = SecItemAdd(item as CFDictionary, nil)
            guard s == errSecSuccess else {
                throw KeychainError.unexpectedStatus(s)
            }
        case let s:
            throw KeychainError.unexpectedStatus(s)
        }
    }

    static func get(_ key: String) throws -> String? {
        var query = makeQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data,
                let string = String(data: data, encoding: .utf8)
            else {
                throw KeychainError.decodingFailed
            }
            return string
        case errSecItemNotFound:
            return nil
        case let s:
            throw KeychainError.unexpectedStatus(s)
        }
    }

    static func delete(_ key: String) throws {
        switch SecItemDelete(makeQuery(for: key) as CFDictionary) {
        case errSecSuccess, errSecItemNotFound: return
        case let s: throw KeychainError.unexpectedStatus(s)
        }
    }
}
