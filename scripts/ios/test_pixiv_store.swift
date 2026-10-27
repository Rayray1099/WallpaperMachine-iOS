// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private let testSession = "31415926_Q7vX2mLp9KdR4tYw8NzB3cHs6FgJ1aUe"
private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private func ranking(mode: String, page: Int) -> Data {
    let base = mode == "weekly" ? 90 : page * 10
    let rows: [[String: Any]] = (0..<2).map { offset in
        ["illust_id": base + offset, "illust_type": 0, "title": "Fixture", "user_id": 12,
         "user_name": "Artist", "url": "https://i.pximg.net/fixture.jpg", "width": 1920,
         "height": 1080, "illust_page_count": 1,
         "illust_content_type": ["sexual": 0, "grotesque": false]]
    }
    return json(["contents": rows, "page": page, "rank_total": 100, "next": page == 1 ? 2 : false])
}

/// Intentionally ignores cancellation at held replies, to exercise stale result defenses.
private actor ControlledTransport: PixivTransport {
    let holdRanking: Bool
    let holdStatus: Bool
    let holdImage: Bool
    let signedIn: Bool
    private var heldRanking = false
    private var heldImage = false
    private var rankingReply: CheckedContinuation<Data, Error>?
    private var rankingData: Data?
    private var statusReply: CheckedContinuation<Data, Error>?
    private var imageReply: CheckedContinuation<Data, Error>?
    private var oldProgress: (@Sendable (Int64, Int64?) -> Void)?
    private(set) var rankingRequests = 0
    private(set) var imageRequests = 0

    init(holdRanking: Bool = false, holdStatus: Bool = false, holdImage: Bool = false, signedIn: Bool = true) {
        self.holdRanking = holdRanking; self.holdStatus = holdStatus
        self.holdImage = holdImage; self.signedIn = signedIn
    }
    var waitingForRanking: Bool { rankingReply != nil }
    var waitingForStatus: Bool { statusReply != nil }
    var waitingForImage: Bool { imageReply != nil }

    func data(from url: URL, session: String?) async throws -> Data {
        if url.path == "/ranking.php" {
            rankingRequests += 1
            let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let page = Int(parameters.first { $0.name == "p" }?.value ?? "1") ?? 1
            let mode = parameters.first { $0.name == "mode" }?.value ?? "daily"
            let data = ranking(mode: mode, page: page)
            if holdRanking && !heldRanking {
                heldRanking = true; rankingData = data
                return try await withCheckedThrowingContinuation { rankingReply = $0 }
            }
            return data
        }
        if url.path.hasSuffix("/status") {
            if holdStatus {
                return try await withCheckedThrowingContinuation { statusReply = $0 }
            }
            return statusData()
        }
        if url.path.hasSuffix("/pages") {
            return json(["error": false, "body": [["width": 1, "height": 1,
                "urls": ["original": "https://i.pximg.net/original.png", "small": "https://i.pximg.net/preview.jpg"]]]])
        }
        throw PixivFailure(code: .unreadable)
    }

    private func statusData() -> Data {
        json(["error": false, "body": ["user_status": ["is_logged_in": signedIn,
            "user_id": "31415926", "user_name": "Fixture", "user_x_restrict": 1]]])
    }
    func releaseRanking() {
        let reply = rankingReply; rankingReply = nil
        reply?.resume(returning: rankingData!)
    }
    func releaseStatus() {
        let reply = statusReply; statusReply = nil
        reply?.resume(returning: statusData())
    }
    func releaseImage() {
        oldProgress?(9000, 10000)
        let reply = imageReply; imageReply = nil
        reply?.resume(returning: png)
    }
    func image(from url: URL, limit: Int,
               progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Data {
        imageRequests += 1
        progress(1, Int64(png.count))
        if holdImage && !heldImage {
            heldImage = true; oldProgress = progress
            return try await withCheckedThrowingContinuation { imageReply = $0 }
        }
        progress(Int64(png.count), Int64(png.count))
        return png
    }
}

private final class MemorySessions: PixivSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func load() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ session: String) throws { lock.lock(); defer { lock.unlock() }; value = session }
    func remove() { lock.lock(); defer { lock.unlock() }; value = nil }
}

