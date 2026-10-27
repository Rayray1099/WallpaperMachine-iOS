import Foundation
#if canImport(Security)
import Security
#endif

/// Keeps the pixiv session between launches. Injected so tests never touch the keychain.
protocol PixivSessionStoring: Sendable {
    /// The saved session; nil when there is none or it cannot be read.
    func load() -> String?
    func save(_ session: String) throws
    func remove()
}

/// The session as a generic password in the app keychain. The iOS target uses the same service
/// and account values across releases so an update can read the session it previously saved.
struct KeychainPixivSessionStore: PixivSessionStoring {
    static let service = "app.wallpapermachine.pixiv"
    static let account = "session"

    #if canImport(Security)
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }
    #endif

    func load() -> String? {
        #if canImport(Security)
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data,
              let session = String(data: data, encoding: .utf8),
              PixivService.isSessionValue(session)
        else { return nil }
        return session
        #else
        return nil
        #endif
    }

    func save(_ session: String) throws {
        #if canImport(Security)
        let data = Data(session.utf8)
        var status = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary)
        if status != errSecSuccess {
            // Missing, or saved by a build this one may not change: start over.
            if status != errSecItemNotFound { SecItemDelete(query as CFDictionary) }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "WallpaperMachine pixiv sign-in"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw PixivServiceError(code: .notSaved)
        }
        #else
        _ = session
        throw PixivServiceError(code: .notSaved)
        #endif
    }

    func remove() {
        #if canImport(Security)
        _ = SecItemDelete(query as CFDictionary)
        #endif
    }
}
