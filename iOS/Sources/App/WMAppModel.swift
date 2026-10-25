import Combine
import Foundation
import UIKit

/// A library scope shown in the sidebar. Workshop, export and settings are modal
/// tools rather than scopes, because they either need a selected wallpaper or own
/// their full screen.
enum WMSidebarSelection: Hashable {
    case all
    case favorites
    case collection(String)
    case playlist
}

struct WMExportTarget: Identifiable {
    let item: WallpaperItem
    let sourceURL: URL

    var id: UUID { item.id }
}

struct WMBackupExport: Identifiable {
    let id = UUID()
    let url: URL
}

/// Application state and every UI action.
///
/// Views only read published state and call these methods; they never mutate the
/// library directly and never perform disk or network work in `body`.
@MainActor
final class WMAppModel: ObservableObject {
    let library: LibraryStore
    let microphone = WMMicrophoneController()
    let microphoneResponse = MicrophoneAudioResponse()

    @Published var sidebarSelection: WMSidebarSelection = .all
    @Published var selectedItemID: WallpaperItem.ID?
    @Published var searchText = ""
    @Published var searchFocusRequest = 0

    @Published var isImporterPresented = false
    @Published var isSettingsPresented = false
    @Published var isWorkshopPresented = false
    @Published var isPlaylistEditorPresented = false
    @Published var isFullscreenPresented = false
    @Published var isCreatingCollection = false
    @Published var newCollectionName = ""

    @Published var errorMessage: String?
    @Published var exportTarget: WMExportTarget?
    @Published var backupExport: WMBackupExport?
    @Published var pendingDeletion: WallpaperItem?
    @Published var pendingCollectionDeletion: String?

    @Published private(set) var isPlaylistPlaying = false

    private var libraryObserver: AnyCancellable?
    private var microphoneObserver: AnyCancellable?
    private var settingsSaveTask: Task<Void, Never>?
    private var playlistTask: Task<Void, Never>?
    private var newCollectionTargetItemID: UUID?

    init(library: LibraryStore) {
        self.library = library
        // The app model is the single observable the views watch, so changes the
        // store publishes (imports, external edits) reach SwiftUI as well.
        libraryObserver = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        microphoneObserver = microphone.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        microphoneResponse.onFailure = { [weak self] failure in
            self?.presentError(failure.localizedDescription)
        }
        microphoneResponse.apply(settings: library.settings)
    }

    // MARK: - Library reading

    var selectedItem: WallpaperItem? {
        guard let id = selectedItemID else { return nil }
        return library.items.first { $0.id == id }
    }

    func item(withID id: UUID) -> WallpaperItem? {
        library.items.first { $0.id == id }
    }

