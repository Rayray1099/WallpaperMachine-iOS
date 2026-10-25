// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import WallpaperMachineIOS

/// Shared fixtures for the iOS unit tests. Every fixture lives in the process's
/// temporary directory and is removed in teardown; tests never touch the
/// installed app's Documents or any user asset.
enum IOSTestSupport {
    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallpaperMachineIOSTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    static func makeSceneFolder(in parent: URL, name: String = "Scene") throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try write("{}", to: folder.appendingPathComponent("scene.json"))
        try write("fixture", to: folder.appendingPathComponent("assets/texture.txt"))
        return folder
    }

    static func makeItem(
        title: String = "Fixture",
        kind: WallpaperKind = .scene,
        relativePath: String = "Fixture",
        entryFile: String = "scene.json",
        isFavorite: Bool = false
    ) -> WallpaperItem {
        WallpaperItem(
            title: title,
            kind: kind,
            relativePath: relativePath,
            entryFile: entryFile,
            isFavorite: isFavorite,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

extension XCTestCase {
    /// A unique temporary directory, removed when the test ends.
    func makeTemporaryDirectory() throws -> URL {
        let directory = try IOSTestSupport.makeDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    /// Asserts `candidate` is contained in `root` after resolving symlinks.
    func assertContained(_ candidate: URL, in root: URL, file: StaticString = #filePath,
                         line: UInt = #line) {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(
            candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/"),
            "\(candidatePath) is outside \(rootPath)", file: file, line: line)
    }
}
