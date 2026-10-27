//
//  WallpaperExportService.swift
//  WallpaperMachineIOS
//
//  Orchestrates real frame rendering and the three output writers.
//
//  Honesty contract:
//  - video items are decoded from their real frames;
//  - image items export their real still image;
//  - scene/web items require a `WallpaperFrameProvider` supplied by the Renderer
//    or Media layer. Without one the service fails with `.frameProviderUnavailable`
//    and never falls back to `item.previewFile`.
//

import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import UIKit

public enum WallpaperExportPhase: String, Sendable, Equatable {
    case preparing
    case rendering
    case encoding
    case packaging
    case finished
}

public struct WallpaperExportProgress: Equatable, Sendable {
    public let phase: WallpaperExportPhase
    public let completedFrames: Int
    public let totalFrames: Int
    public let fraction: Double

    public init(phase: WallpaperExportPhase, completedFrames: Int, totalFrames: Int) {
        self.phase = phase
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
        self.fraction = totalFrames > 0 ? min(1, max(0, Double(completedFrames) / Double(totalFrames))) : 0
    }
}

public struct WallpaperExportResult: Equatable, Sendable {
    public let outputURL: URL
    public let format: WallpaperExportFormat
    public let pixelSize: PixelSize
    public let frameCount: Int
    public let frameRate: Int
    public let duration: Double
    public let byteSize: Int64
    public let frameDirectoryURL: URL?
    public let notes: [String]

    public init(outputURL: URL, format: WallpaperExportFormat, pixelSize: PixelSize,
                frameCount: Int, frameRate: Int, duration: Double, byteSize: Int64,
                frameDirectoryURL: URL?, notes: [String]) {
        self.outputURL = outputURL
        self.format = format
        self.pixelSize = pixelSize
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.duration = duration
        self.byteSize = byteSize
        self.frameDirectoryURL = frameDirectoryURL
        self.notes = notes
    }
}

public enum WallpaperExportError: LocalizedError, Equatable {
    case unsupportedItemKind(String)
    case frameProviderUnavailable(String)
    case frameProviderFailed(String)
    case frameProviderReturnedNoFrame(Int)
    case sourceUnavailable(String)
    case imageUnreadable(String)
    case invalidResolution(PixelSize)
    case sourceEndedEarly(Int, Int)
    case archiveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedItemKind(let kind):
            return String(localized: "This wallpaper type cannot be exported.") + " (\(kind))"
        case .frameProviderUnavailable(let reason):
            return String(localized: "This wallpaper needs a live frame source that is not connected yet.") + " " + reason
        case .frameProviderFailed(let reason):
            return String(localized: "The wallpaper renderer failed while exporting.") + " " + reason
        case .frameProviderReturnedNoFrame(let index):
            return String(localized: "The wallpaper renderer did not return a frame.") + " (\(index))"
        case .sourceUnavailable(let reason):
            return String(localized: "The wallpaper source could not be read.") + " " + reason
        case .imageUnreadable(let reason):
            return String(localized: "The wallpaper image could not be opened.") + " " + reason
        case .invalidResolution(let size):
            return String(localized: "The export resolution is not usable.") + " (\(size))"
        case .sourceEndedEarly(let rendered, let expected):
            return String(localized: "The source ended before every frame was rendered.") + " (\(rendered)/\(expected))"
        case .archiveFailed(let reason):
            return String(localized: "The export archive could not be written.") + " " + reason
        }
    }
}

public final class WallpaperExportService {
    public init() {}

