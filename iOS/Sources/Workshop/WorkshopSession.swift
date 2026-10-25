import Foundation

/// A signed-in Steam Community session. It is sent to steamcommunity.com alone, to read the
/// account's subscriptions; its renewal token goes to Steam's token service alone.
struct SteamWebSession: Equatable, Sendable {
    /// The account's SteamID64, which the cookie starts with.
    let steamID: String
    /// The `steamLoginSecure` cookie's value, exactly as Steam set it.
    let cookie: String
    /// The token in Steam's `steamRefresh_steam` cookie, which Steam trades for a new
    /// `steamLoginSecure` for months after the sign-in; nil when the page set none.
    let refreshToken: String?
    /// When the cookie's own token runs out, as the token says; nil when it does not say.
    let expiresAt: Date?

    /// Reads a `steamLoginSecure` value, `<SteamID64>||<token>` with the bars percent-encoded
    /// or not. `refresh` is the `steamRefresh_steam` value in the same form; one of another
    /// account, or of any other shape, is left out.
    init?(cookie value: String, refresh: String? = nil) {
        guard let (id, token) = Self.parts(of: value) else { return nil }
        steamID = id
        cookie = value
        expiresAt = Self.expiry(of: token)
        refreshToken = refresh.flatMap(Self.parts(of:)).flatMap { $0.0 == id ? $0.1 : nil }
    }

    /// The same session with the cookie Steam's token service made from `accessToken`.
    func renewed(accessToken: String) -> SteamWebSession? {
        guard let fresh = SteamWebSession(cookie: "\(steamID)%7C%7C\(accessToken)") else {
            return nil
        }
        return SteamWebSession(
            steamID: steamID, cookie: fresh.cookie, refreshToken: refreshToken,
            expiresAt: fresh.expiresAt)
    }

    /// Whether the cookie has run out, or will within `margin`, and can be renewed.
    func needsRenewal(at now: Date, margin: TimeInterval = 120) -> Bool {
        guard refreshToken != nil, let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < margin
    }

    private init(steamID: String, cookie: String, refreshToken: String?, expiresAt: Date?) {
        self.steamID = steamID
        self.cookie = cookie
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// The SteamID64 and token of `<SteamID64>||<token>`.
    private static func parts(of value: String) -> (String, String)? {
        let decoded = value.replacingOccurrences(
            of: "%7C", with: "|", options: .caseInsensitive)
        let parts = decoded.components(separatedBy: "||")
        guard parts.count == 2, let id = parts.first, Self.isSteamID(id),
              let token = parts.last, token.count >= 16, value.count <= 4_096,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
        else { return nil }
        return (id, token)
    }

    /// The `exp` of a JSON Web Token, read without checking its signature: it only decides
    /// when to ask Steam for a new one, and Steam checks the token itself.
    static func expiry(of token: String) -> Date? {
        let sections = token.split(separator: ".", omittingEmptySubsequences: false)
        guard sections.count == 3 else { return nil }
        var payload = sections[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (claims["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// Whether `id` has the form of a SteamID64: 17 ASCII digits.
    static func isSteamID(_ id: String) -> Bool {
        id.count == 17 && id.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Keeps the Steam Community session between launches. Injected so tests never touch the
/// keychain.
protocol WorkshopSteamSessionStoring: Sendable {
    func load() -> SteamWebSession?
    func save(_ session: SteamWebSession) throws
    func remove()
}

/// An in-memory store for previews and tests. It never persists, so a test cannot leak a
/// session into the next launch.
final class WorkshopMemorySteamSessionStore: WorkshopSteamSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: SteamWebSession?

    init(session: SteamWebSession? = nil) { self.session = session }

    func load() -> SteamWebSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    func save(_ session: SteamWebSession) throws {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        session = nil
    }
}
