//
//  ImageSequenceExportWriter.swift
//  WallpaperMachineIOS
//
//  Writes numbered PNG/JPEG frames into a directory. The service optionally ZIPs
//  the directory for the share sheet.
//

import CoreGraphics
import CoreImage
import Foundation
import UIKit

public enum ImageSequenceExportError: LocalizedError, Equatable {
    case encodingFailed
    case directoryCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return String(localized: "A frame could not be encoded as an image.")
        case .directoryCreationFailed(let reason):
            return String(localized: "The frame directory could not be created.") + " " + reason
        }
    }
}

public final class ImageSequenceExportWriter {
    public let directory: URL
    private let imageFormat: WallpaperExportImageFormat
    private let quality: Double
    private let compositor: FrameCompositor

    public private(set) var writtenFrames = 0
    public private(set) var writtenBytes: Int64 = 0

    public init(
        directory: URL,
        imageFormat: WallpaperExportImageFormat,
        quality: Double,
        compositor: FrameCompositor
    ) throws {
        self.directory = directory
        self.imageFormat = imageFormat
        self.quality = min(max(quality, 0.1), 1.0)
        self.compositor = compositor
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ImageSequenceExportError.directoryCreationFailed(error.localizedDescription)
        }
    }

    public func append(_ image: CIImage, frameIndex: Int) throws {
        let rendered = try compositor.cgImage(for: image)
        let uiImage = UIImage(cgImage: rendered)
        let data: Data?
        switch imageFormat {
        case .png:
            data = uiImage.pngData()
        case .jpeg:
            data = uiImage.jpegData(compressionQuality: quality)
        }
        guard let data else { throw ImageSequenceExportError.encodingFailed }
        let base = String(format: "frame_%05d", frameIndex)
        let url = directory.appendingPathComponent("\(base).\(imageFormat.fileExtension)")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImageSequenceExportError.directoryCreationFailed(error.localizedDescription)
        }
        writtenFrames += 1
        writtenBytes += Int64(data.count)
    }

    public func finish() -> URL {
        directory
    }
}
