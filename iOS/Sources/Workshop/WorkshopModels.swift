import Foundation

/// Wallpaper Engine's Steam app id. Every Workshop request is scoped to it.
enum WorkshopApp {
    static let id = 431960
    static let collectionCreatorApp = 766
    static let pageSize = 30
    static let maxPages = 1_000
}

/// One Workshop item as Steam's public endpoints describe it.
struct WorkshopItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    var creator: String
    let summary: String
    let previewURL: URL?
    let tags: [String]
    let size: Int64
    let subscriptions: Int
    /// The author's SteamID64 when Steam said it; it opens the author's other items.
    var creatorID: String?
    /// When the author last changed the item on the Workshop.
    var timeUpdated: Date?
    /// Set when the item is a collection: how many wallpapers it holds, or 0 when unknown.
    /// A collection is opened, never downloaded.
    var collectionSize: Int?

    var kind: WorkshopKind {
        WorkshopKind.allCases.first { $0 != .all && tags.contains($0.rawValue) } ?? .all
    }

    var isCollection: Bool { collectionSize != nil }
    var isApplication: Bool { tags.contains(WorkshopKind.application.rawValue) }
    var pageURL: URL { Self.pageURL(id: id) }

    /// The item's page on Steam; `id` is digits only, checked by the callers that accept
    /// an id from a person or a URL.
    static func pageURL(id: String) -> URL {
        URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
    }

    /// The JSON value Steam uses for `tags` is a list of dictionaries; older answers use
    /// plain strings. Both are read the same way.
    static func tags(from value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap {
            ($0 as? [String: Any])?["tag"] as? String ?? $0 as? String
        }
    }

    /// Whether the item can produce a wallpaper at all on iPadOS. Scenes need the engine and
    /// Wallpaper Engine's licensed shared assets; videos depend on the codec; web wallpapers
    /// use the system web view. Application wallpapers execute Windows programs.
    var isPlayableOnIPad: Bool { kind != .application && !isCollection }

    enum CodingKeys: String, CodingKey {
        case id, title, creator, summary, previewURL, tags, size, subscriptions
        case creatorID, timeUpdated, collectionSize
    }
}

enum WorkshopKind: String, CaseIterable, Identifiable, Sendable {
    case all = "All types"
    case scene = "Scene"
    case video = "Video"
    case web = "Web"
    case application = "Application"

    var id: String { rawValue }

    /// The Steam tag value; `.all` is a control value and never sent as a tag.
    var steamTag: String? { self == .all ? nil : rawValue }

    var title: String {
        switch self {
        case .all: WS("All types", "所有類型")
        case .scene: WS("Scene", "場景")
        case .video: WS("Video", "影片")
        case .web: WS("Web", "網頁")
        case .application: WS("Application", "應用程式")
        }
    }

    var compatibility: String {
        switch self {
        case .scene:
            WS(
                "Scene · needs the scene engine and Wallpaper Engine’s shared assets",
                "場景 · 需要場景引擎與 Wallpaper Engine 共用素材")
        case .video:
            WS("Video · codec dependent", "影片 · 視編碼支援而定")
        case .web:
            WS("Web · runs in a built-in web view", "網頁 · 在內建網頁檢視中執行")
        case .application:
            WS(
                "Application · runs Windows programs and is unsupported on iPad",
                "應用程式 · 執行 Windows 程式，iPad 不支援")
        case .all:
            WS("Compatibility is checked after import", "匯入後再檢查相容性")
        }
    }
}

