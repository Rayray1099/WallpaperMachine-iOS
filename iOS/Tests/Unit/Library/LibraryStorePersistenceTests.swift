// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
import ZIPFoundation
@testable import WallpaperMachineIOS

/// Persistence must round-trip the documented model through save/reload and
/// backup/restore, and must reject corrupt backups without destroying live state.
@MainActor
final class LibraryStorePersistenceTests: XCTestCase {
    private func makeStore(_ root: URL) -> LibraryStore {
        LibraryStore(rootURL: root)
    }

    private func seed(_ store: LibraryStore, in root: URL) throws -> WallpaperItem {
        var item = IOSTestSupport.makeItem(relativePath: "Fixture")
        item.relativePath = "Wallpapers/" + item.id.uuidString
        let folder = root.appendingPathComponent(item.relativePath, isDirectory: true)
        try IOSTestSupport.write("{}", to: folder.appendingPathComponent(item.entryFile))
        store.items = [item]
        store.collections = ["Night"]
        store.playlistIDs = [item.id]
        store.settings.volume = 0.25
        store.settings.framesPerSecond = 30
        return item
    }

    func testSaveAndReloadKeepsItemsCollectionsPlaylistsAndSettings() throws {
        let root = try makeTemporaryDirectory()
        let store = makeStore(root)
        let item = try seed(store, in: root)
        try store.save()

        let reloaded = makeStore(root)
        XCTAssertEqual(reloaded.items, [item])
        XCTAssertEqual(reloaded.collections, ["Night"])
        XCTAssertEqual(reloaded.playlistIDs, [item.id])
        XCTAssertEqual(reloaded.settings.volume, 0.25, accuracy: 0.0001)
        XCTAssertEqual(reloaded.settings.framesPerSecond, 30)
        XCTAssertNil(reloaded.errorMessage)
    }

    func testFavoriteAndEditsSurviveReload() throws {
        let root = try makeTemporaryDirectory()
        let store = makeStore(root)
        let item = try seed(store, in: root)
        store.toggleFavorite(item)
        var edited = store.items[0]
        edited.title = "Renamed"
        edited.collections = ["Night", "Rain"]
        store.update(edited)
        try store.save()

        let reloaded = makeStore(root)
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertTrue(reloaded.items[0].isFavorite)
        XCTAssertEqual(reloaded.items[0].title, "Renamed")
        XCTAssertEqual(reloaded.items[0].collections, ["Night", "Rain"])
    }

    func testExportAndRestoreBackupRoundTrip() throws {
        let sourceRoot = try makeTemporaryDirectory()
        let source = makeStore(sourceRoot)
        let item = try seed(source, in: sourceRoot)
        let backup = try makeTemporaryDirectory().appendingPathComponent("library-backup.json")
        try source.exportBackup(to: backup)

        let restoredRoot = try makeTemporaryDirectory()
        let restored = makeStore(restoredRoot)
        try restored.restoreBackup(from: backup)

        XCTAssertEqual(restored.items.count, 1)
        XCTAssertEqual(restored.items[0].id, item.id)
        XCTAssertEqual(restored.items[0].title, item.title)
        XCTAssertEqual(restored.collections, ["Night"])
        XCTAssertEqual(restored.playlistIDs, [item.id])
        XCTAssertEqual(restored.settings.volume, 0.25, accuracy: 0.0001)
        assertContained(restored.url(for: restored.items[0]), in: restoredRoot)
    }

    func testRestoreInvalidJSONThrowsAndKeepsLiveState() throws {
        let root = try makeTemporaryDirectory()
        let store = makeStore(root)
        let item = try seed(store, in: root)
        let invalid = try makeTemporaryDirectory().appendingPathComponent("broken.json")
        try IOSTestSupport.write("this is not a library backup", to: invalid)

        XCTAssertThrowsError(try store.restoreBackup(from: invalid))
        XCTAssertEqual(store.items, [item], "a failed restore must not clear the live library")
        XCTAssertEqual(store.collections, ["Night"])
    }

    func testRestoreUnsupportedVersionThrows() throws {
        let root = try makeTemporaryDirectory()
        let store = makeStore(root)
        let _ = try seed(store, in: root)
        let backup = try makeTemporaryDirectory().appendingPathComponent("future.json")
        try store.exportBackup(to: backup)

        let unpacked = try makeTemporaryDirectory().appendingPathComponent("unpacked")
        try FileManager.default.unzipItem(at: backup, to: unpacked)
        let manifest = unpacked.appendingPathComponent("library.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        let future = try makeTemporaryDirectory().appendingPathComponent("future-999.wmbackup")
        try FileManager.default.zipItem(at: unpacked, to: future, shouldKeepParent: false)

        XCTAssertThrowsError(try store.restoreBackup(from: future))
        XCTAssertEqual(store.items.count, 1)
    }

    func testRemoveDeletesTheManagedFolderAndItem() throws {
        let root = try makeTemporaryDirectory()
        let store = makeStore(root)
        let item = try seed(store, in: root)
        let folder = store.url(for: item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        try store.remove(item)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(store.playlistIDs.contains(item.id),
                       "a removed item must not remain in the playlist")
    }

    func testCorruptOnDiskManifestDoesNotCrashAndReports() throws {
        let root = try makeTemporaryDirectory()
        try IOSTestSupport.write("not json", to: root.appendingPathComponent("library.json"))
        let store = makeStore(root)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.errorMessage,
                        "an unreadable manifest must be reported, not silently ignored")
    }
}