    var sortedCollections: [String] {
        library.collections.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var playlistItems: [WallpaperItem] {
        let byID = Dictionary(library.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return library.playlistIDs.compactMap { byID[$0] }
    }

    var filteredItems: [WallpaperItem] {
        let base: [WallpaperItem]
        switch sidebarSelection {
        case .all:
            base = library.items.sorted(by: sortByAddedDate)
        case .favorites:
            base = library.items.filter(\.isFavorite).sorted(by: sortByAddedDate)
        case .collection(let name):
            base = library.items
                .filter { $0.collections.contains(name) }
                .sorted(by: sortByAddedDate)
        case .playlist:
            base = playlistItems
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.collections.contains { $0.localizedCaseInsensitiveContains(query) }
                || (item.workshopID?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sortByAddedDate(_ lhs: WallpaperItem, _ rhs: WallpaperItem) -> Bool {
        if lhs.addedAt == rhs.addedAt {
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return lhs.addedAt > rhs.addedAt
    }

    // MARK: - URLs

    /// The managed folder for an item. `LibraryStore.url(for:)` resolves the item's
    /// relative folder; the entry file is appended here because the preview views take
    /// the imported entry (scene JSON/package, video file, HTML page or image).
    func playbackURL(for item: WallpaperItem) -> URL {
        let base = library.url(for: item)
        let entry = item.entryFile
        guard !entry.isEmpty else { return base }
        if entry.hasPrefix("/") {
            return URL(fileURLWithPath: entry)
        }
        return base.appendingPathComponent(entry)
    }

    // MARK: - Navigation

    func selectScope(_ selection: WMSidebarSelection) {
        guard selection != sidebarSelection else { return }
        if case .collection(let name) = selection, !library.collections.contains(name) {
            pausePlaylist()
            sidebarSelection = .all
            selectedItemID = nil
            return
        }
        pausePlaylist()
        sidebarSelection = selection
        selectedItemID = nil
    }

    func selectItem(_ item: WallpaperItem) {
        selectedItemID = item.id
    }

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    // MARK: - Import

    func presentImporter() {
        isImporterPresented = true
    }

    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                await self.library.importURL(url)
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if self.selectedItemID == nil, let first = self.filteredItems.first {
                self.selectedItemID = first.id
            }
        }
    }

    // MARK: - Favorites

    func toggleFavorite(_ item: WallpaperItem) {
        library.toggleFavorite(item)
    }

    func toggleFavoriteOnSelection() {
        guard let item = selectedItem else { return }
        library.toggleFavorite(item)
    }

    // MARK: - Collections

    var canCreateCollection: Bool {
        let trimmed = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !library.collections.contains { $0.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    func beginCreatingCollection(addingItemID: UUID? = nil) {
        newCollectionName = ""
        newCollectionTargetItemID = addingItemID
        isCreatingCollection = true
    }

    func cancelNewCollection() {
        isCreatingCollection = false
        newCollectionName = ""
        newCollectionTargetItemID = nil
    }

    func commitNewCollection() {
        guard canCreateCollection else { return }
        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = newCollectionTargetItemID
        library.collections.append(name)
        if let targetID,
           var updated = library.items.first(where: { $0.id == targetID }),
           !updated.collections.contains(name) {
            updated.collections.append(name)
            library.update(updated)
        }
        persistLibrary()
        newCollectionName = ""
        newCollectionTargetItemID = nil
        isCreatingCollection = false
        if targetID == nil {
            sidebarSelection = .collection(name)
            selectedItemID = nil
        } else if let targetID {
            selectedItemID = targetID
        }
    }

    func requestDeleteCollection(_ name: String) {
        pendingCollectionDeletion = name
    }

    func deleteCollection(_ name: String) {
        pendingCollectionDeletion = nil
        // Strip the name from every wallpaper first, then from the collection list, so
        // a store that derives its collection list from items settles on the same answer.
        for item in library.items where item.collections.contains(name) {
            var updated = item
            updated.collections.removeAll { $0 == name }
            library.update(updated)
        }
        library.collections.removeAll { $0 == name }
        persistLibrary()
        if sidebarSelection == .collection(name) {
            pausePlaylist()
            sidebarSelection = .all
            selectedItemID = nil
        }
    }

    func setCollectionMembership(_ name: String, isOn: Bool, itemID: UUID) {
        guard var updated = library.items.first(where: { $0.id == itemID }) else { return }
        if isOn {
            guard !updated.collections.contains(name) else { return }
            updated.collections.append(name)
        } else {
            guard updated.collections.contains(name) else { return }
            updated.collections.removeAll { $0 == name }
        }
        library.update(updated)
    }

    func toggleCollectionMembership(_ name: String, for item: WallpaperItem) {
        setCollectionMembership(name, isOn: !item.collections.contains(name), itemID: item.id)
    }

    // MARK: - Wallpaper properties

    func setPropertyValue(for itemID: UUID, key: String, value: JSONValue) {
        guard var updated = library.items.first(where: { $0.id == itemID }),
              var property = updated.properties[key] else {
            return
        }
        property.value = value
        updated.properties[key] = property
        library.update(updated)
    }

    // MARK: - Playlist

    var isPlaylistContext: Bool {
        if case .playlist = sidebarSelection { return true }
        return false
    }

    var canPlayPlaylist: Bool {
        isPlaylistContext && playlistItems.count > 1
    }

    var currentPlaylistPosition: Int? {
        guard let id = selectedItemID else { return nil }
        return playlistItems.firstIndex { $0.id == id }
    }

    func isInPlaylist(_ item: WallpaperItem) -> Bool {
        library.playlistIDs.contains(item.id)
    }

    func addToPlaylist(_ item: WallpaperItem) {
        guard !library.playlistIDs.contains(item.id) else { return }
        library.playlistIDs.append(item.id)
        persistLibrary()
    }

    func removeFromPlaylist(_ item: WallpaperItem) {
        guard library.playlistIDs.contains(item.id) else { return }
        library.playlistIDs.removeAll { $0 == item.id }
        persistLibrary()
        if playlistItems.count < 2 {
            pausePlaylist()
        }
    }

    func togglePlaylistMembership(_ item: WallpaperItem) {
        if isInPlaylist(item) {
            removeFromPlaylist(item)
        } else {
            addToPlaylist(item)
        }
    }

    func movePlaylist(from source: IndexSet, to destination: Int) {
        var ids = library.playlistIDs
        let valid = source.filter { ids.indices.contains($0) }.sorted()
        guard !valid.isEmpty else { return }
        let moving = valid.map { ids[$0] }
        let removedBefore = valid.filter { $0 < destination }.count
        for index in valid.reversed() {
            ids.remove(at: index)
        }
        let insertion = max(0, min(ids.count, destination - removedBefore))
        ids.insert(contentsOf: moving, at: insertion)
        library.playlistIDs = ids
        persistLibrary()
    }

    func deletePlaylistItems(at offsets: IndexSet) {
        var ids = library.playlistIDs
        for index in offsets.filter({ ids.indices.contains($0) }).sorted(by: >) {
            ids.remove(at: index)
        }
        library.playlistIDs = ids
        persistLibrary()
        if playlistItems.count < 2 {
            pausePlaylist()
        }
    }

    func startPlaylistEditor() {
        isPlaylistEditorPresented = true
    }

    func togglePlaylistPlayback() {
        guard canPlayPlaylist else { return }
        if isPlaylistPlaying {
            pausePlaylist()
        } else {
            startPlaylist()
        }
    }

    func startPlaylist() {
        guard canPlayPlaylist else { return }
        isPlaylistPlaying = true
        if currentPlaylistPosition == nil {
            selectedItemID = playlistItems.first?.id
        }
        playlistTask?.cancel()
        playlistTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = max(2, self.library.settings.playlistInterval)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                self.advancePlaylist(by: 1)
            }
        }
    }

    func pausePlaylist() {
        isPlaylistPlaying = false
        playlistTask?.cancel()
        playlistTask = nil
    }

    func advancePlaylist(by offset: Int) {
        guard canPlayPlaylist else { return }
        let items = playlistItems
        guard !items.isEmpty else { return }
        let current = currentPlaylistPosition ?? (offset >= 0 ? -1 : 0)
        var next = current + offset
        if next >= items.count { next = 0 }
        if next < 0 { next = items.count - 1 }
        selectedItemID = items[next].id
    }

    // MARK: - Settings

    func updateSettings(_ mutate: (inout PlaybackSettings) -> Void) {
        var settings = library.settings
        mutate(&settings)
        library.settings = settings
        microphoneResponse.apply(settings: settings)
        scheduleSettingsSave()
    }

    private func scheduleSettingsSave() {
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try self.library.save()
            } catch {
                self.presentError(error.localizedDescription)
            }
        }
    }

    private func persistLibrary() {
        do {
            try library.save()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Microphone

    func refreshMicrophonePermission() {
        microphone.refresh()
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        guard enabled else {
            updateSettings { $0.microphoneEnabled = false }
            return
        }
        if microphone.permission == .granted {
            updateSettings { $0.microphoneEnabled = true }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.microphone.requestAccess()
            self.microphoneResponse.refreshPermission()
            if granted {
                self.updateSettings { $0.microphoneEnabled = true }
            } else {
                self.updateSettings { $0.microphoneEnabled = false }
                self.presentError(WMLocalized.string("settings.microphone.denied.message"))
            }
        }
    }

    func openMicrophoneSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Preview, export and backup

    func toggleFullscreen() {
        guard selectedItem != nil else { return }
        isFullscreenPresented.toggle()
    }

    func beginExport(_ item: WallpaperItem) {
        exportTarget = WMExportTarget(item: item, sourceURL: library.url(for: item))
    }

    func exportBackup() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = "WallpaperMachine-\(formatter.string(from: Date()))"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("wmbackup")
        do {
            try library.exportBackup(to: url)
            backupExport = WMBackupExport(url: url)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func finishBackupExport() {
        if let export = backupExport {
            try? FileManager.default.removeItem(at: export.url)
        }
        backupExport = nil
    }

    func restoreBackup(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try library.restoreBackup(from: url)
            pausePlaylist()
            sidebarSelection = .all
            selectedItemID = nil
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Removal

    func requestRemoval(_ item: WallpaperItem) {
        pendingDeletion = item
    }

    func remove(_ item: WallpaperItem) {
        pendingDeletion = nil
        do {
            try library.remove(item)
            library.playlistIDs.removeAll { $0 == item.id }
            if selectedItemID == item.id {
                selectedItemID = nil
            }
            if playlistItems.count < 2 {
                pausePlaylist()
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Errors

    func presentError(_ message: String) {
        errorMessage = message
    }

    func clearError() {
        errorMessage = nil
    }
}
