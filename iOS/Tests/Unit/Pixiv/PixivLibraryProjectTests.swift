// SPDX-License-Identifier: GPL-3.0-only
#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import WallpaperMachineIOS

/// Apple ImageIO coverage complements the Foundation-only Windows harness.
final class PixivLibraryProjectTests: XCTestCase {
    func testInvalidImageSignatureIsRejectedByImageIO() throws {
        let page = PixivPage(index: 0, width: 8, height: 8, previewURL: nil,
                             originalURL: URL(string: "https://i.pximg.net/img-original/77_p0.png")!)
        let work = PixivWork(id: "77", title: "Invalid", authorID: "1", authorName: "Artist",
                             thumbnailURL: nil, width: 8, height: 8, pageCount: 1,
                             rating: .everyone, aiGenerated: false, tags: [], rank: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try PixivLibraryProject.stage(
            Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
            work: work, page: page, pageCount: 1, temporaryRoot: root)) {
            XCTAssertEqual(($0 as? PixivFailure)?.code, .undecodable)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil), [])
    }

    func testLargeImageUses4096DisplayAnd512PreviewAndRetainsOriginal() throws {
        let original = try makePNG(width: 5000, height: 3000)
        let page = PixivPage(index: 0, width: 5000, height: 3000, previewURL: nil,
                             originalURL: URL(string: "https://i.pximg.net/img-original/77_p0.png")!)
        let work = PixivWork(id: "77", title: "Large", authorID: "1", authorName: "Artist",
                             thumbnailURL: nil, width: 5000, height: 3000, pageCount: 1,
                             rating: .everyone, aiGenerated: false, tags: [], rank: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = try PixivLibraryProject.stage(original, work: work, page: page, pageCount: 1,
                                                   temporaryRoot: root)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("project.json"))) as? [String: Any])
        XCTAssertEqual(project["file"] as? String, "display.jpg")
        XCTAssertEqual(project["preview"] as? String, "preview.jpg")
        let pixiv = try XCTUnwrap(project["pixiv"] as? [String: Any])
        XCTAssertEqual(pixiv["file"] as? String, "illustration.png")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("illustration.png")), original)
        let display = try pixelSize(at: folder.appendingPathComponent("display.jpg"))
        let preview = try pixelSize(at: folder.appendingPathComponent("preview.jpg"))
        XCTAssertEqual(display[0], 4096)
        XCTAssertLessThanOrEqual(abs(Double(display[1]) - 2457.6), 1)
        XCTAssertEqual(preview[0], 512)
        XCTAssertLessThanOrEqual(abs(Double(preview[1]) - 307.2), 1)
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                               bitsPerComponent: 8, bytesPerRow: width * 4,
                                               space: colorSpace,
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixelSize(at url: URL) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any])
        let width = try XCTUnwrap((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try XCTUnwrap((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        return [width, height]
    }
}
#endif
