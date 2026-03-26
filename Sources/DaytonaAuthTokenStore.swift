import Foundation
#if canImport(Security)
import Security
#endif

/// Keychain-backed storage for the Daytona API key.
/// Falls back to the `DAYTONA_API_KEY` environment variable.
enum DaytonaAuthTokenStore {
    private static let keychainService = "cmux"
    private static let keychainAccount = "Daytona API Key"

    /// In-process cache so we only hit the Keychain once per app launch.
    private static var cachedToken: String?
    private static var cacheLoaded = false

    /// Returns the Daytona API key, checking cache, Keychain, then environment.
    static func token() -> String? {
        if cacheLoaded, let cached = cachedToken {
            return cached
        }
        if let stored = loadFromKeychain() {
            cachedToken = stored
            cacheLoaded = true
            return stored
        }
        if let env = ProcessInfo.processInfo.environment["DAYTONA_API_KEY"], !env.isEmpty {
            cachedToken = env
            cacheLoaded = true
            return env
        }
        cacheLoaded = true
        return nil
    }

    /// Stores the API key in the macOS Keychain.
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
        if status == errSecSuccess {
            cachedToken = token
            cacheLoaded = true
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// Removes the API key from the Keychain.
    @discardableResult
    static func clearToken() -> Bool {
        cachedToken = nil
        cacheLoaded = false
        return deleteFromKeychain()
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
