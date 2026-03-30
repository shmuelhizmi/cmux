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

    /// Returns the Daytona API key, checking cache, file/Keychain, then environment.
    static func token() -> String? {
        if cacheLoaded, let cached = cachedToken {
            return cached
        }
        if let stored = loadToken() {
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

    /// Stores the API key.
    /// In DEBUG builds, writes to a plain file to avoid Keychain prompts.
    /// In release builds, uses the macOS Keychain.
    @discardableResult
    static func setToken(_ token: String) -> Bool {
#if DEBUG
        let success = saveToDebugFile(token)
        if success {
            cachedToken = token
            cacheLoaded = true
        }
        return success
#else
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
#endif
    }

    /// Removes the API key.
    @discardableResult
    static func clearToken() -> Bool {
        cachedToken = nil
        cacheLoaded = false
#if DEBUG
        return deleteDebugFile()
#else
        return deleteFromKeychain()
#endif
    }

    // MARK: - Private

    private static func loadToken() -> String? {
#if DEBUG
        return loadFromDebugFile()
#else
        return loadFromKeychain()
#endif
    }

    // MARK: - Debug File Storage

#if DEBUG
    private static var debugTokenFilePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("cmux/debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("daytona-api-key").path
    }

    private static func loadFromDebugFile() -> String? {
        guard let data = FileManager.default.contents(atPath: debugTokenFilePath),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func saveToDebugFile(_ token: String) -> Bool {
        let path = debugTokenFilePath
        return FileManager.default.createFile(atPath: path, contents: Data(token.utf8))
    }

    @discardableResult
    private static func deleteDebugFile() -> Bool {
        try? FileManager.default.removeItem(atPath: debugTokenFilePath)
        return true
    }
#endif

    // MARK: - Keychain

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
