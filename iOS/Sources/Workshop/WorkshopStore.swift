import Foundation
import Observation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Workshop page's state: the draft controls, the committed query, paging, the cache,
/// the public Steam Community session and the update check.
///
/// Everything here is real Steam traffic or the shared `LibraryStore`; nothing fakes a
/// download. The iOS build has no authorized Steam content downloader, so an item's only
/// install path is a folder the person already obtained through Steam on a computer. The
/// browser exposes that handoff and the importer honestly.
@MainActor
@Observable
final class WorkshopStore {
    // MARK: The draft

    /// The search field's text. Edit it through `editSearch(_:)` so typing is debounced and a
    /// pasted link searches immediately.
    var searchText = ""
    var kind: WorkshopKind = .all
    var sort: WorkshopSort = .trendingYear {
        didSet { if sort != oldValue { search() } }
    }
    /// The filters the controls edit before and after asking Steam.
    private(set) var filters = WorkshopFilterDraft.cleared

    // MARK: The list

    private(set) var items: [WorkshopItem] = []
    private(set) var page = 1
    private(set) var totalPages = 1
    private(set) var totalCount = 0
    /// Results Steam can serve for the committed query: its count capped by 1,000 pages of
    /// 30, so the last page never asks for an unreachable item.
    private(set) var reachableCount = 0
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// The list on show was found from the links on a Steam page this app could no longer
    /// read the usual way, so it may be incomplete and its page count is an estimate.
    private(set) var isDegraded = false
    var errorMessage: String?
    private(set) var failedRequest: WorkshopRequest?
    private(set) var committedQuery: WorkshopQuery?
    private(set) var source: WorkshopSource = .browse
    private(set) var sourceHistory: [WorkshopSource] = []
    /// Steam's own name for the source when it has one, such as an author's or the signed-in
    /// account's display name.
    private(set) var sourceTitle: String?
    private(set) var selectedItem: WorkshopItem?

    // MARK: Steam Community

    /// The session subscriptions are read with. `sessions` keeps it between launches; it ends
    /// on Sign Out, or when Steam refuses to renew it.
    private(set) var steamWebSession: SteamWebSession?
    private(set) var isSigningInToSteamWeb = false
    @ObservationIgnored private let sessions: any WorkshopSteamSessionStoring
    @ObservationIgnored private var webSessionRestore: Task<Void, Never>?
    @ObservationIgnored private var webSessionRenewal: Task<SteamWebSession, Error>?
    @ObservationIgnored private var didRestoreSession = false

    // MARK: Updates and imports

    /// Which installed Workshop wallpapers have updates; an update is installed by importing
    /// the new folder, exactly like a first download.
    let updates: WorkshopUpdates
    private(set) var isImporting = false
    private(set) var lastImportOutcome: WorkshopImportOutcome?

    /// The item whose download/give-instructions sheet is open, if a view keeps one.
    // MARK: Dependencies

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let service: WorkshopService
    @ObservationIgnored let thumbnails: WorkshopThumbnailCache
    @ObservationIgnored private let sleep: @Sendable (UInt64) async throws -> Void

    // MARK: Search internals

    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var cacheQuery: WorkshopQuery?
    @ObservationIgnored private var cacheID = UUID()
    @ObservationIgnored private var steamPages: [Int: WorkshopPage] = [:]
    @ObservationIgnored private var steamFetches: [Int: Task<WorkshopPage, Error>] = [:]
    @ObservationIgnored private var screenedPages: [Int: WorkshopPage] = [:]
    @ObservationIgnored private var screenedFetches: [Int: Task<WorkshopPage, Error>] = [:]
    @ObservationIgnored private var pageStarts: [Int: SteamPosition] = [1: .start]
    @ObservationIgnored private var pageCounts: [Int: Int] = [:]
    @ObservationIgnored private static let maxSteamPagesPerPage = 10

    static var pageSize: Int { WorkshopService.pageSize }
    static var maxPages: Int { WorkshopService.maxPages }
    static var defaultExcludedTags: [String] { WorkshopFilterCatalog.defaultExcludedTags }

