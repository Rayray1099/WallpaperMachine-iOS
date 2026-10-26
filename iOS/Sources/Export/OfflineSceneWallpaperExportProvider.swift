// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// A single native manual-clock session. Encoding may be slower than real time:
/// native advances by index/fps, not by elapsed capture or JPEG-encoding time.
/// There is deliberately no fallback to live snapshots or relaxed drift checks.
@MainActor
final class OfflineSceneWallpaperExportProvider: WallpaperFrameProvider {
    private let source: OfflineSceneFrameProviding
    private let outputSize: CGSize
    private let frameRate: Int
    private var prepared = false
    private var ended = false
    private var preparing = false
    private var nextIndex = 0
    private var measuredSize: CGSize = .zero
    private var primedFrame: CVPixelBuffer?
    private var generation = UUID()
    private var activeCapture: OfflineSceneProviderRequest?

    init(source: OfflineSceneFrameProviding, outputSize: CGSize, frameRate: Int) {
        self.source = source
        self.outputSize = outputSize
        self.frameRate = frameRate
    }

    var frameSize: CGSize { measuredSize }
    var duration: CMTime? { nil }

    func prepareForExport() async throws {
        try Task.checkCancellation()
        guard !ended, !prepared, !preparing else { throw OfflineSceneCaptureError.sessionEnded }
        preparing = true
        defer { preparing = false }
        do {
            guard SceneCaptureLimits.native.validatedSize(outputSize) == outputSize else { throw SceneFrameCaptureError.invalidSize }
            guard (1...SceneCaptureLimits.maximumFrameRate).contains(frameRate), source.offlineFrameRate == frameRate else {
                throw OfflineSceneCaptureError.invalidSequence
            }
            // Exactly one native index-0 request. The service's first frame(0)
            // consumes this primed buffer instead of advancing simulation again.
            let frame = try await capture(index: 0)
            primedFrame = try MediaCaptureFrameProvider.pixelBuffer(from: frame.image)
            try Task.checkCancellation()
            guard !ended else { throw CancellationError() }
            measuredSize = frame.pixelSize
            prepared = true
        } catch {
            await finishExport()
            throw error
        }
    }

    func frame(at time: CMTime) async throws -> CVPixelBuffer? {
        try Task.checkCancellation()
        guard prepared, !ended else { throw WallpaperFrameProviderError.notPrepared }
        guard activeCapture == nil else { throw SceneFrameCaptureError.busy }
        do {
            guard nextIndex <= OfflineSceneFrameCapture.maximumFrameIndex,
                  time.isNumeric, time.seconds.isFinite,
                  CMTimeCompare(time, CMTime(value: CMTimeValue(nextIndex), timescale: CMTimeScale(frameRate))) == 0 else {
                throw OfflineSceneCaptureError.invalidSequence
            }
            if nextIndex == 0 {
                guard let frame = primedFrame else { throw WallpaperFrameProviderError.notPrepared }
                primedFrame = nil
                nextIndex += 1
                return frame
            }
            let session = generation
            let frame = try await capture(index: nextIndex)
            let buffer = try MediaCaptureFrameProvider.pixelBuffer(from: frame.image)
            try Task.checkCancellation()
            guard generation == session, prepared, !ended else { throw CancellationError() }
            nextIndex += 1
            return buffer
        } catch {
            await finishExport()
            throw error
        }
    }

    func finishExport() async {
        guard !ended else { return }
        ended = true
        generation = UUID()
        activeCapture?.cancel()
        activeCapture = nil
        primedFrame = nil
        prepared = false
        measuredSize = .zero
        // This is synchronous by contract: native teardown owns/drains its GPU
        // work before the surrounding controller releases its assets lease.
        source.finishOfflineCapture()
    }

    private func capture(index: Int) async throws -> MediaFrame {
        try Task.checkCancellation()
        guard !ended, source.isOfflineFrameCaptureReady else { throw SceneFrameCaptureError.notReady }
        let session = generation
        let request = OfflineSceneProviderRequest()
        activeCapture = request
        defer { if activeCapture === request { activeCapture = nil } }
        let frame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start(source: source, index: index, frameRate: frameRate, outputSize: outputSize,
                              continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        try Task.checkCancellation()
        guard generation == session, !ended else { throw CancellationError() }
        guard source.isOfflineFrameCaptureReady else { throw SceneFrameCaptureError.notReady }
        guard frame.source == .scene, frame.pixelSize == outputSize,
              let time = frame.presentationTime, time.isNumeric,
              CMTimeCompare(time, CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))) == 0 else {
            throw SceneFrameCaptureError.invalidResponse
        }
        return frame
    }
}

@MainActor
private final class OfflineSceneProviderRequest {
    private var continuation: CheckedContinuation<MediaFrame, Error>?
    private var task: Task<Void, Never>?
    private var completed = false

    func start(source: OfflineSceneFrameProviding, index: Int, frameRate: Int, outputSize: CGSize,
               continuation: CheckedContinuation<MediaFrame, Error>) {
        guard !completed else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let frame = try await source.captureOfflineFrame(index: index, frameRate: frameRate, maximumSize: outputSize)
                try Task.checkCancellation()
                self?.complete(.success(frame))
            } catch { self?.complete(.failure(error)) }
        }
    }

    func cancel() { complete(.failure(CancellationError())) }
    private func complete(_ result: Result<MediaFrame, Error>) {
        guard !completed else { return }
        completed = true
        let continuation = continuation
        self.continuation = nil
        task?.cancel()
        task = nil
        continuation?.resume(with: result)
    }
}
