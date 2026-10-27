// SPDX-License-Identifier: GPL-3.0-only
// Foundation-only regression harness for the production Pixiv library project and repository.
// It deliberately uses local fixtures and never reaches pixiv, an account, or the keychain.
import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

private struct PixivLibraryTestFailure: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private enum PixivLibraryFixtures {
    #if canImport(ImageIO)
    static let jpeg = makeImage(type: UTType.jpeg.identifier)
    static let png = makeImage(type: UTType.png.identifier)

    private static func makeImage(type: String) -> Data {
        let context = CGContext(data: nil, width: 1920, height: 1080,
                                bitsPerComponent: 8, bytesPerRow: 1920 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination), "ImageIO fixture encoding failed")
        return output as Data
    }
    #else
    static let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46])
    static let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x01])
    #endif

    static let originalJPEG = URL(string: "https://i.pximg.net/img-original/77_p1.jpg")!
    static let originalPNG = URL(string: "https://i.pximg.net/img-original/77_p1.png")!

    static func work(title: String = "Triptych", pageCount: Int = 3) -> PixivWork {
        PixivWork(id: "77", title: title, authorID: "1304", authorName: "Artist",
                  thumbnailURL: nil, width: 1920, height: 1080, pageCount: pageCount,
                  rating: .everyone, aiGenerated: false, tags: ["sky", "night"], rank: nil)
    }

    static func page(index: Int, width: Int = 1920, height: Int = 1080,
                     originalURL: URL = originalJPEG) -> PixivPage {
        PixivPage(index: index, width: width, height: height, previewURL: nil, originalURL: originalURL)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-pixiv-library-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func jsonObject(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = object as? [String: Any] else {
            throw PixivLibraryTestFailure(message: "Expected a JSON object at \(url.path)")
        }
        return object
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw PixivLibraryTestFailure(message: "Fixture is not valid JSON")
        }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
            .write(to: url, options: .atomic)
    }

    static func copyFolder(_ folder: URL, into parent: URL) throws -> URL {
        let copy = parent.appendingPathComponent("copy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: copy)
        return copy
    }

    static func mutateProject(at folder: URL, _ mutate: (inout [String: Any]) throws -> Void) throws {
        var object = try jsonObject(at: folder.appendingPathComponent("project.json"))
        try mutate(&object)
        try writeJSON(object, to: folder.appendingPathComponent("project.json"))
    }

    static func itemDictionary(from object: [String: Any], index: Int = 0) throws -> [String: Any] {
        guard let items = object["items"] as? [[String: Any]], items.indices.contains(index) else {
            throw PixivLibraryTestFailure(message: "Legacy manifest has no item")
        }
        return items[index]
    }
}

