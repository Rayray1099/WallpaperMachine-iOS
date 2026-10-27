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
    case incompleteFrames(Int, Int)
    case archiveFailed(String)
    case unsupportedName

    public var errorDescription: String? {
        switch self {
        case .jpegEncodingFailed:
            return String(localized: "A wallpaper frame could not be encoded as JPEG.")
        case .frameIndexOutOfRange(let index, let expected):
            return String(localized: "A frame was written out of order.") + " (\(index)/\(expected))"
        case .incompleteFrames(let written, let expected):
            return String(localized: "The .tendies archive is missing wallpaper frames.") + " (\(written)/\(expected))"
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
    // A rejected or partially written frame must never become a completed archive.
    private var failure: Error?

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
        if let failure { throw failure }
        guard frameIndex == writtenFrames, frameIndex < descriptor.frameCount else {
            let error = TendiesExportError.frameIndexOutOfRange(frameIndex, descriptor.frameCount)
            failure = error
            throw error
        }
        // Drain this frame's synchronous Core Image/UIKit/JPEG temporaries even
        // when an offline export encodes many frames without a run-loop drain.
        // The input CIImage remains caller-owned; no await crosses this pool.
        do {
            try autoreleasepool {
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
        } catch {
            failure = error
            throw error
        }
    }

    public func finish() throws -> URL {
        if let failure { throw failure }
        guard writtenFrames == descriptor.frameCount else {
            let error = TendiesExportError.incompleteFrames(writtenFrames, descriptor.frameCount)
            failure = error
            throw error
        }
        do {
            return try archive.finish()
        } catch let error as ZipArchiveWriter.ZipError {
            let failure = TendiesExportError.archiveFailed(error.description)
            self.failure = failure
            throw failure
        } catch {
            failure = error
            throw error
        }
    }

    public func cancel() {
        archive.abort()
        try? FileManager.default.removeItem(at: outputURL)
    }
}