    init(
        library: LibraryStore,
        service: WorkshopService = WorkshopService(),
        thumbnails: WorkshopThumbnailCache = WorkshopThumbnailCache(),
        updates: WorkshopUpdates? = nil,
        sessions: any WorkshopSteamSessionStoring = KeychainWorkshopSteamSessionStore(),
        defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.library = library
        self.service = service
        self.thumbnails = thumbnails
        self.updates = updates ?? WorkshopUpdates(defaults: defaults)
        self.sessions = sessions
        self.sleep = sleep
    }

    // MARK: Lifecycle

    /// The page appeared: restore a saved Steam session, start the first search, and check
    /// installed Workshop wallpapers for updates when a day has passed.
    func start() async {
        restoreSteamWebSession()
        if !hasLoaded && !isLoading { search() }
        updates.checkIfDue(
            installed: Array(installedWorkshopIDs), library: library.rootURL)
    }

    // MARK: Library facts

    /// Workshop ids currently in the shared managed library. The embedding view observes
    /// `LibraryStore` itself, so a change re-renders the grid and these facts stay current.
    var installedWorkshopIDs: Set<String> {
        Set(library.items.compactMap(\.workshopID))
    }

    func isInstalled(_ item: WorkshopItem) -> Bool {
        installedWorkshopIDs.contains(item.id)
    }

    func update(for item: WorkshopItem) -> WorkshopItem? {
        updates.available[item.id]
    }

    /// What the detail view may offer for this item. There is deliberately no `.download`
    /// case: no authorized iOS downloader exists.
    func availability(for item: WorkshopItem) -> WorkshopDownloadAvailability {
        if item.isCollection { return .collection }
        if item.isApplication { return .unsupportedApplication }
        if isInstalled(item) { return .installed(update: update(for: item)) }
        return .desktopDownloadRequired
    }

    /// The current page's wallpapers that are not in the library, have a wallpaper file, and
    /// can be handed to a desktop Steam client. Collections and Application items are left
    /// out.
    var itemsMissingFromLibrary: [WorkshopItem] {
        items.filter {
            !$0.isCollection && !$0.isApplication && !isInstalled($0)
        }
    }

    // MARK: Search

    /// An edit of the search field. A pasted link or a full-length item id searches at once;
    /// other typing waits for a short pause, and Return commits immediately.
    func editSearch(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        pendingSearch?.cancel()
        pendingSearch = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            search()
            return
        }
        if let id = WorkshopLink.itemID(in: text), !text.allSatisfy(\.isNumber) || id.count >= 9 {
            search()
            return
        }
        pendingSearch = Task { [weak self, sleep] in
            do { try await sleep(450_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.search()
        }
    }

    /// Return, Refresh, a sort or a filter: searches with the draft now, from the first page
    /// and with a fresh cache. Any typing still waiting for its pause is superseded.
    @discardableResult
    func search() -> Task<Void, Never> {
        pendingSearch?.cancel()
        pendingSearch = nil
        let query = draftQuery
        resetCache(for: query)
        return load(WorkshopRequest(query: query, page: 1))
    }

    func commitSearch() { search() }

    func refresh() { search() }

    func setSort(_ new: WorkshopSort) {
        if sort != new { sort = new }
    }

    func setKind(_ new: WorkshopKind) {
        guard kind != new else { return }
        kind = new
        search()
    }

    /// **Clear search and filters** and **Clear search**: the text goes too, and the filters
    /// return to their defaults.
    func clearSearchAndFilters() {
        pendingSearch?.cancel()
        pendingSearch = nil
        searchText = ""
        filters.clear()
        search()
    }

    func clearSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        searchText = ""
        search()
    }

    func clearFilters() {
        filters.clear()
        search()
    }

    func setRequired(_ tag: String, _ required: Bool) {
        filters.setRequired(tag, required)
        search()
    }

    func setIncluded(_ tag: String, _ included: Bool) {
        filters.setIncluded(tag, included)
        search()
    }