private struct PixivLibraryHarness {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw PixivLibraryTestFailure(message: message) }
    }

    static func expectThrow(_ operation: () throws -> Void, _ message: String) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw PixivLibraryTestFailure(message: "Expected failure: \(message)")
    }

    static func expectPixivFailure(_ code: PixivFailure.Code, _ operation: () throws -> Void,
                                   _ message: String) throws {
        do {
            try operation()
        } catch let failure as PixivFailure {
            try require(failure.code == code, "\(message): got \(failure.code), expected \(code)")
            return
        } catch {
            throw PixivLibraryTestFailure(message: "\(message): got unexpected error \(error)")
        }
        throw PixivLibraryTestFailure(message: "Expected PixivFailure \(code): \(message)")
    }

    static func projectSignaturesAndAttribution() throws {
        let root = try PixivLibraryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let work = PixivLibraryFixtures.work()
        let page = PixivLibraryFixtures.page(index: 1, originalURL: PixivLibraryFixtures.originalJPEG)
        let cases: [(String, Data)] = [("jpg", PixivLibraryFixtures.jpeg), ("png", PixivLibraryFixtures.png)]
        for (expectedExtension, bytes) in cases {
            let folder = try PixivLibraryProject.stage(bytes, work: work, page: page, pageCount: 3,
                                                      temporaryRoot: root)
            defer { try? FileManager.default.removeItem(at: folder) }

            let original = folder.appendingPathComponent("illustration." + expectedExtension)
            try require(FileManager.default.fileExists(atPath: original.path),
                        "stage did not choose the \(expectedExtension) extension")
            try require(Data(contentsOf: original) == bytes, "stage changed the original bytes")

            let object = try PixivLibraryFixtures.jsonObject(at: folder.appendingPathComponent("project.json"))
            try require(object["file"] as? String == "illustration." + expectedExtension,
                        "project entry extension does not match the signature")
            #if canImport(ImageIO)
            try require(object["preview"] as? String == "preview.jpg", "Apple stage did not generate its preview")
            #else
            try require(object["preview"] as? String == "illustration." + expectedExtension,
                        "portable stage should retain the source as its preview")
            #endif
            try require(object["title"] as? String == "Triptych (2/3)",
                        "multipage title did not include the page position")
            let pixiv = try requireDictionary(object["pixiv"], "pixiv attribution")
            try require(pixiv["id"] as? String == "77" && pixiv["page"] as? Int == 1
                        && pixiv["pages"] as? Int == 3, "multipage attribution is incomplete")
            try require(pixiv["file"] as? String == "illustration." + expectedExtension,
                        "attribution did not retain the original file")
            try require(pixiv["width"] as? Int == 1920 && pixiv["height"] as? Int == 1080,
                        "attribution dimensions are wrong")
        }
    }

    static func projectRejectsInvalidInputsAndCleansUp() throws {
        let root = try PixivLibraryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = PixivLibraryFixtures.work(pageCount: 1)
        let validPage = PixivLibraryFixtures.page(index: 0, originalURL: PixivLibraryFixtures.originalJPEG)

        try expectPixivFailure(.notAnImage, { _ = try PixivLibraryProject.imageExtension(Data("plain text".utf8)) },
                               "non-image signature")
        try expectPixivFailure(.notAnImage, {
            _ = try PixivLibraryProject.stage(Data("plain text".utf8), work: work, page: validPage,
                                               pageCount: 1, temporaryRoot: root)
        }, "non-image stage")
        try require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty,
                    "failed non-image stage left a temporary folder")

        let oversized = Data(repeating: 0x5a, count: PixivService.originalByteLimit + 1)
        try expectPixivFailure(.tooLarge(megabytes: PixivService.originalByteLimit / 1024 / 1024), {
            _ = try PixivLibraryProject.stage(oversized, work: work, page: validPage,
                                               pageCount: 1, temporaryRoot: root)
        }, "oversized stage")
        try require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty,
                    "failed oversized stage left a temporary folder")

        let outOfRange = PixivLibraryFixtures.page(index: 1, originalURL: PixivLibraryFixtures.originalJPEG)
        try expectPixivFailure(.unreadable, {
            _ = try PixivLibraryProject.stage(PixivLibraryFixtures.jpeg, work: work, page: outOfRange,
                                               pageCount: 1, temporaryRoot: root)
        }, "out-of-range page")
        try require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty,
                    "failed out-of-range stage left a temporary folder")
    }

    static func repositoryImportIsIdempotentAndSeparatesPages() throws {
        let root = try PixivLibraryFixtures.temporaryDirectory()
        let sourceRoot = try PixivLibraryFixtures.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let work = PixivLibraryFixtures.work(pageCount: 2)
        let page0 = PixivLibraryFixtures.page(index: 0, originalURL: PixivLibraryFixtures.originalJPEG)
        let source0 = try PixivLibraryProject.stage(PixivLibraryFixtures.jpeg, work: work, page: page0,
                                                     pageCount: 2, temporaryRoot: sourceRoot)
        try PixivLibraryFixtures.mutateProject(at: source0) { object in
            object["general"] = ["properties": [
                "brightness": ["text": "Brightness", "type": "slider", "value": 0.25,
                                "min": 0.0, "max": 1.0, "options": []]
            ]]
        }

        let repository = LibraryRepository(rootURL: root)
        var manifest = try repository.importWallpaper(from: source0, into: repository.load())
        try require(manifest.items.count == 1, "first Pixiv import did not create one item")
        let first = try requireItem(manifest, index: 0)
        let firstBytes = try Data(contentsOf: repository.rootURL
            .appendingPathComponent(first.relativePath).appendingPathComponent(first.entryFile))
        try require(firstBytes == PixivLibraryFixtures.jpeg, "repository import changed original bytes")
        try require(first.title == "Triptych (1/2)" && first.pixiv?.page == 0,
                    "first page title or attribution is wrong")
        try require(first.properties["brightness"]?.value == .number(0.25),
                    "general property was not imported")

        var customized = first
        customized.isFavorite = true
        customized.collections = ["Favorites", "Night"]
        customized.properties["brightness"]?.value = .number(0.9)
        customized.addedAt = Date(timeIntervalSince1970: 1234)
        manifest.items[0] = customized
        manifest.collections = ["Favorites", "Night"]
        try repository.save(manifest)
        let originalID = customized.id

        let reimported = try repository.importWallpaper(from: source0, into: repository.load())
        try require(reimported.items.count == 1, "reimport duplicated the same work/page")
        let retained = try requireItem(reimported, index: 0)
        try require(retained.id == originalID && retained.isFavorite,
                    "reimport did not preserve UUID/favorite")
        try require(retained.collections == ["Favorites", "Night"]
                    && retained.properties["brightness"]?.value == .number(0.9),
                    "reimport did not preserve collections/properties")
        try require(retained.addedAt == Date(timeIntervalSince1970: 1234),
                    "reimport changed addedAt")
        try require(Data(contentsOf: repository.rootURL.appendingPathComponent(retained.relativePath)
            .appendingPathComponent(retained.entryFile)) == PixivLibraryFixtures.jpeg,
                    "reimport changed the retained original bytes")

        let page1 = PixivLibraryFixtures.page(index: 1, originalURL: PixivLibraryFixtures.originalPNG)
        let source1 = try PixivLibraryProject.stage(PixivLibraryFixtures.png, work: work, page: page1,
                                                     pageCount: 2, temporaryRoot: sourceRoot)
        let withSecondPage = try repository.importWallpaper(from: source1, into: reimported)
        try require(withSecondPage.items.count == 2, "a separate Pixiv page was not added")
        let second = try requireItem(withSecondPage, index: 1)
        try require(second.pixiv?.id == "77" && second.pixiv?.page == 1
                    && second.id != retained.id && second.title == "Triptych (2/2)",
                    "separate page did not receive a separate item identity")
    }

    static func oldManifestWithoutPixivLoads() throws {
        let root = try PixivLibraryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let relativePath = "Wallpapers/" + id.uuidString
        let folder = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PixivLibraryFixtures.jpeg.write(to: folder.appendingPathComponent("image.jpg"))

        let item = WallpaperItem(id: id, title: "Legacy", kind: .image, relativePath: relativePath,
                                 entryFile: "image.jpg", workshopID: nil, pixiv: nil,
                                 isFavorite: true, collections: ["Old"],
                                 addedAt: Date(timeIntervalSince1970: 42))
        var manifest = LibraryManifest()
        manifest.items = [item]
        let encoded = try JSONEncoder().encode(manifest)
        var object = try requireDictionary(JSONSerialization.jsonObject(with: encoded), "encoded manifest")
        var oldItem = try PixivLibraryFixtures.itemDictionary(from: object)
        oldItem.removeValue(forKey: "pixiv")
        object["items"] = [oldItem]
        try PixivLibraryFixtures.writeJSON(object, to: root.appendingPathComponent("library.json"))

        let loaded = try LibraryRepository(rootURL: root).load()
        try require(loaded.items.count == 1 && loaded.items[0].pixiv == nil,
                    "manifest without pixiv did not remain compatible")
        try require(loaded.items[0].isFavorite && loaded.items[0].collections == ["Old"],
                    "legacy fields changed while decoding")
    }

    static func malformedProvenanceDoesNotCorruptExistingLibrary() throws {
        let variants = ["scalar", "unsafe-file", "foreign-original"]
        for variant in variants {
            let root = try PixivLibraryFixtures.temporaryDirectory()
            let sourceRoot = try PixivLibraryFixtures.temporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: root)
                try? FileManager.default.removeItem(at: sourceRoot)
            }

            let work = PixivLibraryFixtures.work(pageCount: 1)
            let validPage = PixivLibraryFixtures.page(index: 0, originalURL: PixivLibraryFixtures.originalJPEG)
            let validSource = try PixivLibraryProject.stage(PixivLibraryFixtures.jpeg, work: work, page: validPage,
                                                            pageCount: 1, temporaryRoot: sourceRoot)
            let repository = LibraryRepository(rootURL: root)
            _ = try repository.importWallpaper(from: validSource, into: repository.load())
            let beforeManifest = try Data(contentsOf: root.appendingPathComponent("library.json"))
            let existing = try requireItem(repository.load(), index: 0)
            let beforeBytes = try Data(contentsOf: root.appendingPathComponent(existing.relativePath)
                .appendingPathComponent(existing.entryFile))

            let invalidSource = try PixivLibraryFixtures.copyFolder(validSource, into: sourceRoot)
            try PixivLibraryFixtures.mutateProject(at: invalidSource) { object in
                switch variant {
                case "scalar": object["pixiv"] = "malformed"
                case "unsafe-file":
                    var pixiv = try requireDictionary(object["pixiv"], "valid fixture pixiv")
                    pixiv["file"] = "../outside.jpg"
                    object["pixiv"] = pixiv
                case "foreign-original":
                    var pixiv = try requireDictionary(object["pixiv"], "valid fixture pixiv")
                    pixiv["original"] = "https://example.com/unsafe.jpg"
                    object["pixiv"] = pixiv
                default: throw PixivLibraryTestFailure(message: "unknown variant")
                }
            }
            try expectThrow({ _ = try repository.importWallpaper(from: invalidSource, into: repository.load()) },
                            "malformed provenance variant \(variant)")
            try require(Data(contentsOf: root.appendingPathComponent("library.json")) == beforeManifest,
                        "failed \(variant) import changed library.json")
            try require(Data(contentsOf: root.appendingPathComponent(existing.relativePath)
                .appendingPathComponent(existing.entryFile)) == beforeBytes,
                        "failed \(variant) import changed the existing asset")
        }
    }

    static func saveAndLoadValidateProvenanceWithoutMutation() throws {
        let root = try PixivLibraryFixtures.temporaryDirectory()
        let sourceRoot = try PixivLibraryFixtures.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let work = PixivLibraryFixtures.work(pageCount: 1)
        let page = PixivLibraryFixtures.page(index: 0, originalURL: PixivLibraryFixtures.originalJPEG)
        let source = try PixivLibraryProject.stage(PixivLibraryFixtures.jpeg, work: work, page: page,
                                                   pageCount: 1, temporaryRoot: sourceRoot)
        let repository = LibraryRepository(rootURL: root)
        let valid = try repository.importWallpaper(from: source, into: repository.load())
        let manifestURL = root.appendingPathComponent("library.json")
        let beforeManifest = try Data(contentsOf: manifestURL)
        let existing = try requireItem(valid, index: 0)
        let entryURL = root.appendingPathComponent(existing.relativePath).appendingPathComponent(existing.entryFile)
        let beforeBytes = try Data(contentsOf: entryURL)

        var invalid = valid
        invalid.items[0].pixiv = PixivAttribution(
            id: "77", page: 0, pages: 1, author: "Artist", authorId: "1304",
            url: URL(string: "https://www.pixiv.net/artworks/77")!,
            original: URL(string: "https://i.pximg.net/img-original/77_p0.jpg")!,
            file: "../outside.jpg", width: 1920, height: 1080)
        try expectThrow({ try repository.save(invalid) }, "save accepted an escaping provenance file")
        try require(Data(contentsOf: manifestURL) == beforeManifest,
                    "rejected save changed the manifest")

        var invalidObject = try PixivLibraryFixtures.jsonObject(at: manifestURL)
        var invalidItem = try PixivLibraryFixtures.itemDictionary(from: invalidObject)
        var invalidPixiv = try requireDictionary(invalidItem["pixiv"], "saved pixiv attribution")
        invalidPixiv["file"] = "missing-original.jpg"
        invalidItem["pixiv"] = invalidPixiv
        invalidObject["items"] = [invalidItem]
        try PixivLibraryFixtures.writeJSON(invalidObject, to: manifestURL)
        let invalidManifestBytes = try Data(contentsOf: manifestURL)
        try expectThrow({ _ = try repository.load() }, "load accepted a missing provenance file")
        try require(Data(contentsOf: manifestURL) == invalidManifestBytes,
                    "rejected load rewrote the manifest")
        try require(Data(contentsOf: entryURL) == beforeBytes,
                    "rejected load changed the existing asset")
    }

    private static func requireDictionary(_ value: Any?, _ label: String) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any] else {
            throw PixivLibraryTestFailure(message: "Expected (label) to be a dictionary")
        }
        return dictionary
    }

    private static func requireItem(_ manifest: LibraryManifest, index: Int) throws -> WallpaperItem {
        guard manifest.items.indices.contains(index) else {
            throw PixivLibraryTestFailure(message: "Expected library item at index \(index)")
        }
        return manifest.items[index]
    }
}

@main
private struct PixivLibraryRegression {
    static func main() throws {
        let cases: [(String, () throws -> Void)] = [
            ("project-signatures-attribution", PixivLibraryHarness.projectSignaturesAndAttribution),
            ("project-rejects-and-cleans", PixivLibraryHarness.projectRejectsInvalidInputsAndCleansUp),
            ("repository-idempotency-pages", PixivLibraryHarness.repositoryImportIsIdempotentAndSeparatesPages),
            ("legacy-manifest-without-pixiv", PixivLibraryHarness.oldManifestWithoutPixivLoads),
            ("malformed-provenance-preserves-library", PixivLibraryHarness.malformedProvenanceDoesNotCorruptExistingLibrary),
            ("provenance-save-load-validation", PixivLibraryHarness.saveAndLoadValidateProvenanceWithoutMutation),
        ]
        for (name, test) in cases {
            do {
                try test()
            } catch {
                throw PixivLibraryTestFailure(message: "\(name): \(error)")
            }
            print("PASS \(name)")
        }
        print("PASS: PixivLibrary \(cases.count) cases")
    }
}
