// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

@MainActor
public final class LibraryStore: ObservableObject {
    @Published public var items: [WallpaperItem] = []
    @Published public var errorMessage: String?
    @Published public var isImporting = false
    @Published public var collections: [String] = []
    @Published public var playlistIDs: [UUID] = []
    @Published public var settings = PlaybackSettings()
    public let rootURL: URL
    private let repository: LibraryRepository

    public convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // UI tests receive an isolated library. Never read or alter the installed user's collection.
        let environment = ProcessInfo.processInfo.environment
        let override = environment["WALLPAPER_MACHINE_HOME"]
        let root: URL
        if let testID = environment["WALLPAPER_MACHINE_UI_TEST_ID"].flatMap(UUID.init(uuidString:)) {
            // The UI runner and app have different containers. Resolve the test
            // root inside this app, not under a path supplied by the runner.
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("wm-ui-test-" + testID.uuidString, isDirectory: true)
        } else {
            root = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? base.appendingPathComponent("WallpaperMachine", isDirectory: true)
        }
        self.init(rootURL: root)
    }
    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        self.repository = LibraryRepository(rootURL: self.rootURL)
        do { adopt(try repository.load()) }
        catch { errorMessage = error.localizedDescription }
    }

    public func url(for item: WallpaperItem) -> URL {
        // A tampered metadata item must never escape into another app/user folder.
        (try? AssetPath.resolve(item.relativePath, inside: rootURL))
            ?? rootURL.appendingPathComponent(".invalid-item")
    }
    public func previewURL(for item: WallpaperItem) -> URL? {
        guard let preview = item.previewFile else { return nil }
        return try? AssetPath.resolve(preview, inside: url(for: item))
    }
    public func importURL(_ url: URL) async {
        guard !isImporting else { errorMessage = "An import is already in progress."; return }
        isImporting = true; defer { isImporting = false }
        let root = rootURL; let original = snapshot()
        do {
            let manifest = try await Task.detached(priority: .userInitiated) {
                try LibraryRepository(rootURL: root).importWallpaper(from: url, into: original)
            }.value
            adopt(manifest)
        } catch { errorMessage = error.localizedDescription }
    }
    public func toggleFavorite(_ item: WallpaperItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isFavorite.toggle(); persistOrReport()
    }
    public func update(_ item: WallpaperItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard items[index].relativePath == item.relativePath, items[index].entryFile == item.entryFile else {
            errorMessage = "A wallpaper update cannot change its managed asset path."; return
        }
        items[index] = item; persistOrReport()
    }
    public func remove(_ item: WallpaperItem) throws {
        guard !isImporting else { throw LibraryError.unsupported("Import in progress") }
        adopt(try repository.remove(item, from: snapshot()))
    }
    public func save() throws {
        guard !isImporting else { return }
        settings.volume = min(1, max(0, settings.volume))
        settings.framesPerSecond = min(120, max(1, settings.framesPerSecond))
        settings.renderScale = min(2, max(0.1, settings.renderScale))
        settings.playlistInterval = max(5, settings.playlistInterval)
        collections = Array(Set(collections.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
        playlistIDs = playlistIDs.filter { id in items.contains { $0.id == id } }
        try repository.save(snapshot())
    }
    public func exportBackup(to destination: URL) throws { try repository.exportBackup(snapshot(), to: destination) }
    public func restoreBackup(from source: URL) throws {
        guard !isImporting else { throw LibraryError.unsupported("Import in progress") }
        adopt(try repository.restoreBackup(from: source))
    }
    private func snapshot() -> LibraryManifest {
        var manifest = LibraryManifest()
        manifest.items = items; manifest.collections = collections
        manifest.playlistIDs = playlistIDs; manifest.settings = settings
        return manifest
    }
    private func adopt(_ manifest: LibraryManifest) {
        items = manifest.items; collections = manifest.collections
        playlistIDs = manifest.playlistIDs; settings = manifest.settings
    }
    private func persistOrReport() { do { try save() } catch { errorMessage = error.localizedDescription } }
}