    public func export(
        item: WallpaperItem,
        sourceURL: URL,
        settings: WallpaperExportSettings,
        frameProvider: WallpaperFrameProvider? = nil,
        progress: (@Sendable (WallpaperExportProgress) -> Void)? = nil
    ) async throws -> WallpaperExportResult {
        try Task.checkCancellation()
        try settings.validate()
        report(.preparing, completed: 0, total: 0, progress: progress)

        let devicePixelSize = await MainActor.run { ExportDevice.screenPixelSize }
        let pixelSize = settings.targetPixelSize(devicePixelSize: devicePixelSize)
        guard pixelSize.isPositive else { throw WallpaperExportError.invalidResolution(pixelSize) }

        let source = try await prepareSource(item: item, sourceURL: sourceURL, frameProvider: frameProvider)
        var notes: [String] = []
        let duration = effectiveDuration(settings: settings, source: source, notes: &notes)
        let timeline = ExportTimeline(frameRate: settings.frameRate, duration: duration)
        guard timeline.frameCount > 0 else {
            throw WallpaperExportError.invalidResolution(pixelSize)
        }

        let fillsBackground: Bool
        switch settings.format {
        case .movie, .tendies:
            fillsBackground = true
        case .imageSequence:
            fillsBackground = settings.imageFormat == .jpeg
        }
        let plan = ExportRenderPlan(
            pixelSize: pixelSize,
            aspectMode: settings.aspectMode,
            zoom: settings.zoom,
            offsetX: settings.offsetX,
            offsetY: settings.offsetY,
            backgroundRed: settings.backgroundRed,
            backgroundGreen: settings.backgroundGreen,
            backgroundBlue: settings.backgroundBlue,
            fillsBackground: fillsBackground)
        let compositor = FrameCompositor(plan: plan)

        var providerPrepared = false
        if case .provider(let provider, _) = source {
            do {
                try await provider.prepareForExport()
                providerPrepared = true
            } catch {
                throw WallpaperExportError.frameProviderFailed(error.localizedDescription)
            }
        }

        do {
            let result: WallpaperExportResult
            switch settings.format {
            case .movie:
                result = try await exportMovie(item: item, source: source, timeline: timeline,
                                               compositor: compositor, settings: settings,
                                               pixelSize: pixelSize, notes: notes, progress: progress)
            case .imageSequence:
                result = try await exportImageSequence(item: item, source: source, timeline: timeline,
                                                       compositor: compositor, settings: settings,
                                                       pixelSize: pixelSize, notes: notes, progress: progress)
            case .tendies:
                result = try await exportTendies(item: item, source: source, timeline: timeline,
                                                 compositor: compositor, settings: settings,
                                                 pixelSize: pixelSize, notes: notes, progress: progress)
            }
            if providerPrepared, case .provider(let provider, _) = source {
                await provider.finishExport()
            }
            report(.finished, completed: timeline.frameCount, total: timeline.frameCount, progress: progress)
            return result
        } catch {
            if providerPrepared, case .provider(let provider, _) = source {
                await provider.finishExport()
            }
            throw error
        }
    }

    // MARK: - Sources

    private enum PreparedSource {
        case movie(MovieFrameSource)
        case provider(WallpaperFrameProvider, duration: CMTime?)
        case still(CGImage)
    }

    private func prepareSource(item: WallpaperItem,
                               sourceURL: URL,
                               frameProvider: WallpaperFrameProvider?) async throws -> PreparedSource {
        switch item.kind {
        case .video:
            let url = try sourceFileURL(sourceURL: sourceURL, entryFile: item.entryFile)
            let movie = try await MovieFrameSource.open(url: url)
            return .movie(movie)
        case .image:
            // Pixiv may use a bounded display image for playback; export the retained original.
            let url = try sourceFileURL(sourceURL: sourceURL, entryFile: item.pixiv?.file ?? item.entryFile)
            guard let image = UIImage(contentsOfFile: url.path)?.cgImage else {
                throw WallpaperExportError.imageUnreadable(url.lastPathComponent)
            }
            return .still(image)
        case .scene, .web:
            guard let frameProvider else {
                throw WallpaperExportError.frameProviderUnavailable(
                    String(localized: "The renderer or media layer has not supplied a frame provider for this wallpaper, so no real frames can be rendered. The preview still is not exported in its place."))
            }
            let duration = await frameProvider.duration
            return .provider(frameProvider, duration: duration)
        }
    }