    func setChip(_ tag: String, _ selection: WorkshopFilterSelection) {
        filters.setChip(tag, selection)
        search()
    }

    func resetChips(in section: WorkshopFilterCatalog.Section) {
        filters.resetChips(in: section)
        search()
    }

    func includeAll(in section: WorkshopFilterCatalog.Section) {
        filters.includeAll(in: section)
        search()
    }

    func excludeAll(in section: WorkshopFilterCatalog.Section) {
        filters.excludeAll(in: section)
        search()
    }

    var filterCount: Int { filters.count }

    func retry() {
        guard let failedRequest else {
            search()
            return
        }
        load(failedRequest)
    }

    // MARK: Lists and sources

    func open(_ list: WorkshopList) {
        open(list.source)
    }

    /// Shows another source from its first page. An author or a collection is opened from
    /// what is on show, so Back can return there; choosing a list afresh starts a new history.
    func open(_ next: WorkshopSource) {
        switch next {
        case .creator, .collection:
            let current = committedQuery?.source ?? source
            if current != next { sourceHistory.append(current) }
        case .browse, .collections, .subscriptions:
            sourceHistory = []
        }
        source = next
        selectedItem = nil
        search()
    }

    /// **More by this author**, when Steam gave the author's SteamID64.
    func openAuthor(of item: WorkshopItem) {
        guard let id = item.creatorID, SteamWebSession.isSteamID(id) else { return }
        open(.creator(id: id, name: item.creator))
    }

    /// Opens a collection's wallpapers. A collection is a list, never a download.
    func openCollection(_ item: WorkshopItem) {
        guard item.isCollection else { return }
        open(.collection(id: item.id, title: item.title))
    }

    func goBack() {
        guard let previous = sourceHistory.popLast() else { return }
        source = previous
        selectedItem = nil
        search()
    }

    var canGoBack: Bool { !sourceHistory.isEmpty }

    // MARK: Paging

    func loadPage(_ number: Int) {
        guard let committedQuery,
              number >= 1, number <= min(totalPages, Self.maxPages)
        else { return }
        load(WorkshopRequest(query: committedQuery, page: number))
    }

    func showPage(_ number: Int) {
        showPage(number, totalPages: totalPages)
    }

    func showPage(_ number: Int, totalPages pages: Int) {
        let target = min(max(1, number), max(1, min(pages, Self.maxPages)))
        guard target != page || !hasLoaded else { return }
        loadPage(target)
    }

    /// The page a number typed into the jump field names: rounded, brought into the pages
    /// the bar offers, and the first page for text that is not a number.
    func clampedPage(typed text: String) -> Int {
        let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let rounded = (value ?? 0).rounded(.toNearestOrAwayFromZero)
        let number = rounded.isNaN || rounded == 0 ? 1 : rounded
        return Int(min(Double(max(totalPages, 1)), max(1, number)))
    }

    // MARK: Selection

    func select(_ item: WorkshopItem) {
        selectedItem = item
    }

    func clearSelection() {
        selectedItem = nil
    }

    // MARK: Steam Community

    /// Takes back the session saved by an earlier launch, once. The keychain is read off the
    /// main actor.
    func restoreSteamWebSession() {
        guard !didRestoreSession else { return }
        didRestoreSession = true
        let sessions = sessions
        webSessionRestore = Task { [weak self] in
            let saved = await Task.detached(priority: .userInitiated) {
                sessions.load()
            }.value
            // A sign-out while the keychain answered wins.
            guard let self, !Task.isCancelled, let saved, self.steamWebSession == nil,
                  !self.isSigningInToSteamWeb
            else { return }
            self.steamWebSession = saved
            if (self.committedQuery?.source ?? self.source) == .subscriptions {
                self.search()
            }
        }
    }

    /// The view's sign-in sheet finished with a session. The app never saw the password; the
    /// sheet took only Steam's cookies from its own non-persistent web view.
    func completeSteamSignIn(_ session: SteamWebSession) {
        isSigningInToSteamWeb = false
        webSessionRenewal?.cancel()
        webSessionRenewal = nil
        steamWebSession = session
        if (committedQuery?.source ?? source) == .subscriptions { search() }
        try? sessions.save(session)
    }

