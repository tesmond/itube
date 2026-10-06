import Foundation
import Security

public protocol SecretStoring: Sendable {
    func read(account: String) -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String)
}

public struct KeychainError: Error, Equatable { public let status: OSStatus }

/// Generic-password Keychain item, device-only, unavailable until first unlock (ADR §51).
public struct KeychainStore: SecretStoring {
    private let service: String
    public init(service: String = "com.tesmond.itube.credentials") { self.service = service }

    private func baseQuery(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public func read(account: String) -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func write(_ data: Data, account: String) throws {
        delete(account: account)
        var q = baseQuery(account)
        q[kSecValueData] = data
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
