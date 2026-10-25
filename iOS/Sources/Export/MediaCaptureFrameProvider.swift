//
//  MediaCaptureFrameProvider.swift
//  WallpaperMachineIOS
//
//  Bridges Media's CGImage capture protocol (`MediaFrameProviding`, owned by the
//  Media Agent) to the exporter's CVPixelBuffer frame provider. This adapter is
//  optional for video items (the exporter can decode them directly) and is the
//  intended path for web items that Media can snapshot.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

@MainActor
final class MediaCaptureFrameProvider: WallpaperFrameProvider {
    private let source: MediaFrameProviding
    private var preparedFrame: MediaFrame?
    private var measuredSize: CGSize = .zero

    init(source: MediaFrameProviding) {
        self.source = source
    }

    var frameSize: CGSize { measuredSize }

    /// MediaFrameProviding does not expose a duration; the export duration is used.
    var duration: CMTime? { nil }

    func prepareForExport() async throws {
        guard source.isFrameCaptureReady else {
            throw WallpaperFrameProviderError.unavailable(
                String(localized: "The wallpaper surface has not rendered a frame that can be captured yet."))
        }
        let frame = try await source.captureFrame(at: nil, maximumSize: .zero)
        guard frame.image.width > 0, frame.image.height > 0 else {
            throw WallpaperFrameProviderError.renderFailed(
                String(localized: "The wallpaper surface returned an empty image."))
        }
        preparedFrame = frame
        measuredSize = CGSize(width: frame.image.width, height: frame.image.height)
    }

    func frame(at time: CMTime) async throws -> CVPixelBuffer? {
        guard preparedFrame != nil else { throw WallpaperFrameProviderError.notPrepared }
        let frame: MediaFrame
        switch source.frameSource {
        case .video:
            frame = try await source.captureFrame(at: time, maximumSize: .zero)
        case .web, .scene, .image:
            // Live surfaces have no independent timeline; capture the current frame.
            // The provider is still asked for every tick, so a changing web canvas
            // is sampled rather than a single still being repeated.
            frame = try await source.captureFrame(at: nil, maximumSize: .zero)
        }
        return try Self.pixelBuffer(from: frame.image)
    }

    func finishExport() async {
        preparedFrame = nil
        measuredSize = .zero
    }

    static func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw WallpaperFrameProviderError.renderFailed(
                String(localized: "The wallpaper surface returned an empty image."))
        }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw WallpaperFrameProviderError.renderFailed(
                String(localized: "The captured frame could not be converted to a video frame."))
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw WallpaperFrameProviderError.renderFailed(
                String(localized: "The captured frame could not be converted to a video frame."))
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: baseAddress,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            throw WallpaperFrameProviderError.renderFailed(
                String(localized: "The captured frame could not be converted to a video frame."))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
