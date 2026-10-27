// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation

@MainActor
protocol PixivLibraryAccess: AnyObject {
    func installedPixivItem(workID: String, page: Int) -> WallpaperItem?
    func importPixivProject(_ folder: URL) async throws
}

struct PixivDownloadState: Identifiable, Equatable {
    enum Status: Equatable { case queued, downloading, importing, completed, cancelled, failed }
    let id: String
    var status: Status
    var received: Int64 = 0
    var expected: Int64?
    var errorMessage: String?
    var progress: Double? {
        guard let expected, expected > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(expected)))
    }
}

/// Serializes keychain changes so a late sign-in cannot restore a signed-out session.
private actor PixivSessionVault {
    let storage: any PixivSessionStoring
    private var revision = 0
    init(_ storage: any PixivSessionStoring) { self.storage = storage }
    func load() -> String? { storage.load() }
    func save(_ value: String, revision candidate: Int) throws {
        guard candidate >= revision else { return }
        revision = candidate
        try storage.save(value)
    }
    func remove(revision candidate: Int) {
        guard candidate >= revision else { return }
        revision = candidate
        storage.remove()
    }
}

@MainActor @Observable
final class PixivStore {
    private(set) var query = PixivQuery()
    private(set) var works: [PixivWork] = []
    private(set) var page = 1
    private(set) var totalPages = 1
    private(set) var totalCount = 0
    private(set) var hiddenCount = 0
    private(set) var isLoading = false
    var errorMessage: String?
    private(set) var account: PixivAccount?
    private(set) var isCheckingAccount = false
    private(set) var sessionWarning: String?
    private(set) var downloads: [String: PixivDownloadState] = [:]
    private var libraryRevision = 0

    @ObservationIgnored private let library: any PixivLibraryAccess
    @ObservationIgnored private let service: PixivService
    @ObservationIgnored private let vault: PixivSessionVault
    @ObservationIgnored private var session: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var authenticationRevision = 0
    @ObservationIgnored private var requestRevision = 0
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var cache: [Int: PixivResultPage] = [:]
    @ObservationIgnored private var cacheOrder: [Int] = []
    @ObservationIgnored private var pageCache: [String: [PixivPage]] = [:]
    @ObservationIgnored private var pageCacheOrder: [String] = []
    @ObservationIgnored private var downloadQueue: [DownloadRequest] = []
    @ObservationIgnored private var activeDownload: Task<Void, Never>?
    @ObservationIgnored private var activeDownloadID: String?
    @ObservationIgnored private var downloadGenerations: [String: UUID] = [:]

    private struct DownloadRequest {
        let work: PixivWork
        let page: PixivPage
        let count: Int
        let generation = UUID()
        var id: String { work.libraryID(page: page.index) }
    }

    init(library: any PixivLibraryAccess, service: PixivService = PixivService(),
         sessions: any PixivSessionStoring = KeychainPixivSessionStore()) {
        self.library = library
        self.service = service
        self.vault = PixivSessionVault(sessions)
    }

    var canShowMature: Bool { account != nil && account?.showsR18 != false }

    func start() async {
        guard !started else { return }
        started = true
        let revision = authenticationRevision
        isCheckingAccount = true
        if let saved = await vault.load(), revision == authenticationRevision {
            await adopt(saved, saving: false, revision: revision)
        }
        if revision == authenticationRevision {
            isCheckingAccount = false
            if !isLoading { refresh() }
        }
    }

    func signIn(session candidate: String) {
        authenticationRevision += 1
        let revision = authenticationRevision
        accountTask?.cancel()
        isCheckingAccount = true
        sessionWarning = nil
        accountTask = Task { [weak self] in
            guard let self else { return }
            await self.adopt(candidate, saving: true, revision: revision)
        }
    }

