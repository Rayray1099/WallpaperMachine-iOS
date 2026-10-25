//
//  MovieFrameSource.swift
//  WallpaperMachineIOS
//
//  Decodes a source video with AVAssetReader and hands the exporter one frame per
//  output tick. The exporter owns the tick grid, so a 60 fps source rendered at
//  30 fps is sampled at 30 fps (nearest frame at or before each tick) instead of
//  being re-timestamped by the encoder.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public struct MovieSourceInfo: Sendable, Equatable {
    public let duration: CMTime
    public let pixelSize: PixelSize
    public let preferredTransform: CGAffineTransform
    public let nominalFrameRate: Float

    public init(duration: CMTime, pixelSize: PixelSize,
                preferredTransform: CGAffineTransform, nominalFrameRate: Float) {
        self.duration = duration
        self.pixelSize = pixelSize
        self.preferredTransform = preferredTransform
        self.nominalFrameRate = nominalFrameRate
    }
}

public enum MovieFrameSourceError: LocalizedError, Equatable {
    case sourceMissing
    case unreadable(String)
    case invalidDuration
    case noVideoTrack
    case invalidTrackSize
    case readerConfigurationFailed
    case readerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return String(localized: "The source video could not be found.")
        case .unreadable(let reason):
            return String(localized: "The source video could not be opened.") + " " + reason
        case .invalidDuration:
            return String(localized: "The source video has no usable duration.")
        case .noVideoTrack:
            return String(localized: "The source file has no video track.")
        case .invalidTrackSize:
            return String(localized: "The source video track has no usable frame size.")
        case .readerConfigurationFailed:
            return String(localized: "The video decoder could not be configured for this file.")
        case .readerFailed(let reason):
            return String(localized: "The video decoder failed.") + " " + reason
        }
    }
}

public final class MovieFrameSource {
    private struct Sample {
        let sampleBuffer: CMSampleBuffer
        let time: CMTime
        var pixelBuffer: CVPixelBuffer? { CMSampleBufferGetImageBuffer(sampleBuffer) }
    }

    public let asset: AVURLAsset
    public let info: MovieSourceInfo
    private let track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: Sample?
    private var lookahead: Sample?
    private var didPrefetch = false

    private init(asset: AVURLAsset, track: AVAssetTrack, info: MovieSourceInfo) {
        self.asset = asset
        self.track = track
        self.info = info
    }

    public static func open(url: URL) async throws -> MovieFrameSource {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MovieFrameSourceError.sourceMissing
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw MovieFrameSourceError.unreadable(error.localizedDescription)
        }
        guard duration.isValid, duration.isNumeric, !duration.isIndefinite,
              duration.seconds.isFinite, duration.seconds > 0 else {
            throw MovieFrameSourceError.invalidDuration
        }
        guard let track = tracks.first else {
            throw MovieFrameSourceError.noVideoTrack
        }

        let naturalSize: CGSize
        let transform: CGAffineTransform
        let nominalFrameRate: Float
        do {
            naturalSize = try await track.load(.naturalSize)
            transform = try await track.load(.preferredTransform)
            nominalFrameRate = try await track.load(.nominalFrameRate)
        } catch {
            throw MovieFrameSourceError.unreadable(error.localizedDescription)
        }

        let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
        let pixelSize = PixelSize(width: Int(transformed.width.rounded()),
                                  height: Int(transformed.height.rounded()))
        guard pixelSize.isPositive else { throw MovieFrameSourceError.invalidTrackSize }

        let info = MovieSourceInfo(duration: duration, pixelSize: pixelSize,
                                   preferredTransform: transform, nominalFrameRate: nominalFrameRate)
        return MovieFrameSource(asset: asset, track: track, info: info)
    }

    /// Starts decoding. Called once by the exporter before the first frame.
    public func start() throws {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MovieFrameSourceError.readerConfigurationFailed }
        reader.add(output)
        guard reader.startReading() else {
            throw MovieFrameSourceError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        self.reader = reader
        self.output = output
        self.current = nil
        self.lookahead = nil
        self.didPrefetch = false
    }

    /// Returns the decoded frame covering `target`, or nil if decoding has ended.
    /// Frames later than the target are held (the last frame is reused) so a
    /// variable-frame-rate source never produces gaps.
    public func frame(at target: CMTime) throws -> CVPixelBuffer? {
        try ensurePrefetch()
        while let next = lookahead, CMTimeCompare(next.time, target) <= 0 {
            current = next
            lookahead = try readNext()
        }
        return current?.pixelBuffer
    }

    public func close() {
        reader?.cancelReading()
        reader = nil
        output = nil
        current = nil
        lookahead = nil
        didPrefetch = false
    }

    private func ensurePrefetch() throws {
        guard !didPrefetch else { return }
        didPrefetch = true
        current = try readNext()
        lookahead = try readNext()
    }

    private func readNext() throws -> Sample? {
        guard let output else { return nil }
        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            if let reader, reader.status == .failed {
                throw MovieFrameSourceError.readerFailed(reader.error?.localizedDescription ?? "unknown")
            }
            return nil
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        return Sample(sampleBuffer: sampleBuffer, time: time)
    }
}