    private func sourceFileURL(sourceURL: URL, entryFile: String) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw WallpaperExportError.sourceUnavailable(sourceURL.lastPathComponent)
        }
        let resolved: URL
        if isDirectory.boolValue {
            resolved = sourceURL.appendingPathComponent(entryFile)
        } else {
            resolved = sourceURL
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw WallpaperExportError.sourceUnavailable(resolved.lastPathComponent)
        }
        return resolved
    }

    private func effectiveDuration(settings: WallpaperExportSettings,
                                   source: PreparedSource,
                                   notes: inout [String]) -> Double {
        var duration = settings.duration
        switch source {
        case .movie(let movie):
            let available = movie.info.duration.seconds
            if available.isFinite, available > 0, available < duration {
                duration = available
                notes.append(String(localized: "The source video is shorter than the selected duration; the whole source is exported."))
            }
        case .provider(_, let providerDuration):
            if let providerDuration,
               providerDuration.isNumeric,
               providerDuration.seconds.isFinite,
               providerDuration.seconds > 0,
               providerDuration.seconds < duration {
                duration = providerDuration.seconds
                notes.append(String(localized: "The wallpaper's own duration is shorter than the selected duration; it is exported in full."))
            }
        case .still:
            break
        }
        return duration
    }

    // MARK: - Frame loop

    private func renderFrames(
        source: PreparedSource,
        timeline: ExportTimeline,
        compositor: FrameCompositor,
        progress: (@Sendable (WallpaperExportProgress) -> Void)?,
        consume: (Int, CIImage) async throws -> Void
    ) async throws {
        if case .movie(let movie) = source {
            try movie.start()
        }
        defer {
            if case .movie(let movie) = source { movie.close() }
        }

        report(.rendering, completed: 0, total: timeline.frameCount, progress: progress)
        for index in 0..<timeline.frameCount {
            try Task.checkCancellation()
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(timeline.frameRate))
            let image: CIImage
            switch source {
            case .movie(let movie):
                guard let buffer = try movie.frame(at: time) else {
                    throw WallpaperExportError.sourceEndedEarly(index, timeline.frameCount)
                }
                image = try compositor.render(source: buffer, preferredTransform: movie.info.preferredTransform)
            case .provider(let provider, _):
                guard let buffer = try await provider.frame(at: time) else {
                    throw WallpaperExportError.frameProviderReturnedNoFrame(index)
                }
                image = try compositor.render(source: buffer)
            case .still(let cgImage):
                image = try compositor.render(source: cgImage)
            }
            try await consume(index, image)
            report(.encoding, completed: index + 1, total: timeline.frameCount, progress: progress)
        }
    }

    // MARK: - Movie

    private func exportMovie(
        item: WallpaperItem,
        source: PreparedSource,
        timeline: ExportTimeline,
        compositor: FrameCompositor,
        settings: WallpaperExportSettings,
        pixelSize: PixelSize,
        notes: [String],
        progress: (@Sendable (WallpaperExportProgress) -> Void)?
    ) async throws -> WallpaperExportResult {
        let exports = try WallpaperExportLocation.exportsDirectory()
        let outputURL = WallpaperExportLocation.uniqueFileURL(
            baseName: ExportNaming.fileBaseName(title: item.title, format: .movie, codec: settings.codec),
            fileExtension: "mp4",
            in: exports)
        let bitrate = settings.quality.averageBitrate(pixelSize: pixelSize,
                                                      frameRate: timeline.frameRate,
                                                      codec: settings.codec)
        let writer: MovieExportWriter
        do {
            writer = try MovieExportWriter(outputURL: outputURL,
                                           pixelSize: pixelSize,
                                           codec: settings.codec,
                                           frameRate: timeline.frameRate,
                                           averageBitrate: bitrate)
        } catch let error as MovieExportError {
            throw error
        }
        try writer.start()
        do {
            try await renderFrames(source: source, timeline: timeline, compositor: compositor, progress: progress) { index, image in
                try await writer.append(image, compositor: compositor, frameIndex: index)
            }
            report(.packaging, completed: timeline.frameCount, total: timeline.frameCount, progress: progress)
            let url = try await writer.finish()
            return WallpaperExportResult(
                outputURL: url,
                format: .movie,
                pixelSize: pixelSize,
                frameCount: timeline.frameCount,
                frameRate: timeline.frameRate,
                duration: timeline.actualDuration,
                byteSize: WallpaperExportLocation.byteSize(of: url),
                frameDirectoryURL: nil,
                notes: notes)
        } catch {
            writer.cancel()
            throw error
        }
    }

    // MARK: - Image sequence

    private func exportImageSequence(
        item: WallpaperItem,
        source: PreparedSource,
        timeline: ExportTimeline,
        compositor: FrameCompositor,
        settings: WallpaperExportSettings,
        pixelSize: PixelSize,
        notes: [String],
        progress: (@Sendable (WallpaperExportProgress) -> Void)?
    ) async throws -> WallpaperExportResult {
        let exports = try WallpaperExportLocation.exportsDirectory()
        let directory = WallpaperExportLocation.uniqueDirectoryURL(
            baseName: ExportNaming.fileBaseName(title: item.title, format: .imageSequence, codec: settings.codec),
            in: exports)
        let writer: ImageSequenceExportWriter
        do {
            writer = try ImageSequenceExportWriter(directory: directory,
                                                   imageFormat: settings.imageFormat,
                                                   quality: settings.imageQuality,
                                                   compositor: compositor)
        } catch let error as ImageSequenceExportError {
            throw error
        }

        var notes = notes
        do {
            try await renderFrames(source: source, timeline: timeline, compositor: compositor, progress: progress) { index, image in
                try writer.append(image, frameIndex: index)
            }
            report(.packaging, completed: timeline.frameCount, total: timeline.frameCount, progress: progress)
            let frameDirectory = writer.finish()
            var outputURL = frameDirectory
            if settings.zipImageSequence {
                let zipURL = WallpaperExportLocation.uniqueFileURL(
                    baseName: ExportNaming.sanitized(item.title, fallback: "Wallpaper") + "-Frames",
                    fileExtension: "zip",
                    in: exports)
                let archive = try ZipArchiveWriter(outputURL: zipURL)
                let frameURLs = try FileManager.default.contentsOfDirectory(
                    at: frameDirectory,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles])
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for frameURL in frameURLs {
                    let data = try Data(contentsOf: frameURL)
                    try archive.addFile(path: frameURL.lastPathComponent, data: data)
                }
                try archive.finish()
                outputURL = zipURL
                notes.append(String(localized: "The numbered frames are also packaged in a ZIP archive for sharing."))
            }
            return WallpaperExportResult(
                outputURL: outputURL,
                format: .imageSequence,
                pixelSize: pixelSize,
                frameCount: writer.writtenFrames,
                frameRate: timeline.frameRate,
                duration: timeline.actualDuration,
                byteSize: WallpaperExportLocation.byteSize(of: outputURL),
                frameDirectoryURL: frameDirectory,
                notes: notes)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    // MARK: - Tendies

    private func exportTendies(
        item: WallpaperItem,
        source: PreparedSource,
        timeline: ExportTimeline,
        compositor: FrameCompositor,
        settings: WallpaperExportSettings,
        pixelSize: PixelSize,
        notes: [String],
        progress: (@Sendable (WallpaperExportProgress) -> Void)?
    ) async throws -> WallpaperExportResult {
        let exports = try WallpaperExportLocation.exportsDirectory()
        let requestedName = settings.tendies.wallpaperName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = requestedName.isEmpty ? item.title : requestedName
        let identifier = settings.tendies.identifier > 0
            ? settings.tendies.identifier
            : Int.random(in: 10_000...99_999)
        let descriptor = TendiesWallpaperDescriptor(
            screenClass: settings.tendies.screenClass,
            displayName: displayName,
            family: settings.tendies.family,
            identifier: identifier,
            pixelSize: pixelSize,
            frameCount: timeline.frameCount,
            frameRate: Double(timeline.frameRate),
            animationEncoding: settings.tendies.animationEncoding)
        let outputURL = WallpaperExportLocation.uniqueFileURL(
            baseName: ExportNaming.sanitized(displayName, fallback: "Wallpaper"),
            fileExtension: "tendies",
            in: exports)

        let writer: TendiesExportWriter
        do {
            writer = try TendiesExportWriter(
                descriptor: descriptor,
                outputURL: outputURL,
                compositor: compositor,
                jpegQuality: settings.tendies.frameQuality,
                includesDisplayNameMetadata: settings.tendies.includesDisplayNameMetadata)
        } catch let error as TendiesExportError {
            throw error
        }

        var notes = notes
        notes.append(String(localized: "iPad screen class: ") + descriptor.screenClass.name)
        do {
            try await renderFrames(source: source, timeline: timeline, compositor: compositor, progress: progress) { index, image in
                try writer.append(image, frameIndex: index)
            }
            report(.packaging, completed: timeline.frameCount, total: timeline.frameCount, progress: progress)
            let url = try writer.finish()
            return WallpaperExportResult(
                outputURL: url,
                format: .tendies,
                pixelSize: pixelSize,
                frameCount: writer.writtenFrames,
                frameRate: timeline.frameRate,
                duration: timeline.actualDuration,
                byteSize: WallpaperExportLocation.byteSize(of: url),
                frameDirectoryURL: nil,
                notes: notes)
        } catch {
            writer.cancel()
            throw error
        }
    }

    // MARK: - Progress

    private func report(_ phase: WallpaperExportPhase,
                        completed: Int,
                        total: Int,
                        progress: (@Sendable (WallpaperExportProgress) -> Void)?) {
        progress?(WallpaperExportProgress(phase: phase, completedFrames: completed, totalFrames: total))
    }
}