    private func adopt(_ candidate: String, saving: Bool, revision: Int) async {
        do {
            guard let verified = try await service.account(session: candidate) else {
                throw PixivFailure(code: .signedOut)
            }
            guard revision == authenticationRevision, !Task.isCancelled else { return }
            if saving {
                do { try await vault.save(candidate, revision: revision) }
                catch {
                    guard revision == authenticationRevision else { return }
                    sessionWarning = PixivFailure(code: .notSaved).localizedDescription
                }
            }
            guard revision == authenticationRevision, !Task.isCancelled else { return }
            session = candidate
            account = verified
            isCheckingAccount = false
            resetCaches()
            query = query.sanitized(signedIn: canShowMature)
            refresh()
        } catch {
            guard revision == authenticationRevision, !Task.isCancelled else { return }
            isCheckingAccount = false
            sessionWarning = error.localizedDescription
            if let failure = error as? PixivFailure, failure.code == .signedOut {
                session = nil
                account = nil
                await vault.remove(revision: revision)
                resetCaches()
                query = query.sanitized(signedIn: false)
                refresh()
            }
        }
    }

    func signOut() {
        authenticationRevision += 1
        let revision = authenticationRevision
        accountTask?.cancel()
        accountTask = nil
        session = nil
        account = nil
        isCheckingAccount = false
        sessionWarning = nil
        for request in downloadQueue { downloads[request.id]?.status = .cancelled }
        downloadQueue.removeAll()
        if let id = activeDownloadID, downloads[id]?.status != .importing { cancelDownload(id) }
        Task { await vault.remove(revision: revision) }
        resetCaches()
        query = query.sanitized(signedIn: false)
        refresh()
    }

    func apply(_ candidate: PixivQuery, refresh force: Bool = false) {
        let next = candidate.sanitized(signedIn: canShowMature)
        let sameListing = next.listing == query.listing
        query = next
        if !sameListing || force { resetCaches() }
        if sameListing, !force, let cached = cache[page] { publish(cached) }
        else { loadPage(1) }
    }

    func refresh() {
        resetCaches()
        loadPage(1)
    }

