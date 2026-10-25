//
//  TendiesExportWriter.swift
//  WallpaperMachineIOS
//
//  Streams rendered JPEG frames plus the generated PosterBoard manifest into a
//  `.tendies` ZIP. One frame is in memory at a time; there is no frame ceiling
//  below the ZIP32 entry limit (65,524 frames for this manifest).
//

import CoreGraphics
import CoreImage
import Foundation
import UIKit

public enum TendiesExportError: LocalizedError, Equatable {
    case jpegEncodingFailed
    case frameIndexOutOfRange(Int, Int)
    case archiveFailed(String)
    case unsupportedName

    public var errorDescription: String? {
        switch self {
        case .jpegEncodingFailed:
            return String(localized: "A wallpaper frame could not be encoded as JPEG.")
        case .frameIndexOutOfRange(let index, let expected):
            return String(localized: "A frame was written out of order.") + " (\(index)/\(expected))"
        case .archiveFailed(let reason):
            return String(localized: "The .tendies archive could not be written.") + " " + reason
        case .unsupportedName:
            return String(localized: "The wallpaper name cannot be used in a .tendies file.")
        }
    }
}

public final class TendiesExportWriter {
    public let descriptor: TendiesWallpaperDescriptor
    public let outputURL: URL
    private let archive: ZipArchiveWriter
    private let compositor: FrameCompositor
    private let quality: Double

    public private(set) var writtenFrames = 0
    public private(set) var writtenFrameBytes: Int64 = 0

    public init(
        descriptor: TendiesWallpaperDescriptor,
        outputURL: URL,
        compositor: FrameCompositor,
        jpegQuality: Double,
        includesDisplayNameMetadata: Bool
    ) throws {
        self.descriptor = try descriptor.validated()
        self.outputURL = outputURL
        self.compositor = compositor
        self.quality = min(max(jpegQuality, 0.1), 1.0)
        do {
            self.archive = try ZipArchiveWriter(outputURL: outputURL)
            let metadata = try TendiesManifest.metadataFiles(
                for: descriptor,
                includeDisplayNameMetadata: includesDisplayNameMetadata)
            for file in metadata {
                try archive.addFile(path: file.path, data: file.data)
            }
        } catch let error as TendiesManifestError {
            throw TendiesExportError.archiveFailed(error.description)
        } catch let error as ZipArchiveWriter.ZipError {
            throw TendiesExportError.archiveFailed(error.description)
        }
    }

    public func append(_ image: CIImage, frameIndex: Int) throws {
        guard frameIndex >= 0, frameIndex < descriptor.frameCount else {
            throw TendiesExportError.frameIndexOutOfRange(frameIndex, descriptor.frameCount)
        }
        let rendered = try compositor.cgImage(for: image)
        guard let jpeg = UIImage(cgImage: rendered).jpegData(compressionQuality: quality) else {
            throw TendiesExportError.jpegEncodingFailed
        }
        do {
            try archive.addFile(path: descriptor.frameMemberPath(at: frameIndex), data: jpeg)
        } catch let error as ZipArchiveWriter.ZipError {
            throw TendiesExportError.archiveFailed(error.description)
        }
        writtenFrames += 1
        writtenFrameBytes += Int64(jpeg.count)
    }

    public func finish() throws -> URL {
        do {
            return try archive.finish()
        } catch let error as ZipArchiveWriter.ZipError {
            throw TendiesExportError.archiveFailed(error.description)
        }
    }

    public func cancel() {
        archive.abort()
        try? FileManager.default.removeItem(at: outputURL)
    }
}
