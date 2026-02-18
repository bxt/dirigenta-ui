import Foundation
import Security

enum KeychainService {
    private static let service = Bundle.main.bundleIdentifier ?? "DefaultService"

    static func set(_ value: String, for key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw NSError(domain: "KeychainServiceError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert string to data"])
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw NSError(domain: "KeychainServiceError", code: Int(updateStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to update item in keychain"])
            }
        case errSecItemNotFound:
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: "KeychainServiceError", code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to add item to keychain"])
            }
        default:
            throw NSError(domain: "KeychainServiceError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to access keychain"])
        }
    }

    static func get(_ key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "KeychainServiceError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert data to string"])
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw NSError(domain: "KeychainServiceError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to retrieve item from keychain"])
        }
    }

    static func delete(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw NSError(domain: "KeychainServiceError", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to delete item from keychain"])
        }
    }
}