/// Sort orders Steam's public browse page honours. The raw value is the stable key shared
/// with the macOS app; `browseSort` and `days` are what the request sends.
enum WorkshopSort: String, CaseIterable, Identifiable, Sendable {
    case topRated = "toprated"
    case trendingToday = "trend-today"
    case trending = "trend"
    case trendingMonth = "trend-month"
    case trendingYear = "trend-year"
    case popular = "totaluniquesubscribers"
    case newest = "mostrecent"
    case updated = "lastupdated"
    case relevance = "textsearch"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topRated: WS("Highest rated", "最高評價")
        case .trendingToday: WS("Most popular today", "今日最熱門")
        case .trending: WS("Trending this week", "本週熱門")
        case .trendingMonth: WS("Most popular this month", "本月最熱門")
        case .trendingYear: WS("Most popular this year", "今年最熱門")
        case .popular: WS("Most subscribed", "最多訂閱")
        case .newest: WS("Newest", "最新")
        case .updated: WS("Recently updated", "最近更新")
        case .relevance: WS("Relevance", "相關度")
        }
    }

    var browseSort: String {
        switch self {
        case .trendingToday, .trending, .trendingMonth, .trendingYear: "trend"
        default: rawValue
        }
    }

    var days: Int {
        switch self {
        case .trendingToday: 1
        case .trendingMonth: 30
        case .trendingYear: 365
        default: 7
        }
    }
}

/// The three lists the Workshop tabs open. An author or a collection is opened from a
/// tile, so this type cannot name one.
enum WorkshopList: String, CaseIterable, Identifiable, Sendable {
    case wallpapers
    case collections
    case subscriptions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallpapers: WS("Wallpapers", "桌布")
        case .collections: WS("Collections", "合集")
        case .subscriptions: WS("Your subscriptions", "你的訂閱")
        }
    }

    var systemImage: String {
        switch self {
        case .wallpapers: "photo.on.rectangle"
        case .collections: "square.stack"
        case .subscriptions: "bookmark"
        }
    }

    var source: WorkshopSource {
        switch self {
        case .wallpapers: .browse
        case .collections: .collections
        case .subscriptions: .subscriptions
        }
    }
}

/// Where the Workshop's tiles come from.
enum WorkshopSource: Equatable, Sendable {
    /// Wallpaper Engine's wallpapers, searched, filtered and sorted by Steam.
    case browse
    /// Wallpaper Engine's collections, searched and sorted by Steam.
    case collections
    /// The wallpapers in one collection, in the collection's own order.
    case collection(id: String, title: String)
    /// One author's wallpapers.
    case creator(id: String, name: String)
    /// The wallpapers the signed-in Steam account subscribes to.
    case subscriptions

    var isSearchable: Bool {
        switch self {
        case .browse, .collections: true
        default: false
        }
    }

    var key: String {
        switch self {
        case .browse: "browse"
        case .collections: "collections"
        case .collection: "collection"
        case .creator: "creator"
        case .subscriptions: "subscriptions"
        }
    }

    var id: String? {
        switch self {
        case .collection(let id, _), .creator(let id, _): id
        default: nil
        }
    }

    var name: String? {
        switch self {
        case .collection(_, let title): title
        case .creator(_, let name): name
        default: nil
        }
    }

    var list: WorkshopList? {
        switch self {
        case .browse: .wallpapers
        case .collections: .collections
        case .subscriptions: .subscriptions
        case .collection, .creator: nil
        }
    }
}

/// What one search means. Steam receives the values from committed queries only.
struct WorkshopQuery: Equatable, Sendable {
    let text: String
    let kind: WorkshopKind
    let sort: WorkshopSort
    /// Steam `requiredtags[]`: every one must be on an item.
    var tags: [String] = []
    /// Steam `excludedtags[]`: an item carrying any of them is dropped.
    var excludedTags: [String] = []
    var source: WorkshopSource = .browse

    /// The Workshop item a pasted link or id names. Only the wallpapers list takes it;
    /// the other sources read the text as words to search for.
    var itemID: String? { source == .browse ? WorkshopLink.itemID(in: text) : nil }
}

struct WorkshopRequest: Equatable, Sendable {
    let query: WorkshopQuery
    let page: Int
}

/// One page of results, already scoped to Wallpaper Engine.
struct WorkshopPage: Sendable {
    var items: [WorkshopItem]
    let page: Int
    let totalPages: Int
    let totalCount: Int
    /// Steam's own name for the source when it has one, such as an author's.
    var title: String?
    /// Set when the usual page data could not be read and the items came from the links the
    /// page still carries: the list may be incomplete and its totals are estimates.
    var isDegraded = false
}

