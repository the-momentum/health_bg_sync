import Foundation
import Security

/// Secure storage for credentials using iOS Keychain
internal class HealthBgSyncKeychain {
    
    private static let service = "com.healthbgsync.tokens"
    private static let defaults = UserDefaults(suiteName: "com.healthbgsync.config") ?? .standard
    
    // MARK: - Keys
    private static let accessTokenKey = "accessToken"
    private static let userIdKey = "userId"
    private static let customSyncUrlKey = "customSyncUrl"
    private static let syncActiveKey = "syncActive"
    private static let trackedTypesKey = "trackedTypes"
    private static let appInstalledKey = "appInstalled"
    
    // MARK: - Fresh Install Detection
    
    /// Call this on app launch to clear Keychain if app was reinstalled.
    /// UserDefaults is cleared on uninstall, but Keychain persists.
    /// If UserDefaults flag is missing but Keychain has data → app was reinstalled.
    static func clearKeychainIfReinstalled() {
        let wasInstalled = defaults.bool(forKey: appInstalledKey)
        
        if !wasInstalled {
            // First launch after install (or reinstall)
            // Clear any stale Keychain data from previous install
            if hasSession() {
                print("🔄 App reinstalled - clearing stale Keychain data")
                clearAll()
            }
            
            // Mark as installed
            defaults.set(true, forKey: appInstalledKey)
            defaults.synchronize()
        }
    }
    
    // MARK: - Save Credentials
    
    static func saveCredentials(userId: String, accessToken: String) {
        save(key: userIdKey, value: userId)
        save(key: accessTokenKey, value: accessToken)
    }
    
    // MARK: - Load Credentials
    
    static func getAccessToken() -> String? {
        return load(key: accessTokenKey)
    }
    
    static func getUserId() -> String? {
        return load(key: userIdKey)
    }
    
    static func hasSession() -> Bool {
        return getAccessToken() != nil && getUserId() != nil
    }
    
    // MARK: - Custom Sync URL (stored in UserDefaults, not sensitive)
    
    static func saveCustomSyncUrl(_ url: String?) {
        if let url = url {
            defaults.set(url, forKey: customSyncUrlKey)
        } else {
            defaults.removeObject(forKey: customSyncUrlKey)
        }
        defaults.synchronize()
    }
    
    static func getCustomSyncUrl() -> String? {
        return defaults.string(forKey: customSyncUrlKey)
    }
    
    // MARK: - Sync Active State
    
    static func setSyncActive(_ active: Bool) {
        defaults.set(active, forKey: syncActiveKey)
        defaults.synchronize()
    }
    
    static func isSyncActive() -> Bool {
        return defaults.bool(forKey: syncActiveKey)
    }
    
    // MARK: - Tracked Types
    
    static func saveTrackedTypes(_ types: [String]) {
        defaults.set(types, forKey: trackedTypesKey)
        defaults.synchronize()
    }
    
    static func getTrackedTypes() -> [String]? {
        return defaults.stringArray(forKey: trackedTypesKey)
    }
    
    // MARK: - Clear
    
    static func clearAll() {
        delete(key: accessTokenKey)
        delete(key: userIdKey)
        defaults.removeObject(forKey: customSyncUrlKey)
        defaults.removeObject(forKey: syncActiveKey)
        defaults.removeObject(forKey: trackedTypesKey)
        defaults.synchronize()
    }
    
    // MARK: - Private Keychain Operations
    
    private static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        
        // Delete existing item first
        delete(key: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Keychain save failed for \(key): \(status)")
        }
    }
    
    private static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
    
    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}
