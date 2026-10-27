// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

/// Prepares a native still-image project for the existing transactional library importer.
/// The original bytes are retained even when playback needs a smaller display image.
enum PixivLibraryProject {
    static let displayLongSide = 4096

    static func imageExtension(_ data: Data) throws -> String {
        if data.starts(with: [0xff, 0xd8, 0xff]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return "png" }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) { return "gif" }
        throw PixivFailure(code: .notAnImage)
    }

    static func stage(
        _ image: Data, work: PixivWork, page: PixivPage, pageCount: Int,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        guard image.count <= PixivService.originalByteLimit else {
            throw PixivFailure(code: .tooLarge(megabytes: PixivService.originalByteLimit / 1024 / 1024))
        }
        guard PixivWork.isValidID(work.id), page.index >= 0, page.index < pageCount,
              page.width > 0, page.height > 0, PixivService.isImageURL(page.originalURL),
              work.rating != .grotesque else { throw PixivFailure(code: .unreadable) }
        try Task.checkCancellation()
        let format = try imageExtension(image)
        let originalName = "illustration." + format
        let folder = temporaryRoot.appendingPathComponent("wm-pixiv-" + UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            var entry = originalName
            var preview = originalName
            var width = page.width
            var height = page.height
            #if canImport(ImageIO)
            guard let source = CGImageSourceCreateWithData(image as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let actualWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let actualHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  actualWidth.intValue > 0, actualHeight.intValue > 0
            else { throw PixivFailure(code: .undecodable) }
            width = actualWidth.intValue
            height = actualHeight.intValue
            let thumbnail = try jpeg(source, maximum: 512)
            preview = "preview.jpg"
            try thumbnail.write(to: folder.appendingPathComponent(preview), options: .atomic)
            if max(width, height) > displayLongSide {
                entry = "display.jpg"
                try jpeg(source, maximum: displayLongSide).write(to: folder.appendingPathComponent(entry), options: .atomic)
            }
            #endif
            try image.write(to: folder.appendingPathComponent(originalName), options: .atomic)
            let name = work.title.isEmpty ? "pixiv " + work.id : work.title
            let title = pageCount > 1 ? "\(name) (\(page.index + 1)/\(pageCount))" : name
            let manifest: [String: Any] = [
                "title": title, "type": "image", "file": entry, "preview": preview,
                "description": "\(name) by \(work.authorName) on pixiv: \(work.artworkURL.absoluteString)",
                "contentrating": work.rating.rawValue, "tags": Array(work.tags.prefix(20)),
                "pixiv": [
                    "id": work.id, "page": page.index, "pages": pageCount,
                    "author": work.authorName, "authorId": work.authorID,
                    "url": work.artworkURL.absoluteString, "original": page.originalURL.absoluteString,
                    "file": originalName, "width": width, "height": height,
                ],
            ]
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
                .write(to: folder.appendingPathComponent("project.json"), options: .atomic)
            try Task.checkCancellation()
            return folder
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    #if canImport(ImageIO)
    private static func jpeg(_ source: CGImageSource, maximum: Int) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw PixivFailure(code: .undecodable) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PixivFailure(code: .undecodable) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PixivFailure(code: .undecodable) }
        return data as Data
    }
    #endif
}
