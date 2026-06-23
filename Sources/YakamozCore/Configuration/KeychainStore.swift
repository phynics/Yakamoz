import Foundation
import Security

/// Abstraction over secret storage, so production code can use the Keychain while tests use
/// an in-memory fake. API keys must only ever flow through this protocol — never `UserDefaults`.
public protocol SecretStoring: Sendable {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

/// Wraps a non-zero `OSStatus` returned by a Keychain Services call.
public struct KeychainError: Error, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var message: String {
        if let cfMessage = SecCopyErrorMessageString(status, nil) {
            return cfMessage as String
        }
        return "Keychain operation failed with status \(status)"
    }
}

/// `SecretStoring` backed by the macOS Keychain, scoped to a single service identifier.
public struct KeychainStore: SecretStoring {
    public static let defaultService = "com.atakandulker.Yakamoz"

    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        var updateAttributes = baseQuery
        // SecItemUpdate takes the match query separately from the attributes to set.
        let existing = try read(account: account)

        if existing != nil {
            let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(updateAttributes as CFDictionary, attributesToUpdate as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainError(status: status)
            }
        } else {
            updateAttributes[kSecValueData as String] = data
            let status = SecItemAdd(updateAttributes as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError(status: status)
            }
        }
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