@MainActor private final class FixtureLibrary: PixivLibraryAccess {
    var items: [WallpaperItem] = []
    var failImport = false
    var imports = 0
    func installedPixivItem(workID: String, page: Int) -> WallpaperItem? {
        items.first { $0.pixiv?.id == workID && $0.pixiv?.page == page }
    }
    func importPixivProject(_ folder: URL) async throws {
        imports += 1
        if failImport { throw LibraryError.unsupported("fixture failure") }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("project.json"))) as! [String: Any]
        let source = try JSONDecoder().decode(PixivAttribution.self, from: json(object["pixiv"]!))
        items.append(WallpaperItem(title: "Fixture", kind: .image, relativePath: "fixture",
            entryFile: object["file"] as! String, pixiv: source))
    }
}

@main struct PixivStoreRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    @MainActor static func eventually(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure(description: "Timed out waiting for fixture state")
    }
    @MainActor private static func make(_ transport: ControlledTransport, library: FixtureLibrary? = nil,
                                sessions: MemorySessions = MemorySessions()) -> PixivStore {
        PixivStore(library: library ?? FixtureLibrary(), service: PixivService(transport: transport, minimumInterval: .zero), sessions: sessions)
    }
    @MainActor static func ready(_ store: PixivStore) async throws {
        await store.start()
        try await eventually { !store.isLoading && !store.works.isEmpty }
    }

    @MainActor static func cacheAndFilters() async throws {
        let transport = ControlledTransport(); let store = make(transport)
        try await ready(store)
        var query = store.query; query.orientation = .portrait
        store.apply(query)
        try require(store.works.isEmpty && store.hiddenCount == 2, "Client filter did not hide landscape works")
        let count = await transport.rankingRequests
        try require(count == 1, "Client-only filter fetched a new page")
        query.orientation = .any; store.apply(query)
        store.loadPage(2)
        try await eventually { !store.isLoading && store.page == 2 && store.works.first?.id == "20" }
        store.loadPage(1)
        try require(store.works.first?.id == "10", "Back navigation lost its cached page")
        let pagedCount = await transport.rankingRequests
        try require(pagedCount == 2, "Cached page was fetched again")
    }

    @MainActor static func staleListing() async throws {
        let transport = ControlledTransport(holdRanking: true); let store = make(transport)
        await store.start()
        try await eventually { await transport.waitingForRanking }
        var query = store.query; query.ranking = .weekly; store.apply(query)
        try await eventually { !store.isLoading && store.works.first?.id == "90" }
        await transport.releaseRanking()
        try await Task.sleep(for: .milliseconds(40))
        try require(store.works.first?.id == "90" && store.query.ranking == .weekly, "Old listing replaced the active query")
    }

    @MainActor static func lateSignIn() async throws {
        let transport = ControlledTransport(holdStatus: true); let sessions = MemorySessions()
        let store = make(transport, sessions: sessions)
        try await ready(store)
        store.signIn(session: testSession)
        try await eventually { await transport.waitingForStatus }
        store.signOut()
        await transport.releaseStatus()
        try await Task.sleep(for: .milliseconds(40))
        try require(store.account == nil && !store.canShowMature && !store.isCheckingAccount, "Late login restored a signed-out account")
        try require(sessions.load() == nil, "Late login restored a signed-out session")
    }

    @MainActor static func matureSanitization() async throws {
        let transport = ControlledTransport(); let store = make(transport)
        try await ready(store)
        store.signIn(session: testSession)
        try await eventually { store.canShowMature }
        var query = store.query; query.ratings = [.mature]; query.ranking = .dailyR18
        store.apply(query)
        try await eventually { !store.isLoading && store.works.first?.rating == .mature }
        store.signOut()
        try require(!store.query.ratings.contains(.mature) && !store.query.ranking.isR18, "Sign-out left a mature query enabled")
        try await eventually { !store.isLoading }
        try require(store.works.allSatisfy { $0.rating != .mature }, "Sign-out left restricted results visible")
    }

    @MainActor static func expiredRestore() async throws {
        let transport = ControlledTransport(signedIn: false); let sessions = MemorySessions(testSession)
        let store = make(transport, sessions: sessions)
        try await ready(store)
        try require(store.account == nil && sessions.load() == nil && store.sessionWarning != nil,
                    "Expired session was not cleared and reported")
        try require(!store.isCheckingAccount && !store.isLoading, "Expired restore left a loading indicator stuck")
    }

    @MainActor static func failedImportRetry() async throws {
        let library = FixtureLibrary(); library.failImport = true
        let store = make(ControlledTransport(), library: library)
        try await ready(store)
        let work = store.works[0]; let pages = try await store.pages(for: work)
        store.requestDownload(work, page: pages[0], pageCount: pages.count)
        try await eventually { store.download(for: work, page: 0)?.status == .failed }
        try require(library.items.isEmpty && library.imports == 1, "Failed import reported a saved wallpaper")
        try require(store.download(for: work, page: 0)?.errorMessage != nil, "Failed import lost its error")
        library.failImport = false
        store.requestDownload(work, page: pages[0], pageCount: pages.count)
        try await eventually { store.download(for: work, page: 0)?.status == .completed }
        try require(library.items.count == 1 && library.imports == 2, "Failed import could not be retried")
    }

    @MainActor static func cancelledRetry() async throws {
        let transport = ControlledTransport(holdImage: true); let library = FixtureLibrary()
        let store = make(transport, library: library)
        try await ready(store)
        let work = store.works[0]; let pages = try await store.pages(for: work)
        store.requestDownload(work, page: pages[0], pageCount: pages.count)
        try await eventually { await transport.waitingForImage }
        store.cancelDownload(work.libraryID(page: 0))
        store.requestDownload(work, page: pages[0], pageCount: pages.count)
        try require(store.download(for: work, page: 0)?.status == .queued, "Retry did not wait for old transfer shutdown")
        await transport.releaseImage()
        try await eventually { store.download(for: work, page: 0)?.status == .completed }
        try require(library.imports == 1 && library.items.count == 1, "Cancelled transfer was imported")
        try require((store.download(for: work, page: 0)?.received ?? 0) <= Int64(png.count), "Old progress overwrote retry progress")
    }

    @MainActor static func rejectsUnverifiedPage() async throws {
        let transport = ControlledTransport(); let library = FixtureLibrary()
        let store = make(transport, library: library)
        try await ready(store)
        let work = store.works[0]
        let page = PixivPage(index: 0, width: 1, height: 1, previewURL: nil,
                             originalURL: URL(string: "https://i.pximg.net/unverified.png")!)
        store.requestDownload(work, page: page, pageCount: 1)
        try require(store.download(for: work, page: 0)?.status == .failed, "Unverified page entered the download queue")
        let count = await transport.imageRequests
        try require(library.imports == 0 && count == 0, "Unverified page fetched bytes")
    }

    @MainActor static func main() async throws {
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("cache-and-filters", cacheAndFilters), ("stale-listing", staleListing),
            ("late-sign-in", lateSignIn), ("mature-sanitization", matureSanitization),
            ("expired-restore", expiredRestore), ("failed-import-retry", failedImportRetry),
            ("cancelled-retry", cancelledRetry), ("reject-unverified-page", rejectsUnverifiedPage),
        ]
        for (name, test) in cases { try await test(); print("PASS " + name) }
        print("PASS: PixivStore \(cases.count) cases")
    }
}