    func beginSteamSignIn() {
        isSigningInToSteamWeb = true
    }

    func cancelSteamSignIn() {
        isSigningInToSteamWeb = false
    }

    /// Forgets the Steam Community session, here and in the keychain. Steam's own sign-in page
    /// kept no cookie: its web view used a non-persistent data store.
    func signOutOfSteam() {
        webSessionRestore?.cancel()
        webSessionRenewal?.cancel()
        webSessionRenewal = nil
        steamWebSession = nil
        isSigningInToSteamWeb = false
        sessions.remove()
        if (committedQuery?.source ?? source) == .subscriptions {
            cancelSearch()
            clearResults()
        }
    }

    /// The session to read with: the one held, renewed first when its cookie has run out.
    /// Readers that arrive during a renewal wait for that one. Steam refusing the renewal
    /// throws `signInRequired`; the caller forgets the session.
    func currentSteamWebSession() async throws -> SteamWebSession? {
        if let webSessionRestore, steamWebSession == nil { await webSessionRestore.value }
        guard let session = steamWebSession else { return nil }
        guard session.needsRenewal(at: Date()) else { return session }
        let renewal = webSessionRenewal ?? Task { [service] in
            try await service.renew(session)
        }
        webSessionRenewal = renewal
        do {
            let renewed = try await renewal.value
            if webSessionRenewal == renewal {
                webSessionRenewal = nil
                if steamWebSession == session {
                    steamWebSession = renewed
                    try? sessions.save(renewed)
                }
            }
            return steamWebSession
        } catch {
            if webSessionRenewal == renewal { webSessionRenewal = nil }
            throw error
        }
    }

    var isSignedInToSteam: Bool { steamWebSession != nil }

    /// The label beside the list tabs while a Steam session is held. The account's display
    /// name comes from Steam's subscriptions page; the SteamID64 is not shown here.
    var subscriptionAccountLabel: String? {
        guard steamWebSession != nil else { return nil }
        if (committedQuery?.source ?? source) == .subscriptions,
           let name = sourceTitle, !name.isEmpty {
            return name
        }
        return WS("Signed in to Steam", "已登入 Steam")
    }

    // MARK: Updates

    func checkForUpdates() {
        updates.check(installed: Array(installedWorkshopIDs), library: library.rootURL)
    }

    // MARK: Importing a folder obtained through Steam on a computer

    /// Imports a folder the person obtained through Steam on a computer. `item` names the
    /// item the sheet was showing; when it is known, the folder must contain that item's
    /// `project.json` (or be the item's folder inside a `content/431960` tree), so a wrong
    /// selection does not silently add something else. The import itself goes through the
    /// shared `LibraryStore.importURL` contract.
    func importFolder(_ url: URL, for item: WorkshopItem?) async {
        guard !isImporting else { return }
        isImporting = true
        lastImportOutcome = nil
        defer { isImporting = false }

        #if canImport(Darwin)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #endif

        guard let folder = WorkshopImportPreflight.folder(in: url, expecting: item?.id) else {
            lastImportOutcome = .notAFolder
            return
        }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            lastImportOutcome = .fileAccess
            return
        }

        await library.importURL(folder)