    func loadPage(_ number: Int) {
        let number = min(max(1, number), max(1, totalPages))
        browseTask?.cancel()
        requestRevision += 1
        let revision = requestRevision
        page = number
        errorMessage = nil
        if let cached = cache[number] { publish(cached); isLoading = false; return }
        works = []
        hiddenCount = 0
        isLoading = true
        let listing = query.listing
        let credential = session
        browseTask = Task { [weak self, service] in
            do {
                let result = try await service.page(number, of: listing, session: credential)
                guard let self, self.requestRevision == revision, !Task.isCancelled else { return }
                self.cache[number] = result
                self.cacheOrder.removeAll { $0 == number }
                self.cacheOrder.append(number)
                while self.cacheOrder.count > 12 {
                    self.cache.removeValue(forKey: self.cacheOrder.removeFirst())
                }
                self.publish(result)
                self.isLoading = false
            } catch {
                guard let self, self.requestRevision == revision, !Task.isCancelled else { return }
                self.isLoading = false
                self.works = []
                self.hiddenCount = 0
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func resetCaches() {
        browseTask?.cancel()
        requestRevision += 1
        cache.removeAll()
        cacheOrder.removeAll()
        pageCache.removeAll()
        pageCacheOrder.removeAll()
        works = []
        totalPages = 1
        totalCount = 0
        hiddenCount = 0
    }

    private func publish(_ result: PixivResultPage) {
        works = result.works.filter(query.admits)
        page = result.page
        totalPages = max(1, result.totalPages)
        totalCount = result.totalCount
        hiddenCount = result.works.count - works.count
    }

    func pages(for work: PixivWork) async throws -> [PixivPage] {
        try requireAccess(to: work)
        if let cached = pageCache[work.id] { return cached }
        let revision = authenticationRevision
        let result = try await service.pages(ofWork: work.id, session: session)
        try Task.checkCancellation()
        guard revision == authenticationRevision else { throw PixivFailure(code: .signedOut) }
        try requireAccess(to: work)
        pageCache[work.id] = result
        pageCacheOrder.removeAll { $0 == work.id }
        pageCacheOrder.append(work.id)
        while pageCacheOrder.count > 24 { pageCache.removeValue(forKey: pageCacheOrder.removeFirst()) }
        return result
    }

    private func requireAccess(to work: PixivWork) throws {
        guard work.rating != .grotesque else { throw PixivFailure(code: .unreadable) }
        if work.rating == .mature, !canShowMature { throw PixivFailure(code: .signedOut) }
    }

    func installedItem(for work: PixivWork, page: Int) -> WallpaperItem? {
        _ = libraryRevision
        return library.installedPixivItem(workID: work.id, page: page)
    }

    func libraryDidChange() { libraryRevision += 1 }

    func download(for work: PixivWork, page: Int) -> PixivDownloadState? {
        downloads[work.libraryID(page: page)]
    }

    func requestDownload(_ work: PixivWork, page: PixivPage, pageCount: Int) {
        let request = DownloadRequest(work: work, page: page, count: pageCount)
        if let status = downloads[request.id]?.status,
           status == .queued || status == .downloading || status == .importing { return }
        if installedItem(for: work, page: page.index) != nil {
            downloads[request.id] = PixivDownloadState(id: request.id, status: .completed)
            return
        }
        do {
            try requireAccess(to: work)
            guard let verified = pageCache[work.id], verified.contains(page), pageCount == verified.count,
                  downloadQueue.count < 24 else { throw PixivFailure(code: .unreadable) }
            if downloads.count >= 64 {
                for id in downloads.keys.sorted() where downloads.count >= 64 {
                    if let status = downloads[id]?.status,
                       status == .completed || status == .cancelled || status == .failed {
                        downloads.removeValue(forKey: id)
                        downloadGenerations.removeValue(forKey: id)
                    }
                }
            }
            downloads[request.id] = PixivDownloadState(id: request.id, status: .queued)
            downloadGenerations[request.id] = request.generation
            downloadQueue.append(request)
            pumpDownloads()
        } catch {
            downloads[request.id] = PixivDownloadState(id: request.id, status: .failed, errorMessage: error.localizedDescription)
        }
    }

    func cancelDownload(_ id: String) {
        guard let status = downloads[id]?.status, status == .queued || status == .downloading else { return }
        downloadQueue.removeAll { $0.id == id }
        downloads[id]?.status = .cancelled
        if activeDownloadID == id { activeDownload?.cancel() }
    }

    /// One transfer/import at a time bounds image memory and shares the library's import lock.
    private func pumpDownloads() {
        guard activeDownload == nil, !downloadQueue.isEmpty else { return }
        let request = downloadQueue.removeFirst()
        activeDownloadID = request.id
        downloads[request.id]?.status = .downloading
        activeDownload = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(request)
            self.activeDownload = nil
            self.activeDownloadID = nil
            self.pumpDownloads()
        }
    }

    private func runDownload(_ request: DownloadRequest) async {
        var staging: URL?
        var finalStatus = PixivDownloadState.Status.failed
        var finalError: String?
        do {
            try requireAccess(to: request.work)
            let data = try await service.original(of: request.page) { [weak self] received, expected in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadGenerations[request.id] == request.generation,
                          self.downloads[request.id]?.status == .downloading else { return }
                    self.downloads[request.id]?.received = received
                    self.downloads[request.id]?.expected = expected
                }
            }
            try Task.checkCancellation()
            try requireAccess(to: request.work)
            downloads[request.id]?.status = .importing
            let folder = try await Task.detached(priority: .userInitiated) {
                try PixivLibraryProject.stage(data, work: request.work, page: request.page, pageCount: request.count)
            }.value
            staging = folder
            try Task.checkCancellation()
            try await library.importPixivProject(folder)
            guard installedItem(for: request.work, page: request.page.index) != nil
            else { throw PixivFailure(code: .unreadable) }
            finalStatus = .completed
        } catch {
            if Task.isCancelled || error is CancellationError {
                finalStatus = .cancelled
            } else {
                finalError = error.localizedDescription
            }
        }
        if let folder = staging {
            await Task.detached { try? FileManager.default.removeItem(at: folder) }.value
        }
        guard downloadGenerations[request.id] == request.generation else { return }
        downloads[request.id]?.status = finalStatus
        downloads[request.id]?.errorMessage = finalError
    }
}