/// Something the Workshop cannot do, as a value so the UI owns the sentence. Cases never
/// carry cookie values, tokens or response bodies.
enum WorkshopFailure: Error, Equatable, Sendable {
    case httpStatus(Int)
    case network(String)
    case layoutChanged
    case busy
    case rateLimited
    case unreadablePage
    case unreadableDetails
    case itemUnavailable
    case notWallpaperEngine
    case applicationUnsupported
    case collectionUnavailable
    case invalidSteamID
    case signInRequired
    case downloadNotAvailable
    case importFailed(String)
    case fileAccess
    case cancelled

    var message: String {
        switch self {
        case .httpStatus(let status):
            String(format: WS("Steam returned status %d. Try again shortly.", "Steam 傳回狀態 %d，請稍後再試。"), status)
        case .network(let detail):
            String(format: WS("Couldn’t reach Steam: %@", "無法連線到 Steam：%@"), detail)
        case .layoutChanged:
            WS(
                "Steam changed its public page or requires a browser sign-in. Open Workshop on Steam, then retry.",
                "Steam 變更了公開頁面或要求瀏覽器登入。請在 Steam 開啟工作坊後再試。")
        case .busy:
            WS("Steam’s Workshop is busy. Try again in a moment.", "Steam 工作坊忙碌中，請稍後再試。")
        case .rateLimited:
            WS(
                "Steam is limiting requests from this device. Wait a minute, then try again.",
                "Steam 正在限制此裝置的請求。請等一分鐘後再試。")
        case .unreadablePage:
            WS(
                "Steam returned a Workshop page this app could not read. Try again or browse on Steam.",
                "Steam 傳回的工作坊頁面無法讀取。請再試或在 Steam 上瀏覽。")
        case .unreadableDetails:
            WS(
                "Steam answered the Workshop details in a form this app does not read.",
                "Steam 傳回的工作坊詳細資料格式無法讀取。")
        case .itemUnavailable:
            WS("Steam no longer serves this Workshop item.", "Steam 已不再提供此工作坊項目。")
        case .notWallpaperEngine:
            WS("This link is not a Wallpaper Engine item.", "此連結不是 Wallpaper Engine 項目。")
        case .applicationUnsupported:
            WS(
                "Application wallpapers run Windows programs and can’t be used on iPad.",
                "應用程式桌布會執行 Windows 程式，無法在 iPad 上使用。")
        case .collectionUnavailable:
            WS("Steam no longer serves this collection.", "Steam 已不再提供此合集。")
        case .invalidSteamID:
            WS("This Steam account id is not one Steam uses.", "這不是 Steam 使用的帳號 ID。")
        case .signInRequired:
            WS(
                "Steam asked you to sign in again. Sign in to Steam to see your subscriptions.",
                "Steam 要求你重新登入。請登入 Steam 以查看訂閱。")
        case .downloadNotAvailable:
            WS(
                "Steam requires its desktop client to download Wallpaper Engine’s Workshop files. This iPad can browse them and import a folder you already downloaded.",
                "Steam 需要桌面用戶端才能下載 Wallpaper Engine 的工作坊檔案。此 iPad 可以瀏覽，並匯入你已下載的資料夾。")
        case .importFailed(let detail):
            String(format: WS("Could not import the folder: %@", "無法匯入資料夾：%@"), detail)
        case .fileAccess:
            WS(
                "The selected folder could not be opened. Choose it again in Files.",
                "無法開啟所選資料夾，請在「檔案」中重新選擇。")
        case .cancelled:
            WS("Cancelled.", "已取消。")
        }
    }
}

extension WorkshopFailure: LocalizedError {
    var errorDescription: String? { message }
}

/// What a tile or the detail view may offer for an item, given what is installed. The iOS
/// build has no authorized Steam content downloader, so nothing here claims a download
/// succeeded: the available path is a desktop handoff plus a real folder import.
enum WorkshopDownloadAvailability: Equatable, Sendable {
    /// A collection: open it to see the wallpapers it holds.
    case collection
    /// An Application wallpaper: Windows-only.
    case unsupportedApplication
    /// A wallpaper already in the library. `update` is the Workshop's newer details when
    /// its author changed it since the installed copy was taken.
    case installed(update: WorkshopItem?)
    /// A wallpaper that needs Steam's desktop client to download; the iPad offers its
    /// Steam page, a link to copy, and the folder importer.
    case desktopDownloadRequired
}