        let installed = installedWorkshopIDs
        if let expected = item?.id, !installed.contains(expected) {
            // The library may have rejected the folder, or found another item in it; the
            // grid's own state is the truth. Say so instead of claiming a download.
            if let imported = library.items.last(where: { $0.title == item?.title }) {
                lastImportOutcome = .imported(workshopID: imported.workshopID)
            } else {
                lastImportOutcome = .importedWithoutWorkshopID
            }
        } else {
            lastImportOutcome = .imported(workshopID: item?.id)
        }
        checkForUpdates()
    }

    func clearImportOutcome() {
        lastImportOutcome = nil
    }

    // MARK: The query and the Steam page

    private var draftQuery: WorkshopQuery {
        WorkshopQuery(
            text: searchText.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
            sort: sort, tags: filters.tags, excludedTags: filters.excludedTags, source: source)
    }

    var isLookup: Bool { committedQuery?.itemID != nil }

    /// The Steam page showing the current page's tiles, for **Open on Steam**.
    var browseURL: URL {
        let query = committedQuery ?? draftQuery
        switch query.source {
        case .browse, .collections:
            if let id = query.itemID { return WorkshopItem.pageURL(id: id) }
            let steamPage = Self.fillsPages(query) ? pageStarts[page]?.page ?? page : page
            return WorkshopService.browseURL(
                search: query.text, kind: query.source == .browse ? query.kind : .all,
                sort: query.sort, page: steamPage, tags: query.tags,
                excludedTags: query.excludedTags,
                section: query.source == .browse ? "readytouseitems" : "collections")
        case .collection(let id, _):
            return WorkshopItem.pageURL(id: id)
        case .creator(let id, _):
            return WorkshopService.profileURL(steamID: id, subscriptions: false, page: page)
        case .subscriptions:
            return steamWebSession.map {
                WorkshopService.profileURL(steamID: $0.steamID, subscriptions: true, page: page)
            } ?? URL(string: "https://steamcommunity.com/app/\(WorkshopApp.id)/workshop/")!
        }
    }

    /// What is on show, by name.
    var heading: String {
        if let list = source.list { return list.title }
        switch source {
        case .creator:
            return sourceTitle.map {
                String(format: WS("Wallpapers by %@", "%@ 的桌布"), $0)
            } ?? WS("This author’s wallpapers", "此作者的桌布")
        case .collection:
            return sourceTitle.map {
                String(format: WS("Collection: %@", "合集：%@"), $0)
            } ?? WS("Collection", "合集")
        default:
            return sourceTitle ?? WS("Workshop", "工作坊")
        }
    }

    // MARK: Cache and loads

    private static func fillsPages(_ query: WorkshopQuery) -> Bool {
        query.source == .collections
            && WorkshopService.screensRatings(
                tags: query.tags, excludedTags: query.excludedTags)
    }

    private func resetCache(for query: WorkshopQuery?) {
        for task in steamFetches.values { task.cancel() }
        for task in screenedFetches.values { task.cancel() }
        steamFetches = [:]
        screenedFetches = [:]
        cacheID = UUID()
        if let query {
            steamPages = [:]
            screenedPages = [:]
            pageStarts = [1: .start]
            pageCounts = [:]
            cacheQuery = query
        }
    }

    private func fetchSteamPage(
        _ number: Int, query: WorkshopQuery
    ) -> Task<WorkshopPage, Error> {
        if let task = steamFetches[number] { return task }
        let cacheID = cacheID
        let service = service
        let task = Task { [weak self] in
            defer {
                if let self, self.cacheID == cacheID { self.steamFetches[number] = nil }
            }
            let result: WorkshopPage
            if Self.fillsPages(query), let self {
                result = try await self.filledPage(number, query: query, cacheID: cacheID)
            } else {
                let account = query.source == .subscriptions
                    ? try await self?.currentSteamWebSession() : nil
                result = try await service.page(for: query, page: number, account: account)
            }
            try Task.checkCancellation()
            if let self, self.cacheID == cacheID {
                self.steamPages[number] = result
                self.thumbnails.warm(result.items.compactMap(\.previewURL))
            }
            return result
        }
        steamFetches[number] = task
        return task
    }

    /// A panel page of screened collections, filled from as many Steam pages as it takes, on
    /// from where the page before it stopped, so paging forward and back shows each
    /// collection once. A page jumped to before the one ahead of it was shown starts where
    /// the pages read so far suggest; that start, the page count and the result count are
    /// estimates.
    private func filledPage(
        _ number: Int, query: WorkshopQuery, cacheID: UUID
    ) async throws -> WorkshopPage {
        let start = pageStarts[number] ?? estimatedStart(of: number)
        var position: SteamPosition? = start
        var items: [WorkshopItem] = []
        var steamPageCount = 1
        var steamCount = 0
        var read = 0
        while let current = position, items.count < Self.pageSize,
              read < Self.maxSteamPagesPerPage {
            guard self.cacheID == cacheID, !Task.isCancelled else {
                throw CancellationError()
            }
            if let known = screenedPages.values.first?.totalPages,
               current.page < min(Self.maxPages, known) {
                _ = fetchScreenedPage(current.page + 1, query: query, cacheID: cacheID)
            }
            let steam = try await fetchScreenedPage(
                current.page, query: query, cacheID: cacheID
            ).value
            read += 1
            steamPageCount = min(Self.maxPages, max(1, steam.totalPages))
            steamCount = steam.totalCount
            let kept = steam.items.dropFirst(current.offset)
            let taken = kept.prefix(Self.pageSize - items.count)
            items += taken
            if taken.count < kept.count {
                position = SteamPosition(
                    page: current.page, offset: current.offset + taken.count)
            } else {
                position = current.page < steamPageCount
                    ? SteamPosition(page: current.page + 1, offset: 0) : nil
            }
        }
        guard self.cacheID == cacheID else { throw CancellationError() }
        if pageStarts[number] == nil { pageStarts[number] = start }
        pageCounts[number] = items.count
        guard let next = position else {
            let before = (1..<number).reduce(0) { $0 + (pageCounts[$1] ?? Self.pageSize) }
            return WorkshopPage(
                items: items, page: number, totalPages: number,
                totalCount: before + items.count)
        }
        if pageStarts[number + 1] == nil { pageStarts[number + 1] = next }
        let steamPagesPerPage = max(1, next.progress / Double(number))
        let remaining = Int(
            ((Double(steamPageCount) - next.progress) / steamPagesPerPage).rounded())
        return WorkshopPage(
            items: items, page: number,
            totalPages: min(Self.maxPages, number + max(1, remaining)),
            totalCount: max(
                number * Self.pageSize, Int(Double(steamCount) / steamPagesPerPage)))
    }

    private func estimatedStart(of number: Int) -> SteamPosition {
        let before = pageStarts.filter { $0.key < number }.max { $0.key < $1.key }
            ?? (key: 1, value: .start)
        let furthest = pageStarts.max { $0.key < $1.key } ?? (key: 1, value: .start)
        let rate = furthest.key > 1
            ? max(1, furthest.value.progress / Double(furthest.key - 1)) : 1
        let page = Int(before.value.progress + Double(number - before.key) * rate) + 1
        let last = screenedPages.values.first
            .map { min(Self.maxPages, max(1, $0.totalPages)) } ?? page
        return SteamPosition(page: min(page, last), offset: 0)
    }

    private func fetchScreenedPage(
        _ number: Int, query: WorkshopQuery, cacheID: UUID
    ) -> Task<WorkshopPage, Error> {
        guard cacheID == self.cacheID else {
            return Task { throw CancellationError() }
        }
        if let page = screenedPages[number] { return Task { page } }
        if let task = screenedFetches[number] { return task }
        let service = service
        let task = Task { [weak self] in
            defer {
                if let self, self.cacheID == cacheID {
                    self.screenedFetches[number] = nil
                }
            }
            let result = try await service.page(for: query, page: number, account: nil)
            try Task.checkCancellation()
            if let self, self.cacheID == cacheID { self.screenedPages[number] = result }
            return result
        }
        screenedFetches[number] = task
        return task
    }

    private func publish(_ result: WorkshopPage, for request: WorkshopRequest) {
        var seen = Set<String>()
        items = result.items.filter { seen.insert($0.id).inserted }
        totalCount = result.totalCount
        totalPages = min(Self.maxPages, max(1, result.totalPages))
        reachableCount = min(result.totalCount, totalPages * Self.pageSize)
        page = min(totalPages, request.page)
        hasLoaded = true
        isDegraded = result.isDegraded
        committedQuery = request.query
        sourceTitle = result.title
        failedRequest = nil
    }

    @discardableResult
    private func load(_ request: WorkshopRequest) -> Task<Void, Never> {
        searchTask?.cancel()
        // A cache built for another query holds nothing this one can use.
        if cacheQuery != request.query { resetCache(for: request.query) }
        let token = UUID()
        generation = token
        errorMessage = nil
        // Paging back to a page already read shows it at once, never as loading.
        if let cached = steamPages[request.page] {
            isLoading = false
            publish(cached, for: request)
            return Task {}
        }
        isLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isLoading = false } }
            do {
                let result = try await self.fetchSteamPage(
                    request.page, query: request.query).value
                guard self.generation == token, !Task.isCancelled else { return }
                self.publish(result, for: request)
            } catch {
                guard self.generation == token, !Task.isCancelled,
                      !(error is CancellationError)
                else { return }
                WorkshopLog.warn(
                    "Workshop \(request.query.source.key) page \(request.page) failed: \(error.localizedDescription)")
                let failure = error as? WorkshopFailure
                if failure == .signInRequired {
                    // The session ended: drop it and the stale tiles, so the page offers
                    // signing in again.
                    self.signOutOfSteam()
                    self.clearResults()
                } else if self.committedQuery?.source != request.query.source {
                    self.clearResults()
                }
                self.errorMessage = error.localizedDescription
                self.failedRequest = request
            }
        }
        searchTask = task
        return task
    }

    private func clearResults() {
        items = []
        page = 1
        totalCount = 0
        totalPages = 1
        reachableCount = 0
        committedQuery = nil
        sourceTitle = nil
        hasLoaded = false
        isDegraded = false
    }

    func cancelSearch() {
        searchTask?.cancel()
        resetCache(for: nil)
        generation = UUID()
        isLoading = false
    }
}

