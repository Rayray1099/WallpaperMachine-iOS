// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import WallpaperMachineIOS

/// Path containment is the security boundary for imported assets, previews,
/// backup and restore. These tests are independent of the store's persistence
/// format: they assert what a consumer can observe (throws / contained URL).
final class AssetPathSecurityTests: XCTestCase {
    private func rejects(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AssetPath.validate(path),
                             "\(path) should be rejected", file: file, line: line)
    }

    func testTraversalAndAbsolutePathsAreRejected() {
        rejects("../escape")
        rejects("a/../b")
        rejects("a/./b")
        rejects("a//b")
        rejects("/etc/passwd")
        rejects("C:/Users/secret")
        rejects("C:\\Users\\secret")
        rejects("..\\escape")
        rejects("")
        rejects("a/\0b")
    }

    func testOrdinaryRelativePathsAreAccepted() throws {
        XCTAssertNoThrow(try AssetPath.validate("Aurora-7f9a"))
        XCTAssertNoThrow(try AssetPath.validate("Aurora-7f9a/scene.json"))
        XCTAssertNoThrow(try AssetPath.validate("nested/dir/texture.png"))
    }

    func testResolveKeepsOrdinaryPathsInsideRoot() throws {
        let root = try makeTemporaryDirectory()
        let resolved = try AssetPath.resolve("Aurora/scene.json", inside: root)
        assertContained(resolved, in: root)
        XCTAssertEqual(resolved.lastPathComponent, "scene.json")
    }

    func testResolveRejectsTraversalEvenWhenTheSiblingExists() throws {
        let root = try makeTemporaryDirectory()
        try IOSTestSupport.write("outside", to: root.deletingLastPathComponent()
            .appendingPathComponent("outside.txt"))
        XCTAssertThrowsError(try AssetPath.resolve("../outside.txt", inside: root))
    }

    func testResolveRejectsSymbolicLinkThatEscapesRoot() throws {
        let root = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        try IOSTestSupport.write("secret", to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("assets"), withDestinationURL: outside)
        XCTAssertThrowsError(try AssetPath.resolve("assets/secret.txt", inside: root),
                             "a symlink that resolves outside the library root must be refused")
    }

    func testResolveRejectsASymlinkToTheRootItself() throws {
        let root = try makeTemporaryDirectory()
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"), withDestinationURL: root)
        XCTAssertThrowsError(try AssetPath.resolve("loop/scene.json", inside: root))
    }
}