/// A safe conversion from Steam's reply into a `WorkshopItem`. Kept as static functions so
/// parsers can be tested without a network or a running app.
enum WorkshopParsing {
    static func item(details row: [String: Any]) -> WorkshopItem? {
        guard (row["result"] as? Int) == 1,
              integer(row["consumer_app_id"]) == WorkshopApp.id,
              let id = row["publishedfileid"] as? String,
              isWorkshopID(id),
              let title = row["title"] as? String
        else { return nil }
        let preview = (row["preview_url"] as? String)
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let updated = number(row["time_updated"]).map(Date.init(timeIntervalSince1970:))
        let creatorID = row["creator"] as? String
        return WorkshopItem(
            id: id,
            title: title,
            creator: WS("Workshop creator", "工作坊創作者"),
            summary: summary(row["description"] as? String ?? ""),
            previewURL: preview?.scheme == "https" ? preview : nil,
            tags: WorkshopItem.tags(from: row["tags"]),
            size: Int64(row["file_size"] as? String ?? "")
                ?? number(row["file_size"]).map(Int64.init) ?? 0,
            subscriptions: integer(row["subscriptions"]) ?? 0,
            creatorID: creatorID,
            timeUpdated: updated,
            collectionSize: integer(row["creator_app_id"]) == WorkshopApp.collectionCreatorApp ? 0 : nil)
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// A Workshop id as Steam writes it: digits only, above zero, without leading zeros,
    /// and fitting a UInt64.
    static func isWorkshopID(_ value: String) -> Bool {
        guard (1...20).contains(value.utf8.count), value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              value.first != "0"
        else { return false }
        return UInt64(value) != nil
    }

    /// The first paragraph of a Workshop description, without Steam's BBCode markup,
    /// short enough for the detail view. Values are never interpreted as Markdown.
    static func summary(_ description: String) -> String {
        let plain = description.replacingOccurrences(
            of: #"\[/?[a-zA-Z0-9*]+(=[^\]]*)?\]"#, with: "", options: .regularExpression)
        let first = plain.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return first.count > 400 ? String(first.prefix(399)) + "…" : first
    }
}

/// A Workshop item named by what the person pasted: its web page, a `steam://` link or a
/// bare id. Links are read as URLs, never by a pattern over free text, so a sentence that
/// merely holds digits or a link is still a search.
enum WorkshopLink {
    /// A bare number names an item from this many digits on, so a short number such as a
    /// year is still searched for.
    static let minimumBareDigits = 6

    static func itemID(in text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.utf8.count >= minimumBareDigits,
           text.utf8.count <= 20,
           text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            return canonical(text)
        }
        return itemID(inLink: text)
    }

    /// The item a link names; a bare id is not a link. Accepted are the Workshop page on
    /// steamcommunity.com (`/sharedfiles/filedetails` or `/workshop/filedetails`, with an
    /// `id`) and `steam://url/CommunityFilePage/<id>`.
    static func itemID(inLink text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 2_048, !text.contains(where: \.isWhitespace),
              let link = URLComponents(string: text),
              link.user == nil, link.password == nil, link.port == nil,
              let scheme = link.scheme?.lowercased(), let host = link.host?.lowercased()
        else { return nil }
        let path = link.path.split(separator: "/").map { $0.lowercased() }
        switch scheme {
        case "https", "http":
            guard host == "steamcommunity.com" || host == "www.steamcommunity.com",
                  path == ["sharedfiles", "filedetails"] || path == ["workshop", "filedetails"]
            else { return nil }
            return (link.queryItems ?? []).first { $0.name == "id" }?.value.flatMap(canonical)
        case "steam":
            guard host == "url", path.count == 2, path[0] == "communityfilepage" else { return nil }
            return canonical(path[1])
        default:
            return nil
        }
    }

    private static func canonical(_ digits: String) -> String? {
        WorkshopParsing.isWorkshopID(digits) ? String(UInt64(digits) ?? 0) : nil
    }
}