/// A place among Steam's screened pages: the page, and how many of the tiles it kept come
/// before.
private struct SteamPosition: Equatable, Sendable {
    static let start = SteamPosition(page: 1, offset: 0)
    var page: Int
    var offset: Int

    /// How many Steam pages lie before this place, a partly read one by the share read.
    var progress: Double {
        Double(page - 1) + Double(offset) / Double(WorkshopService.pageSize)
    }
}

/// Raised after a folder import so the view can say what actually happened.
enum WorkshopImportOutcome: Equatable, Sendable {
    case imported(workshopID: String?)
    case importedWithoutWorkshopID
    case notAFolder
    case fileAccess

    var message: String {
        switch self {
        case .imported(let id):
            if let id {
                return String(
                    format: WS("Imported the folder for Workshop item %@.", "已匯入工作坊項目 %@ 的資料夾。"),
                    id)
            }
            return WS("The folder was imported into the library.", "資料夾已匯入媒體庫。")
        case .importedWithoutWorkshopID:
            return WS(
                "The folder was imported, but no Workshop id was found. You can still use it from the library; update checks may not know this item.",
                "資料夾已匯入，但找不到工作坊 ID。你仍可從媒體庫使用它；更新檢查可能無法辨識此項目。")
        case .notAFolder:
            return WS(
                "Choose the whole wallpaper folder, the item’s folder inside steamapps/workshop/content/431960, or a copy of it.",
                "請選擇完整的桌布資料夾、steamapps/workshop/content/431960 內的項目資料夾，或其副本。")
        case .fileAccess:
            return WS(
                "The selected folder could not be opened. Choose it again in Files.",
                "無法開啟所選資料夾，請在「檔案」中重新選擇。")
        }
    }
}

