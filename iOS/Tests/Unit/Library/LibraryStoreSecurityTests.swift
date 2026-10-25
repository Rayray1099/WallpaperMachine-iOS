// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
import ZIPFoundation
@testable import WallpaperMachineIOS

/// Security behaviour a consumer can observe: unsafe item paths never resolve
/// outside the library root, imports refuse symlinks, and backups refuse unsafe
/// manifests instead of writing outside the managed folder.
@MainActor
final class LibraryStoreSecurityTests: XCTestCase {
    private func makeStore() throws -> (LibraryStore, URL) {
        let root = try makeTemporaryDirectory()
        return (LibraryStore(rootURL: root), root)
    }

    func testURLForItemStaysInsideTheLibraryRoot() throws {
        let (store, root) = try makeStore()
        let item = IOSTestSupport.makeItem(relativePath: "Fixture")
        assertContained(store.url(for: item), in: root)
    }

    func testURLForTraversalPathDoesNotEscapeTheLibraryRoot() throws {
        let (store, root) = try makeStore()
        let escape = IOSTestSupport.makeItem(relativePath: "../escape")
        let resolved = store.url(for: escape)
        assertContained(resolved, in: root)
    }

    func testURLForAbsolutePathDoesNotEscapeTheLibraryRoot() throws {
        let (store, root) = try makeStore()
        let escape = IOSTestSupport.makeItem(relativePath: "/tmp/wm-qa-escape")
        assertContained(store.url(for: escape), in: root)
    }

    func testPreviewURLForUnsafeItemIsNilOrContained() throws {
        let (store, root) = try makeStore()
        var item = IOSTestSupport.makeItem(relativePath: "../escape")
        item.previewFile = "../../secret.png"
        if let preview = store.previewURL(for: item) {
            assertContained(preview, in: root)
        }
    }

    func testImportRefusesSymbolicLinksThatEscapeTheSource() async throws {
        let (store, root) = try makeStore()
        let source = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        try IOSTestSupport.write("secret", to: outside.appendingPathComponent("secret.txt"))
        try IOSTestSupport.write("{}", to: source.appendingPathComponent("scene.json"))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("assets"), withDestinationURL: outside)

        await store.importURL(source)

        XCTAssertNotNil(store.errorMessage,
                        "an import containing an escaping symlink must report a refusal")
        for item in store.items {
            assertContained(store.url(for: item), in: root)
        }
        assertNoSymlinks(in: root)
    }

    func testImportRefusesEmptyFolder() async throws {
        let (store, root) = try makeStore()
        let source = try makeTemporaryDirectory()
        await store.importURL(source)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        assertNoSymlinks(in: root)
    }

    func testImportDestinationIsContainedAndUsesARelativePath() async throws {
        let (store, root) = try makeStore()
        let source = try IOSTestSupport.makeSceneFolder(in: try makeTemporaryDirectory())
        await store.importURL(source)
        guard let item = store.items.first else {
            XCTFail("a scene folder with scene.json should import: \(store.errorMessage ?? "no error")")
            return
        }
        XCTAssertFalse(item.relativePath.hasPrefix("/"), "stored path must be relative")
        XCTAssertFalse(item.relativePath.contains(".."))
        assertContained(store.url(for: item), in: root)
        assertContained(store.url(for: item).appendingPathComponent(item.entryFile), in: root)
        assertNoSymlinks(in: root)
    }

    func testRestoreBackupRejectsTraversalRelativePath() throws {
        let (store, root) = try makeStore()
        var manifest = LibraryManifest()
        manifest.items = [IOSTestSupport.makeItem(relativePath: "../escape")]
        let staged = try makeTemporaryDirectory()
        try JSONEncoder().encode(manifest).write(to: staged.appendingPathComponent("library.json"))
        let backupURL = try makeTemporaryDirectory().appendingPathComponent("traversal.wmbackup")
        // A valid ZIP with an unsafe manifest exercises path validation, rather
        // than merely failing because raw JSON is not the backup archive format.
        try FileManager.default.zipItem(at: staged, to: backupURL, shouldKeepParent: false)

        XCTAssertThrowsError(try store.restoreBackup(from: backupURL),
                             "a backup item that escapes the library root must be refused")
        for item in store.items {
            assertContained(store.url(for: item), in: root)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    func testExportBackupRefusesTraversalItem() throws {
        let (store, root) = try makeStore()
        store.items = [IOSTestSupport.makeItem(relativePath: "../escape")]
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("backup-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        XCTAssertThrowsError(try store.exportBackup(to: destination),
                             "exporting an item outside the library must be refused")
    }

    private func assertNoSymlinks(in root: URL,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys) else { return }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            XCTAssertNotEqual(values?.isSymbolicLink, true,
                              "import left a symlink at \(url.path)", file: file, line: line)
        }
    }
}
