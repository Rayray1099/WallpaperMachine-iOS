// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import CoreMedia
import CoreVideo
import Dispatch
import Foundation

/// Samples real native scene readbacks on a monotonic, live clock. This is not
/// an offline scene seek API and does not claim that Metal readback sustains
/// 60fps. Late capture fails rather than silently lowering FPS or repeating a
/// preview image. The attached host owns native readiness, geometry and lifetime.
@MainActor
final class SceneWallpaperExportProvider: WallpaperFrameProvider {
    private let source: MediaFrameProviding
    private let outputSize: CGSize
    private let now: @MainActor () -> UInt64
    private let sleep: @MainActor (UInt64) async throws -> Void
    private var prepared = false
    private var measuredSize: CGSize = .zero
    private var startedAt: UInt64?
    private var lastTimestamp: Double?
    private var generation = UUID()
    private var activeOperation: UUID?
    private var activeCapture: SceneExportCaptureRequest?
    private var activeWait: SceneExportWaitRequest?

    init(source: MediaFrameProviding, outputSize: CGSize,
         now: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.source = source
        self.outputSize = outputSize
        self.now = now
        self.sleep = sleep
    }

    var frameSize: CGSize { measuredSize }
    var duration: CMTime? { nil }

    func prepareForExport() async throws {
        await finishExport()
        try Task.checkCancellation()
        guard SceneCaptureLimits.native.validatedSize(outputSize) == outputSize else {
            throw SceneFrameCaptureError.invalidSize
        }
        let session = generation
        let operation = UUID()
        activeOperation = operation
        defer { if activeOperation == operation { activeOperation = nil } }
        do {
            let frame = try await capture(session: session)
            try Task.checkCancellation()
            guard generation == session else { throw CancellationError() }
            measuredSize = frame.pixelSize
            prepared = true
        } catch {
            if generation == session { reset() }
            throw error
        }
    }

    func frame(at time: CMTime) async throws -> CVPixelBuffer? {
        try Task.checkCancellation()
        guard prepared else { throw WallpaperFrameProviderError.notPrepared }
        guard activeOperation == nil else { throw SceneFrameCaptureError.busy }
        let session = generation
        let operation = UUID()
        activeOperation = operation
        defer { if activeOperation == operation { activeOperation = nil } }
        do {
            guard time.isNumeric, time.seconds.isFinite, time.seconds >= 0,
                  lastTimestamp.map({ time.seconds > $0 }) ?? true else {
                throw WallpaperFrameProviderError.unavailable(NSLocalizedString("scene.capture.invalidTime", comment: ""))
            }
            if startedAt == nil { startedAt = now() }
            guard let origin = startedAt,
                  let wait = LiveCaptureTiming.waitNanoseconds(origin: origin, now: now(), seconds: time.seconds) else {
                throw tooSlow()
            }
            if wait > 0 { try await waitForFrame(nanoseconds: wait) }
            try Task.checkCancellation()
            guard generation == session, prepared else { throw CancellationError() }
            // A wake after background suspension must not sample an old timeline.
            guard LiveCaptureTiming.waitNanoseconds(origin: origin, now: now(), seconds: time.seconds) != nil else {
                throw tooSlow()
            }
            let frame = try await capture(session: session)
            let buffer = try MediaCaptureFrameProvider.pixelBuffer(from: frame.image)
            try Task.checkCancellation()
            guard generation == session, prepared else { throw CancellationError() }
            // Include readback and CPU conversion, even on the final/only frame.
            guard LiveCaptureTiming.waitNanoseconds(origin: origin, now: now(), seconds: time.seconds) != nil else {
                throw tooSlow()
            }
            lastTimestamp = time.seconds
            return buffer
        } catch {
            if generation == session { reset() }
            throw error
        }
    }

    func finishExport() async { reset() }

    private func reset() {
        generation = UUID()
        activeCapture?.cancel()
        activeCapture = nil
        activeWait?.cancel()
        activeWait = nil
        activeOperation = nil
        prepared = false
        measuredSize = .zero
        startedAt = nil
        lastTimestamp = nil
    }

    private func waitForFrame(nanoseconds: UInt64) async throws {
        let request = SceneExportWaitRequest()
        activeWait = request
        defer { if activeWait === request { activeWait = nil } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start(nanoseconds: nanoseconds, sleep: sleep, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
    }

    private func capture(session: UUID) async throws -> MediaFrame {
        try Task.checkCancellation()
        guard source.frameSource == .scene else {
            throw WallpaperFrameProviderError.unavailable(NSLocalizedString("scene.capture.wrongSource", comment: ""))
        }
        guard generation == session else { throw CancellationError() }
        guard source.isFrameCaptureReady else { throw SceneFrameCaptureError.notReady }
        let request = SceneExportCaptureRequest()
        activeCapture = request
        defer { if activeCapture === request { activeCapture = nil } }
        let frame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The native mailbox helper owns its single 10-second timeout.
                // Do not race it against a second timer or ask it to seek time.
                request.start(source: source, maximumSize: outputSize, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        try Task.checkCancellation()
        guard generation == session else { throw CancellationError() }
        guard source.isFrameCaptureReady else { throw SceneFrameCaptureError.notReady }
        guard source.frameSource == .scene, frame.source == .scene, frame.presentationTime == nil else {
            throw WallpaperFrameProviderError.renderFailed(NSLocalizedString("scene.capture.wrongSource", comment: ""))
        }
        // Native readback captures the layer's actual drawable-sized composition.
        // A small preview must never masquerade as native output. The host must
        // separately configure renderScale=1: drawable dimensions cannot prove
        // the renderer's internal scene-target resolution.
        guard frame.pixelSize == outputSize else {
            throw WallpaperFrameProviderError.renderFailed(NSLocalizedString("scene.capture.resolutionMismatch", comment: ""))
        }
        return frame
    }

    private func tooSlow() -> WallpaperFrameProviderError {
        .renderFailed(NSLocalizedString("scene.capture.tooSlow", comment: ""))
    }
}

/// Finish/cancellation must interrupt pacing too, including a long future tick.
@MainActor
private final class SceneExportWaitRequest {
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: Task<Void, Never>?
    private var completed = false

    func start(nanoseconds: UInt64, sleep: @escaping @MainActor (UInt64) async throws -> Void,
               continuation: CheckedContinuation<Void, Error>) {
        guard !completed else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        task = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                try await sleep(nanoseconds)
                try Task.checkCancellation()
                self?.complete(.success(()))
            } catch { self?.complete(.failure(error)) }
        }
    }

    func cancel() { complete(.failure(CancellationError())) }

    private func complete(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        let continuation = continuation
        self.continuation = nil
        task?.cancel()
        task = nil
        continuation?.resume(with: result)
    }
}

/// A cancellation/finish relay only. The real source owns native timeout and
/// readback invalidation. Late completions can neither revive a finished export
/// nor resume a cancelled continuation twice.
@MainActor
private final class SceneExportCaptureRequest {
    private var continuation: CheckedContinuation<MediaFrame, Error>?
    private var task: Task<Void, Never>?
    private var completed = false

    func start(source: MediaFrameProviding, maximumSize: CGSize, continuation: CheckedContinuation<MediaFrame, Error>) {
        guard !completed else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let frame = try await source.captureFrame(at: nil, maximumSize: maximumSize)
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