/// Finds the wallpaper folder inside a selection from Files, so a person can choose either
/// the item's folder or the `431960` folder that contains it.
enum WorkshopImportPreflight {
    static func folder(in url: URL, expecting itemID: String?) -> URL? {
        let fileManager = FileManager.default
        guard isDirectory(url, fileManager) else { return nil }

        if let itemID {
            let direct = url.appendingPathComponent(itemID, isDirectory: true)
            if containsWallpaper(direct, fileManager) { return direct }
            if url.lastPathComponent == itemID, containsWallpaper(url, fileManager) {
                return url
            }
            // A `steamapps/workshop/content/431960/<id>` path selected a level or two above.
            if let component = url.pathComponents.lastIndex(of: itemID) {
                let candidate = URL(fileURLWithPath: NSString.path(
                    withComponents: Array(url.pathComponents[...component])))
                if containsWallpaper(candidate, fileManager) { return candidate }
            }
            return nil
        }

        if containsWallpaper(url, fileManager) { return url }
        let children = (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return children.first { containsWallpaper($0, fileManager) }
    }

    private static func containsWallpaper(_ url: URL, _ fileManager: FileManager) -> Bool {
        guard isDirectory(url, fileManager) else { return false }
        return fileManager.fileExists(atPath: url.appendingPathComponent("project.json").path)
            || fileManager.fileExists(atPath: url.appendingPathComponent("scene.pkg").path)
    }

    private static func isDirectory(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// The lawful desktop handoff for a Workshop item. These are Steam's own page and app URLs;
/// nothing here guesses a content URL or bypasses ownership.
enum WorkshopDesktopHandoff {
    static func steamPageURL(for item: WorkshopItem) -> URL {
        item.pageURL
    }

    /// `steam://` opens the Steam mobile app or the desktop client when installed. The view
    /// checks `canOpenURL`; iOS only answers true when the app declares the scheme.
    static func steamAppURL(for item: WorkshopItem) -> URL? {
        guard WorkshopParsing.isWorkshopID(item.id) else { return nil }
        return URL(string: "steam://url/CommunityFilePage/\(item.id)")
    }

    /// The Steam links of `items`, one per line, for copying to a computer.
    static func links(for items: [WorkshopItem]) -> String {
        items.map(\.pageURL.absoluteString).joined(separator: "\n")
    }

    /// Steps for getting a Workshop wallpaper onto the iPad. The app never asks for a Steam
    /// password: the download happens in Steam on a computer, then the folder is imported.
    static func steps(for item: WorkshopItem) -> [String] {
        [
            WS(
                "On a Mac or Windows PC, sign in to Steam and subscribe to this item. Wallpaper Engine must be owned by that Steam account.",
                "在 Mac 或 Windows 電腦上登入 Steam 並訂閱此項目。該 Steam 帳號必須擁有 Wallpaper Engine。"),
            String(
                format: WS(
                    "Let Steam download it, then find the folder steamapps/workshop/content/431960/%@.",
                    "讓 Steam 完成下載，然後找到資料夾 steamapps/workshop/content/431960/%@。"),
                item.id),
            WS(
                "Copy that folder to the iPad through Files, AirDrop or iCloud Drive.",
                "透過「檔案」、AirDrop 或 iCloud Drive 將該資料夾複製到 iPad。"),
            WS(
                "Return here, tap Import downloaded folder, and choose the copied folder.",
                "回到這裡，點一下「匯入已下載資料夾」，然後選擇複製的資料夾。"),
        ]
    }

    /// What the update path needs beyond the first download.
    static func updateSteps(for item: WorkshopItem) -> [String] {
        [
            WS(
                "Steam on the iPad cannot download Workshop content. On a computer, download the item again in Steam so it has the author’s newest files.",
                "iPad 上的 Steam 無法下載工作坊內容。請在電腦的 Steam 重新下載此項目，取得作者最新的檔案。"),
            String(
                format: WS(
                    "Copy steamapps/workshop/content/431960/%@ to the iPad again and import it over the installed copy.",
                    "再次將 steamapps/workshop/content/431960/%@ 複製到 iPad，並匯入以取代已安裝的版本。"),
                item.id),
            WS(
                "The library decides whether the new folder replaces the installed item; nothing is deleted before the import succeeds.",
                "媒體庫會決定新資料夾是否取代已安裝項目；匯入成功前不會刪除任何內容。"),
        ]
    }
}
