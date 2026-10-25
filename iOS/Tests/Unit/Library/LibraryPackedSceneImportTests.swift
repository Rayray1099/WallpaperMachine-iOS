// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import XCTest
@testable import WallpaperMachineIOS

final class LibraryPackedSceneImportTests: XCTestCase {
    private func package(entry: String = "scene.json") -> Data {
        // Same PKGV0001 table/payload format as the native engine's package fixtures.
        let name = Data(entry.utf8)
        let payload = Data("{\"general\":{},\"objects\":[]}".utf8)
        var data = Data()
        func integer(_ value: UInt32) {
            data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        integer(8); data.append(Data("PKGV0001".utf8)); integer(1)
        integer(UInt32(name.count)); data.append(name); integer(0); integer(UInt32(payload.count))
        data.append(payload)
        return data
    }

    private func fixture(type: String = "scene", file: String = "scene.json", packageName: String? = "scene.pkg") throws -> URL {
        let source = try makeTemporaryDirectory()
        let metadata: [String: Any] = [
            "type": type, "file": file, "title": "Packed fixture", "preview": "preview.png",
            "general": ["properties": ["speed": ["text": "Speed", "type": "slider", "value": 2]]]
        ]
        try JSONSerialization.data(withJSONObject: metadata).write(to: source.appendingPathComponent("project.json"))
        try IOSTestSupport.write("synthetic preview", to: source.appendingPathComponent("preview.png"))
        try IOSTestSupport.write("retained extra asset", to: source.appendingPathComponent("assets/extra.txt"))
        if let packageName {
            let url = source.appendingPathComponent(packageName)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try package(entry: file).write(to: url)
        }
        return source
    }

    func testPackedSceneResolvesPhysicalPackageAndPreservesMetadataAndAllFiles() throws {
        let source = try fixture()
        let metadata = try Data(contentsOf: source.appendingPathComponent("project.json"))
        let packed = try Data(contentsOf: source.appendingPathComponent("scene.pkg"))
        let root = try makeTemporaryDirectory()
        let repository = LibraryRepository(rootURL: root)
        let manifest = try repository.importWallpaper(from: source, into: repository.load())
        let item = try XCTUnwrap(manifest.items.first)
        XCTAssertEqual(item.kind, .scene)
        XCTAssertEqual(item.entryFile, "scene.pkg")
        XCTAssertEqual(item.title, "Packed fixture")
        XCTAssertEqual(item.previewFile, "preview.png")
        XCTAssertEqual(item.properties["speed"]?.value, .number(2))
        let imported = root.appendingPathComponent(item.relativePath)
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent("project.json")), metadata)
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent("scene.pkg")), packed)
        XCTAssertEqual(try String(contentsOf: imported.appendingPathComponent("assets/extra.txt"), encoding: .utf8), "retained extra asset")
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.json")), metadata)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("scene.pkg")), packed)
        XCTAssertEqual(try repository.load().items, manifest.items)
    }

    func testExistingLooseEntryStillWinsOverPackage() throws {
        let source = try fixture()
        try IOSTestSupport.write("{}", to: source.appendingPathComponent("scene.json"))
        let repository = LibraryRepository(rootURL: try makeTemporaryDirectory())
        let imported = try repository.importWallpaper(from: source, into: repository.load())
        XCTAssertEqual(imported.items.first?.entryFile, "scene.json")
    }

    func testSameBasenamePackageIsNotHardcodedToScene() throws {
        let source = try fixture(file: "custom.json", packageName: "custom.pkg")
        let repository = LibraryRepository(rootURL: try makeTemporaryDirectory())
        let imported = try repository.importWallpaper(from: source, into: repository.load())
        XCTAssertEqual(imported.items.first?.entryFile, "custom.pkg")
    }

    func testNestedPackedEntryIsRejectedWithoutChangingSource() throws {
        for entry in ["nested/scene.json", "nested\\scene.json"] {
            let source = try fixture(file: entry, packageName: "nested/scene.pkg")
            let metadata = try Data(contentsOf: source.appendingPathComponent("project.json"))
            let packageURL = source.appendingPathComponent("nested/scene.pkg")
            let packed = try Data(contentsOf: packageURL)
            let repository = LibraryRepository(rootURL: try makeTemporaryDirectory())
            XCTAssertThrowsError(try repository.importWallpaper(from: source, into: repository.load()))
            XCTAssertTrue(try repository.load().items.isEmpty)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.json")), metadata)
            XCTAssertEqual(try Data(contentsOf: packageURL), packed)
        }
    }

    func testExistingLooseNestedEntryRemainsImportable() throws {
        let source = try fixture(file: "nested/scene.json", packageName: "nested/scene.pkg")
        try IOSTestSupport.write("{}", to: source.appendingPathComponent("nested/scene.json"))
        let repository = LibraryRepository(rootURL: try makeTemporaryDirectory())
        let imported = try repository.importWallpaper(from: source, into: repository.load())
        XCTAssertEqual(imported.items.first?.entryFile, "nested/scene.json")
    }

    func testMissingNonSceneAndUnrelatedPackageEntriesAreRejected() throws {
        for source in [try fixture(packageName: nil), try fixture(type: "web"),
                       try fixture(file: "other.json"), try fixture(file: "missing.mp4")] {
            let repository = LibraryRepository(rootURL: try makeTemporaryDirectory())
            XCTAssertThrowsError(try repository.importWallpaper(from: source, into: repository.load()))
            XCTAssertTrue(try repository.load().items.isEmpty)
        }
    }

    func testDirectoryCannotServeAsEntryOrPackage() throws {
        for name in ["scene.json", "scene.pkg"] {
            let source = try fixture(packageName: nil)
            try FileManager.default.createDirectory(at: source.appendingPathComponent(name), withIntermediateDirectories: true)
            let repository = LibraryRepository(rootURL: try makeTemporaryDirectory())
            XCTAssertThrowsError(try repository.importWallpaper(from: source, into: repository.load()))
        }
    }

    func testUnsafeDeclaredEntryCannotBeHiddenByPackageFallback() throws {
        for entry in ["../scene.json", "/scene.json", "nested/../../scene.json"] {
            let source = try fixture(file: entry)
            let repository = LibraryRepository(rootURL: try makeTemporaryDirectory())
            XCTAssertThrowsError(try repository.importWallpaper(from: source, into: repository.load()))
        }
    }

    func testPackageSymlinkIsRejected() throws {
        let source = try fixture(packageName: nil)
        let outside = try makeTemporaryDirectory().appendingPathComponent("outside.pkg")
        try package().write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("scene.pkg"), withDestinationURL: outside)
        let repository = LibraryRepository(rootURL: try makeTemporaryDirectory())
        XCTAssertThrowsError(try repository.importWallpaper(from: source, into: repository.load()))
        XCTAssertTrue(try repository.load().items.isEmpty)
    }
}
