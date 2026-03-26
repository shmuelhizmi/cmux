import Foundation
#if canImport(Security)
import Security
#endif

/// Keychain-backed storage for the fly.io API token.
/// Falls back to the `FLY_API_TOKEN` environment variable.
enum FlyAuthTokenStore {
    private static let keychainService = "com.cmux.fly-api-token"
    private static let keychainAccount = "fly-api-token"

    /// Returns the fly.io API token, checking Keychain first, then environment.
    static func token() -> String? {
        if let stored = loadFromKeychain() {
            return stored
        }
        if let env = ProcessInfo.processInfo.environment["FLY_API_TOKEN"], !env.isEmpty {
            return env
        }
        return nil
    }

    /// Stores the token in the macOS Keychain.
    @discardableResult
    static func setToken(_ token: String) -> Bool {
        #if canImport(Security)
        deleteFromKeychain()
        guard let data = token.data(using: .utf8) else { return false }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecValueData: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
        #else
        return false
        #endif
    }

    /// Removes the token from the Keychain.
    @discardableResult
    static func clearToken() -> Bool {
        deleteFromKeychain()
    }

    // MARK: - Private

    private static func loadFromKeychain() -> String? {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    @discardableResult
    private static func deleteFromKeychain() -> Bool {
        #if canImport(Security)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #else
        return false
        #endif
    }
}
