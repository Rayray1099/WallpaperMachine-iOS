//
//  MovieExportWriter.swift
//  WallpaperMachineIOS
//
//  AVAssetWriter pipeline for MP4 output (H.264 or HEVC).
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation

public enum MovieExportError: LocalizedError, Equatable {
    case unsupportedSettings
    case writerSetupFailed(String)
    case writerStartFailed(String)
    case appendFailed(String)
    case finishFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSettings:
            return String(localized: "This device cannot encode the selected codec and resolution.")
        case .writerSetupFailed(let reason):
            return String(localized: "The video encoder could not be created.") + " " + reason
        case .writerStartFailed(let reason):
            return String(localized: "The video encoder could not start.") + " " + reason
        case .appendFailed(let reason):
            return String(localized: "A video frame could not be encoded.") + " " + reason
        case .finishFailed(let reason):
            return String(localized: "The MP4 file could not be finalised.") + " " + reason
        }
    }
}

public final class MovieExportWriter {
    private let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameRate: Int
    private var started = false

    public init(
        outputURL: URL,
        pixelSize: PixelSize,
        codec: WallpaperExportCodec,
        frameRate: Int,
        averageBitrate: Int
    ) throws {
        self.outputURL = outputURL
        self.frameRate = max(1, frameRate)
        try? FileManager.default.removeItem(at: outputURL)

        do {
            self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw MovieExportError.writerSetupFailed(error.localizedDescription)
        }

        let codecType: AVVideoCodecType = codec == .hevc ? .hevc : .h264
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: max(1, averageBitrate),
            AVVideoExpectedSourceFrameRateKey: self.frameRate,
            AVVideoMaxKeyFrameIntervalKey: self.frameRate * 2,
            AVVideoAllowFrameReorderingKey: true
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: pixelSize.width,
            AVVideoHeightKey: pixelSize.height,
            AVVideoCompressionPropertiesKey: compression
        ]
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
            throw MovieExportError.unsupportedSettings
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: pixelSize.width,
            kCVPixelBufferHeightKey as String: pixelSize.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: sourceAttributes)
        guard writer.canAdd(input) else { throw MovieExportError.unsupportedSettings }
        writer.add(input)
        writer.shouldOptimizeForNetworkUse = true

        self.input = input
        self.adaptor = adaptor
    }

    public var pixelBufferPool: CVPixelBufferPool? { adaptor.pixelBufferPool }

    public func start() throws {
        guard writer.startWriting() else {
            throw MovieExportError.writerStartFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    public func append(_ image: CIImage, compositor: FrameCompositor, frameIndex: Int) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw MovieExportError.appendFailed("no pixel buffer pool")
        }
        let buffer = try compositor.pixelBuffer(for: image, pool: pool)
        let presentationTime = CMTime(value: CMTimeValue(frameIndex),
                                      timescale: CMTimeScale(frameRate))
        guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
            throw MovieExportError.appendFailed(writer.error?.localizedDescription ?? "append failed")
        }
    }

    public func finish() async throws -> URL {
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw MovieExportError.finishFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        return outputURL
    }

    public func cancel() {
        if started, writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: outputURL)
    }
}
