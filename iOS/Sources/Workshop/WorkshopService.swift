import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Steam's public Workshop endpoints and page shapes, ported from the macOS app.
///
/// This service is actor-isolated and touches the network only. It never accepts a URL from
/// a person for a download, never follows a redirect with a Steam session cookie attached
/// outside steamcommunity.com, and never logs a response body, a cookie or a token.
actor WorkshopService {
    /// Steam's public browse page clamps `numperpage` to 30 and `total_pages` to 1,000.
    static let pageSize = WorkshopApp.pageSize
    static let maxPages = WorkshopApp.maxPages
    /// Steam's public details endpoint answers up to this many items per request without a key.
    static let detailsBatchSize = 100
    /// How many wallpapers of a collection are sampled while an age rating is hidden.
    static let collectionSample = 3

    private let session: URLSession
    private let busyRetryDelays: [TimeInterval]

    init(session: URLSession? = nil, busyRetryDelays: [TimeInterval] = [1, 3]) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 35
            configuration.timeoutIntervalForResource = 70
            configuration.httpMaximumConnectionsPerHost = 6
            self.session = URLSession(configuration: configuration)
        }
        self.busyRetryDelays = busyRetryDelays
    }

    // MARK: Browse

    static func browseURL(
        search: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, tags: [String] = [],
        excludedTags: [String] = [], section: String = "readytouseitems"
    ) -> URL {
        var items: [(String, String)] = [
            ("appid", String(WorkshopApp.id)),
            ("section", section),
            ("browsesort", sort.browseSort),
            ("searchtext", search),
            ("p", String(max(1, page))),
            ("numperpage", String(pageSize)),
            ("days", String(sort.days)),
            ("l", "english"),
        ]
        var required: [String] = []
        if let tag = kind.steamTag { required.append(tag) }
        for tag in tags where !required.contains(tag) { required.append(tag) }
        items += required.map { ("requiredtags[]", $0) }
        var excluded: [String] = []
        for tag in excludedTags where !required.contains(tag) && !excluded.contains(tag) {
            excluded.append(tag)
        }
        items += excluded.map { ("excludedtags[]", $0) }

        // Every value is escaped down to unreserved characters: `URLComponents` leaves `+`,
        // which Steam reads as a space, and a search such as "rain & snow" must stay one
        // parameter.
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var components = URLComponents()
        components.scheme = "https"
        components.host = "steamcommunity.com"
        components.path = "/workshop/browse/"
        components.percentEncodedQuery = items.map { name, value in
            (name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name) + "="
                + (value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
        }.joined(separator: "&")
        return components.url!
    }

    func browse(
        search: String, kind: WorkshopKind, sort: WorkshopSort, page: Int, tags: [String] = [],
        excludedTags: [String] = []
    ) async throws -> WorkshopPage {
        let url = Self.browseURL(
            search: search, kind: kind, sort: sort, page: page, tags: tags, excludedTags: excludedTags)
        let (html, decoded) = try await browsePage(url) { html -> (String, WorkshopPage?) in
            do { return (html, try Self.decodePage(html)) }
            catch WorkshopFailure.layoutChanged { return (html, nil) }
        }
        if let decoded { return decoded }
        return try await degradedPage(html: html, page: page, original: .layoutChanged)
    }

    /// A browse page, decoded. While Steam answers it busy the page is requested again after
    /// each delay; after the last, `WorkshopFailure.busy` stands.
    private func browsePage<T>(
        _ url: URL, decode: (String) throws -> T
    ) async throws -> T {
        var delayIndex = 0
        while true {
            let html = try await communityPage(url)
            do {
                return try decode(html)
            } catch WorkshopFailure.busy where delayIndex < busyRetryDelays.count {
                let delay = busyRetryDelays[delayIndex]
                delayIndex += 1
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// A browse page whose markup this app no longer reads, shown from the item links it still
    /// carries. With no item found the original failure stands, so an unreadable page never
    /// passes for an empty list.
    private func degradedPage(
        html: String, page: Int, original: WorkshopFailure
    ) async throws -> WorkshopPage {
        let ids = Self.itemIDs(in: html, limit: Self.pageSize)
        guard !ids.isEmpty else { throw original }
        let served = Dictionary(
            try await details(ids: ids).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = ids.compactMap { served[$0] }
        guard !items.isEmpty else { throw original }
        WorkshopLog.warn("Steam's Workshop page was read from its item links only")
        let number = max(1, page)
        return WorkshopPage(
            items: items, page: number,
            totalPages: ids.count >= Self.pageSize ? number + 1 : number,
            totalCount: (number - 1) * Self.pageSize + items.count, isDegraded: true)
    }

    /// A Steam Community page as text. `account` adds its session cookie, and only ever to a
    /// steamcommunity.com address.
    private func communityPage(_ url: URL, account: SteamWebSession? = nil) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        request.setValue(
            "WallpaperMachine/1.0 (iOS; public Workshop browser)", forHTTPHeaderField: "User-Agent")
        var redirects: SteamCookieRedirectGuard?
        if let account, Self.mayCarrySession(url) {
            request.httpShouldHandleCookies = false
            request.setValue("steamLoginSecure=\(account.cookie)", forHTTPHeaderField: "Cookie")
            redirects = SteamCookieRedirectGuard()
        }
        let (data, http) = try await response(for: request, redirects: redirects)
        try Task.checkCancellation()
        try Self.throwForStatus(http.statusCode)
        guard data.count < 12_000_000, let html = String(data: data, encoding: .utf8) else {
            throw WorkshopFailure.unreadablePage
        }
        return html
    }

    /// The Steam session cookie goes to steamcommunity.com over HTTPS and nowhere else.
    static func mayCarrySession(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "steamcommunity.com" && url.port == nil
            && url.user == nil
    }

    /// A redirect keeps the session cookie only while it stays where `mayCarrySession` allows.
    static func redirected(_ request: URLRequest) -> URLRequest {
        var request = request
        if !mayCarrySession(request.url) { request.setValue(nil, forHTTPHeaderField: "Cookie") }
        return request
    }

    /// Where Steam trades a session's renewal token for a new `steamLoginSecure` token.
    static let renewalURL = URL(
        string: "https://api.steampowered.com/IAuthenticationService/GenerateAccessTokenForApp/v1/")!

    /// Renews a Steam Community session. The refresh token goes to Steam's token service alone,
    /// in a body that follows no redirect. Steam refusing it throws `signInRequired`.
    func renew(_ account: SteamWebSession) async throws -> SteamWebSession {
        guard let refreshToken = account.refreshToken else { throw WorkshopFailure.signInRequired }
        var request = URLRequest(url: Self.renewalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "steamid", value: account.steamID),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, http) = try await response(for: request, redirects: SteamNoRedirects())
        if http.statusCode == 401 || http.statusCode == 403 {
            throw WorkshopFailure.signInRequired
        }
        try Self.throwForStatus(http.statusCode)
        // Steam answers a refused token with an empty response and the reason in a header.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = root["response"] as? [String: Any],
              let token = body["access_token"] as? String,
              let renewed = account.renewed(accessToken: token)
        else { throw WorkshopFailure.signInRequired }
        return renewed
    }

    // MARK: Details

    /// Current details of Workshop items, in the order Steam answers, without those Steam no
    /// longer serves (removed, hidden, or not Wallpaper Engine's).
    func details(ids: [String]) async throws -> [WorkshopItem] {
        let numeric = ids.filter(WorkshopParsing.isWorkshopID)
        guard !numeric.isEmpty else { return [] }
        var items: [WorkshopItem] = []
        var start = 0
        while start < numeric.count {
            try Task.checkCancellation()
            let batch = Array(numeric[start..<min(numeric.count, start + Self.detailsBatchSize)])
            start += batch.count
            let (data, http) = try await response(for: Self.detailsRequest(ids: batch))
            try Self.throwForStatus(http.statusCode)
            items += try Self.decodeDetails(data)
        }
        return items
    }

    static func detailsRequest(ids: [String]) -> URLRequest {
        var request = URLRequest(
            url: URL(string:
                "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "WallpaperMachine/1.0 (iOS; public Workshop browser)", forHTTPHeaderField: "User-Agent")
        let numeric = ids.filter(WorkshopParsing.isWorkshopID)
        var fields = ["itemcount=\(numeric.count)"]
        for (index, id) in numeric.enumerated() {
            fields.append("publishedfileids[\(index)]=\(id)")
        }
        request.httpBody = Data(fields.joined(separator: "&").utf8)
        return request
    }

    static func decodeDetails(_ data: Data) throws -> [WorkshopItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let rows = response["publishedfiledetails"] as? [[String: Any]]
        else { throw WorkshopFailure.unreadableDetails }
        return rows.compactMap(WorkshopParsing.item(details:))
    }

    /// The one tile for a Workshop item named by a pasted link or id, as a page of one.
    func itemPage(id: String) async throws -> WorkshopPage {
        guard WorkshopParsing.isWorkshopID(id) else { throw WorkshopFailure.itemUnavailable }
        let (data, http) = try await response(for: Self.detailsRequest(ids: [id]))
        try Self.throwForStatus(http.statusCode)
        let item = try Self.lookup(details: data, id: id)
        return WorkshopPage(items: [item], page: 1, totalPages: 1, totalCount: 1)
    }

    /// The item `id` from a details answer, or why it cannot be shown as a tile.
    static func lookup(details data: Data, id: String) throws -> WorkshopItem {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let rows = response["publishedfiledetails"] as? [[String: Any]]
        else { throw WorkshopFailure.unreadableDetails }
        guard let row = rows.first(where: { ($0["publishedfileid"] as? String) == id }),
              (row["result"] as? Int) == 1
        else { throw WorkshopFailure.itemUnavailable }
        guard WorkshopParsing.integer(row["consumer_app_id"]) == WorkshopApp.id else {
            throw WorkshopFailure.notWallpaperEngine
        }
        guard let item = WorkshopParsing.item(details: row) else {
            throw WorkshopFailure.unreadableDetails
        }
        guard !item.isApplication else { throw WorkshopFailure.applicationUnsupported }
        return item
    }

    // MARK: Sources other than the browse page

    /// One page of `query`'s source. Steam filters and sorts the browse and collections pages
    /// itself; the other sources are listed in their own order and filtered here with the
    /// same rules, so a page can hold fewer than `pageSize` tiles.
    func page(for query: WorkshopQuery, page: Int, account: SteamWebSession?) async throws
        -> WorkshopPage
    {
        switch query.source {
        case .browse:
            if let id = query.itemID { return try await itemPage(id: id) }
            return try await browse(
                search: query.text, kind: query.kind, sort: query.sort, page: page,
                tags: query.tags, excludedTags: query.excludedTags)
        case .collections:
            return try await collections(
                search: query.text, sort: query.sort, page: page, tags: query.tags,
                excludedTags: query.excludedTags)
        case .collection(let id, _):
            return try await collectionPage(
                id: id, page: page, tags: query.tags, excludedTags: query.excludedTags)
        case .creator(let id, let name):
            var listing = try await profilePage(
                steamID: id, subscriptions: false, account: nil, page: page)
            let author = listing.page.title ?? name
            listing.page = Self.matching(
                listing.page, tags: query.tags, excludedTags: query.excludedTags)
            listing.page.title = author
            return listing.page
        case .subscriptions:
            guard let account else { throw WorkshopFailure.signInRequired }
            var listing = try await profilePage(
                steamID: account.steamID, subscriptions: true, account: account, page: page)
            listing.page = Self.matching(
                listing.page, tags: query.tags, excludedTags: query.excludedTags)
            return listing.page
        }
    }

    private static let ratingTags: Set<String> = ["questionable", "mature"]

    /// Whether the sidebar hides an age rating, which Steam cannot apply to a collection, so
    /// collections are screened here and a page of them can come back with gaps.
    static func screensRatings(tags: [String], excludedTags: [String]) -> Bool {
        !hiddenTags(tags: tags, excludedTags: excludedTags).isDisjoint(with: ratingTags)
    }

    /// The excluded tags, lowercased, less any that are also required, as on Steam.
    private static func hiddenTags(tags: [String], excludedTags: [String]) -> Set<String> {
        Set(excludedTags.map { $0.lowercased() }).subtracting(tags.map { $0.lowercased() })
    }

    /// Collections, as Steam's browse page lists them. While Questionable or Mature is hidden, a
    /// collection is shown only when neither its own tags nor its first few wallpapers carry a
    /// hidden tag, and it has a wallpaper to look at.
    func collections(
        search: String, sort: WorkshopSort, page: Int, tags: [String], excludedTags: [String]
    ) async throws -> WorkshopPage {
        var (listing, children) = try await browsePage(Self.browseURL(
            search: search, kind: .all, sort: sort, page: page, tags: tags,
            excludedTags: excludedTags, section: "collections"), decode: Self.decodeBrowse)
        guard Self.screensRatings(tags: tags, excludedTags: excludedTags) else { return listing }
        let excluded = Self.hiddenTags(tags: tags, excludedTags: excludedTags)
        var samples: [String: [String]] = [:]
        for collection in listing.items {
            samples[collection.id] = Array(
                (children[collection.id] ?? []).prefix(Self.collectionSample))
        }
        let sampled = try await details(ids: Array(Set(samples.values.flatMap { $0 })).sorted())
        let byID = Dictionary(
            sampled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        listing.items = listing.items.filter { collection in
            let wallpapers = (samples[collection.id] ?? []).compactMap { byID[$0] }
            return !Self.carries(collection.tags, anyOf: excluded) && !wallpapers.isEmpty
                && !wallpapers.contains { Self.carries($0.tags, anyOf: excluded) }
        }
        return listing
    }

    /// The items of one collection, a page at a time, in the collection's own order. A
    /// collection inside it is shown as a collection unless an age rating is hidden, when
    /// there is nothing to vouch for what it holds.
    func collectionPage(
        id: String, page: Int, tags: [String], excludedTags: [String]
    ) async throws -> WorkshopPage {
        guard WorkshopParsing.isWorkshopID(id) else {
            throw WorkshopFailure.collectionUnavailable
        }
        let (data, http) = try await response(for: Self.collectionRequest(id: id))
        try Self.throwForStatus(http.statusCode)
        let children = try Self.decodeCollection(data)
        let totalPages = max(1, (children.count + Self.pageSize - 1) / Self.pageSize)
        let number = min(max(1, page), totalPages)
        let slice = Array(children.dropFirst((number - 1) * Self.pageSize).prefix(Self.pageSize))
        let items = try await details(ids: slice)
        return Self.matching(
            WorkshopPage(items: items, page: number, totalPages: totalPages, totalCount: children.count),
            tags: tags, excludedTags: excludedTags)
    }

    static func collectionRequest(id: String) -> URLRequest {
        var request = URLRequest(
            url: URL(string:
                "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "WallpaperMachine/1.0 (iOS; public Workshop browser)", forHTTPHeaderField: "User-Agent")
        let numeric = WorkshopParsing.isWorkshopID(id) ? id : "0"
        request.httpBody = Data("collectioncount=1&publishedfileids[0]=\(numeric)".utf8)
        return request
    }

    static func decodeCollection(_ data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let collection = (response["collectiondetails"] as? [[String: Any]])?.first
        else { throw WorkshopFailure.unreadableDetails }
        guard (collection["result"] as? Int) == 1 else {
            throw WorkshopFailure.collectionUnavailable
        }
        return (collection["children"] as? [[String: Any]] ?? [])
            .sorted {
                WorkshopParsing.integer($0["sortorder"]) ?? 0
                    < WorkshopParsing.integer($1["sortorder"]) ?? 0
            }
            .compactMap { $0["publishedfileid"] as? String }
    }

    static func profileURL(steamID: String, subscriptions: Bool, page: Int) -> URL {
        var url = URLComponents(
            string: "https://steamcommunity.com/profiles/\(steamID)/myworkshopfiles/")!
        url.queryItems = [
            URLQueryItem(name: "appid", value: String(WorkshopApp.id)),
            URLQueryItem(name: "p", value: String(max(1, page))),
            URLQueryItem(name: "numperpage", value: String(Self.pageSize)),
            URLQueryItem(name: "l", value: "english"),
        ]
        if subscriptions {
            url.queryItems?.append(URLQueryItem(name: "browsefilter", value: "mysubscriptions"))
        }
        return url.url!
    }

    /// One page of an account's Workshop items, or of its subscriptions, with the account's
    /// name when Steam put one in the page title.
    func profilePage(
        steamID: String, subscriptions: Bool, account: SteamWebSession?, page: Int
    ) async throws -> (page: WorkshopPage, name: String?) {
        guard SteamWebSession.isSteamID(steamID) else {
            throw WorkshopFailure.invalidSteamID
        }
        let html = try await communityPage(
            Self.profileURL(steamID: steamID, subscriptions: subscriptions, page: page),
            account: account)
        let listing = try Self.decodeProfileListing(html)
        let items = try await details(ids: listing.ids)
        let totalPages = max(1, (listing.total + Self.pageSize - 1) / Self.pageSize)
        return (
            WorkshopPage(
                items: items, page: max(1, page), totalPages: min(totalPages, Self.maxPages),
                totalCount: listing.total, title: listing.name),
            listing.name)
    }

    /// Every id the account subscribes to, page by page, at most 1,000 pages.
    func subscribedIDs(account: SteamWebSession) async throws -> [String] {
        var ids: [String] = []
        var page = 1
        var pages = 1
        repeat {
            try Task.checkCancellation()
            let html = try await communityPage(
                Self.profileURL(steamID: account.steamID, subscriptions: true, page: page),
                account: account)
            let listing = try Self.decodeProfileListing(html)
            ids += listing.ids.filter { !ids.contains($0) }
            pages = min(Self.maxPages, max(1, (listing.total + Self.pageSize - 1) / Self.pageSize))
            if listing.ids.isEmpty { break }
            page += 1
        } while page <= pages
        return ids
    }

    /// The ids on a profile's Workshop items page, the number of entries in all, and the
    /// account's name. Steam's sign-in page instead means the session is gone.
    static func decodeProfileListing(_ html: String) throws
        -> (ids: [String], total: Int, name: String?)
    {
        var ids: [String] = []
        // An author's items are tiles carrying `data-publishedfileid`; subscriptions are rows,
        // `<div class="workshopItemSubscription " id="Subscription<id>">`, whose details and
        // Unsubscribe control are not always in the served page, so the row's own id names
        // the item.
        let idPattern = try NSRegularExpression(
            pattern:
                #"(?:data-publishedfileid="|id="(?:Subscription|UnsubscribeItemBtn)|UnsubscribeItem\(\s*')(\d+)["']"#)
        for match in idPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let id = String(html[range])
            guard WorkshopParsing.isWorkshopID(id), !ids.contains(id) else { continue }
            ids.append(id)
        }
        let title = (firstMatch(#"<title>([^<]*)</title>"#, in: html) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Every page links to the sign-in page in its header; only the page itself is titled so.
        if ids.isEmpty, title == "Sign In" { throw WorkshopFailure.signInRequired }
        let paging = #"Showing\s+([\d,]+)\s*-\s*[\d,]+\s+of\s+([\d,]+)\s+entries"#
        let number = { (group: Int) in
            firstMatch(paging, in: html, group: group)
                .flatMap { Int($0.replacingOccurrences(of: ",", with: "")) }
        }
        let total = number(2) ?? ids.count
        // Steam says the page holds entries yet none could be read: its markup has changed,
        // which must not pass for an empty list.
        if ids.isEmpty, total > 0, let first = number(1), first <= total {
            throw WorkshopFailure.unreadablePage
        }
        let name = firstMatch(#"^Steam Community :: (.+?)(?: :: [^:]*)?$"#, in: title)
            .map(unescapeHTML)
        return (ids, max(total, ids.count), name)
    }

    private static func firstMatch(
        _ pattern: String, in text: String, group: Int = 1
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Applies the sidebar's rules to a page Steam did not filter: every required tag must be
    /// on an item and none of the excluded ones, compared without case. A collection inside it
    /// is dropped while an age rating is hidden, as nothing vouches for what it holds.
    static func matching(
        _ page: WorkshopPage, tags: [String], excludedTags: [String]
    ) -> WorkshopPage {
        let required = Set(tags.map { $0.lowercased() })
        let excluded = hiddenTags(tags: tags, excludedTags: excludedTags)
        let screening = screensRatings(tags: tags, excludedTags: excludedTags)
        var filtered = page
        filtered.items = page.items.filter { item in
            let own = Set(item.tags.map { $0.lowercased() })
            return required.isSubset(of: own) && own.isDisjoint(with: excluded)
                && !(screening && item.collectionSize != nil)
        }
        return filtered
    }

    private static func carries(_ tags: [String], anyOf excluded: Set<String>) -> Bool {
        tags.contains { excluded.contains($0.lowercased()) }
    }

    // MARK: Parsing browse pages

    /// The page's `renderContext`, served either as `{"renderContext": …}` in a
    /// `<script type="application/json" id="valve-ssr-data">` block or, on older pages, as a
    /// JSON string literal passed to `JSON.parse` for `window.SSR.renderContext`.
    static func renderContext(in html: String) -> [String: Any]? {
        let bytes = Array(html.utf8)
        if let data = ssrDataBlock(in: bytes) {
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[
                "renderContext"] as? [String: Any]
        }
        guard let encoded = renderContextLiteral(in: bytes),
              let contextString = try? JSONSerialization.jsonObject(
                with: encoded, options: .fragmentsAllowed) as? String
        else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(contextString.utf8))
            as? [String: Any]
    }

    private static func ssrDataBlock(in bytes: [UInt8]) -> Data? {
        guard let marker = firstIndex(of: Array(#"id="valve-ssr-data""#.utf8), in: bytes, from: 0),
              let open = bytes[marker...].firstIndex(of: UInt8(ascii: ">")),
              let close = firstIndex(of: Array("</script".utf8), in: bytes, from: open + 1)
        else { return nil }
        return Data(bytes[(open + 1)..<close])
    }

    private static func renderContextLiteral(in bytes: [UInt8]) -> Data? {
        guard let marker = firstIndex(
            of: Array("window.SSR.renderContext".utf8), in: bytes, from: 0)
        else { return nil }
        var index = marker + "window.SSR.renderContext".utf8.count
        func skipSpaces() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }
        skipSpaces()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { return nil }
        index += 1
        skipSpaces()
        let call = Array("JSON.parse(".utf8)
        guard index + call.count <= bytes.count,
              Array(bytes[index..<index + call.count]) == call
        else { return nil }
        index += call.count
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
        let start = index
        index += 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"): index += 2
            case UInt8(ascii: "\""): return Data(bytes[start...index])
            default: index += 1
            }
        }
        return nil
    }

    /// How a browse page names an item: the link on its tile, the `publishedfileid` key of
    /// its row in the page's JSON (also in the escaped older form), and older tiles' attribute.
    private static let itemNeedles: [[UInt8]] = [
        "sharedfiles/filedetails/?id=",
        #""publishedfileid":""#,
        #"publishedfileid\":\""#,
        #"data-publishedfileid=""#,
    ].map { Array($0.utf8) }

    /// The ids of the Workshop items a browse page names, in the order they first appear, at
    /// most `limit`.
    static func itemIDs(in html: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let bytes = Array(html.utf8)
        var found: [(offset: Int, id: String)] = []
        for needle in itemNeedles {
            var named = Set<String>()
            var from = 0
            while named.count < limit, let at = firstIndex(of: needle, in: bytes, from: from) {
                from = at + needle.count
                if let id = itemID(in: bytes, at: from), named.insert(id).inserted {
                    found.append((at, id))
                }
            }
        }
        var unique = Set<String>()
        var ids: [String] = []
        for entry in found.sorted(by: { $0.offset < $1.offset })
        where unique.insert(entry.id).inserted {
            ids.append(entry.id)
            if ids.count == limit { break }
        }
        return ids
    }

    private static func itemID(in bytes: [UInt8], at start: Int) -> String? {
        var end = start
        while end < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[end]) {
            end += 1
        }
        guard (5...20).contains(end - start), bytes[start] != UInt8(ascii: "0") else { return nil }
        let id = String(decoding: bytes[start..<end], as: UTF8.self)
        return UInt64(id) == nil ? nil : id
    }

    private static func firstIndex(
        of needle: [UInt8], in haystack: [UInt8], from start: Int
    ) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0],
               haystack[index..<index + needle.count].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    static func decodePage(_ html: String) throws -> WorkshopPage {
        try decodeBrowse(html).page
    }

    /// A browse page and, for each collection on it, the ids of the wallpapers it holds (not
    /// the collections it holds), in the collection's order.
    static func decodeBrowse(_ html: String) throws
        -> (page: WorkshopPage, children: [String: [String]])
    {
        guard let context = renderContext(in: html),
              let queryData = context["queryData"] as? String,
              let decoded = try? JSONSerialization.jsonObject(with: Data(queryData.utf8))
                as? [String: Any],
              let queries = decoded["queries"] as? [[String: Any]]
        else { throw WorkshopFailure.layoutChanged }

        func key(_ query: [String: Any]) -> [String] {
            (query["queryKey"] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        func data(_ query: [String: Any]) -> [String: Any]? {
            (query["state"] as? [String: Any])?["data"] as? [String: Any]
        }
        guard let browse = queries.first(where: { key($0).first == "workshop_browse" }),
              let result = data(browse)
        else { throw WorkshopFailure.layoutChanged }
        let answer = WorkshopParsing.integer(result["eresult"])
        // 10 is Steam's search being overloaded; any other refusal keeps the page-changed
        // wording.
        if answer == 10 { throw WorkshopFailure.busy }
        guard answer == 1 else { throw WorkshopFailure.layoutChanged }
        guard let rows = result["results"] as? [[String: Any]] else {
            throw WorkshopFailure.layoutChanged
        }

        // Display names of the creators the page mentions, by Steam id.
        var names: [String: String] = [:]
        for query in queries {
            let parts = key(query)
            guard parts.count == 2, parts[0] == "PlayerLinkDetails",
                  let name = ((data(query)?["public_data"]) as? [String: Any])?[
                    "persona_name"] as? String,
                  !name.isEmpty
            else { continue }
            names[parts[1]] = name
        }
        // Current pages also put the tile creators' public data beside the results.
        for link in result["creator_player_link_details"] as? [[String: Any]] ?? [] {
            guard let publicData = link["public_data"] as? [String: Any],
                  let id = publicData["steamid"] as? String,
                  let name = publicData["persona_name"] as? String, !name.isEmpty
            else { continue }
            names[id] = name
        }

        func fileID(_ value: Any?) -> String? {
            if let text = value as? String {
                return WorkshopParsing.isWorkshopID(text) ? text : nil
            }
            if let number = value as? NSNumber, number.int64Value > 0 {
                return String(number.int64Value)
            }
            return nil
        }

        var seen = Set<String>()
        var items: [WorkshopItem] = []
        var children: [String: [String]] = [:]
        for row in rows {
            guard let id = fileID(row["publishedfileid"]),
                  WorkshopParsing.integer(row["consumer_appid"]) == WorkshopApp.id,
                  let title = row["title"] as? String, seen.insert(id).inserted
            else { continue }
            let preview = (row["preview_url"] as? String)
                .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let creatorID = row["creator"] as? String
            let updated = WorkshopParsing.number(row["time_updated"])
                .map(Date.init(timeIntervalSince1970:))
            let isCollection = WorkshopParsing.integer(row["file_type"]) == 2
            var item = WorkshopItem(
                id: id, title: title,
                creator: creatorID.flatMap { names[$0] }
                    ?? WS("Workshop creator", "工作坊創作者"),
                summary: WorkshopParsing.summary(row["short_description"] as? String ?? ""),
                previewURL: preview?.scheme == "https" ? preview : nil,
                tags: WorkshopItem.tags(from: row["tags"]),
                size: Int64(row["file_size"] as? String ?? "")
                    ?? WorkshopParsing.number(row["file_size"]).map(Int64.init) ?? 0,
                subscriptions: WorkshopParsing.integer(row["subscriptions"]) ?? 0,
                creatorID: creatorID,
                timeUpdated: updated)
            if isCollection {
                item.collectionSize = WorkshopParsing.integer(row["num_children"]) ?? 0
                let held = (row["children"] as? [[String: Any]] ?? [])
                    .filter { WorkshopParsing.integer($0["file_type"]) != 2 }
                    .compactMap { child -> (id: String, order: Int)? in
                        fileID(child["publishedfileid"]).map {
                            ($0, WorkshopParsing.integer(child["sortorder"]) ?? 0)
                        }
                    }
                children[id] = held.sorted { $0.order < $1.order }.map(\.id)
            }
            items.append(item)
        }
        let page = WorkshopPage(
            items: items, page: WorkshopParsing.integer(result["current_page"]) ?? 1,
            totalPages: max(1, WorkshopParsing.integer(result["total_pages"]) ?? 1),
            totalCount: WorkshopParsing.integer(result["total_count"]) ?? 0)
        return (page, children)
    }

    // MARK: Transport

    private func response(
        for request: URLRequest, redirects: URLSessionTaskDelegate? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request, delegate: redirects)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw WorkshopFailure.network(WS("No HTTP response.", "沒有 HTTP 回應。"))
            }
            return (data, http)
        } catch is CancellationError {
            throw WorkshopFailure.cancelled
        } catch let failure as WorkshopFailure {
            throw failure
        } catch let error as URLError where error.code == .cancelled {
            throw WorkshopFailure.cancelled
        } catch {
            throw WorkshopFailure.network(error.localizedDescription)
        }
    }

    private static func throwForStatus(_ status: Int) throws {
        if status == 429 { throw WorkshopFailure.rateLimited }
        guard (200..<300).contains(status) else { throw WorkshopFailure.httpStatus(status) }
    }
}

/// Strips the Steam session cookie from a redirect that leaves steamcommunity.com.
private final class SteamCookieRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(WorkshopService.redirected(request))
    }
}

/// Follows no redirect: the renewal token is for Steam's token service and nowhere else.
private final class SteamNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
