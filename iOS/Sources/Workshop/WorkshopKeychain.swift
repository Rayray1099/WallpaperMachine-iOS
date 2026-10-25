import Foundation
import Security

/// The keychain refused the item.
struct WorkshopKeychainError: Error {
    let status: OSStatus
}

/// The Steam Community session as a generic password in this device's keychain. The item is
/// this-device-only and is not synchronised to iCloud. The Workshop never logs the cookie or
/// the refresh token; only the OSStatus of a failed keychain operation.
struct KeychainWorkshopSteamSessionStore: WorkshopSteamSessionStoring {
    static let service = "com.rayray1099.wallpapermachine.ios.steam-community"
    static let account = "session"

    /// What is saved: the two cookie values, as Steam set them.
    private struct Saved: Codable {
        var cookie: String
        var refresh: String?
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func load() -> SteamWebSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                WorkshopLog.warn("Steam sign-in could not be read from the keychain (\(status))")
            }
            return nil
        }
        guard let data = item as? Data,
              let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return nil }
        return SteamWebSession(cookie: saved.cookie, refresh: saved.refresh)
    }

    func save(_ session: SteamWebSession) throws {
        let saved = Saved(
            cookie: session.cookie,
            refresh: session.refreshToken.map { "\(session.steamID)%7C%7C\($0)" })
        let data = try JSONEncoder().encode(saved)
        var status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecSuccess {
            // Missing, or saved by a build this one may not change: start over.
            if status != errSecItemNotFound { SecItemDelete(query as CFDictionary) }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "WallpaperMachine iOS Steam Community sign-in"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            WorkshopLog.warn("Steam sign-in could not be saved in the keychain (\(status))")
            throw WorkshopKeychainError(status: status)
        }
    }

    func remove() {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            WorkshopLog.warn("Steam sign-in could not be removed from the keychain (\(status))")
        }
    }
}
