// SPDX-License-Identifier: GPL-3.0-only
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import SwiftUI
import UIKit

/// Keeps the capture surface attached to the export sheet, outside recycled Form rows.
/// This is deliberately not observable: representable lifecycle callbacks must not
/// publish SwiftUI state while SwiftUI is creating or dismantling the UIView.
@MainActor
final class WebWallpaperExportController {
    let url: URL
    let properties: [String: WallpaperProperty]
    let settings: PlaybackSettings
    private(set) var surface: WebWallpaperView?
    private var exportFrameRate: Int?

    init(url: URL, properties: [String: WallpaperProperty], settings: PlaybackSettings) {
        self.url = url
        self.properties = properties
        self.settings = settings
    }

    func attach(_ view: WebWallpaperView) {
        surface = view
        update(view)
    }

    func update(_ view: WebWallpaperView) {
        view.properties = properties
        var captureSettings = settings
        // Export never starts a microphone adapter or implies microphone consent.
        captureSettings.microphoneEnabled = false
        captureSettings.framesPerSecond = exportFrameRate ?? settings.framesPerSecond
        view.apply(settings: captureSettings)
    }

    func detach(_ view: WebWallpaperView) {
        guard surface === view else { return }
        surface = nil
    }

    func prepare(outputSize: CGSize, frameRate: Int) async throws -> WallpaperFrameProvider {
        guard let maximumSize = LiveCaptureLimits.boundedSize(outputSize) else {
            throw WallpaperFrameProviderError.unavailable(NSLocalizedString("export.web.invalidSize", comment: ""))
        }
        guard (1...LiveCaptureLimits.maximumFrameRate).contains(frameRate) else {
            throw WallpaperExportValidationError.invalidFrameRate(frameRate)
        }
        exportFrameRate = frameRate
        if let surface { update(surface) }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let surface {
                if case .failed(let error) = surface.loadState {
                    throw WallpaperFrameProviderError.unavailable(error.localizedDescription)
                }
                if surface.isFrameCaptureReady, surface.bounds.width > 0, surface.bounds.height > 0 {
                    // Only the service prepares/snapshots the provider. Doing so here
                    // as well captures twice and can overwrite its configured size.
                    return WebWallpaperExportProvider(source: surface, maximumSize: maximumSize)
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw WallpaperFrameProviderError.unavailable(
            NSLocalizedString("export.web.loadTimeout", comment: ""))
    }
}

@MainActor
struct WebWallpaperExportPreview: UIViewRepresentable {
    let controller: WebWallpaperExportController

    func makeCoordinator() -> WebWallpaperExportController { controller }

    func makeUIView(context: Context) -> WebWallpaperView {
        let view = WebWallpaperView(url: controller.url, properties: controller.properties)
        controller.attach(view)
        return view
    }

    func updateUIView(_ view: WebWallpaperView, context: Context) {
        controller.update(view)
    }

    static func dismantleUIView(_ view: WebWallpaperView, coordinator: WebWallpaperExportController) {
        coordinator.detach(view)
    }
}

/// Samples a live, attached source on a monotonic clock; it cannot seek WebKit.
@MainActor
final class WebWallpaperExportProvider: WallpaperFrameProvider {
    private let source: MediaFrameProviding
    private let maximumSize: CGSize
    private let now: () -> UInt64
    private let sleep: (UInt64) async throws -> Void
    private let snapshotTimeoutNanoseconds: UInt64
    private var prepared = false
    private var measuredSize: CGSize = .zero
    private var startedAt: UInt64?
    private var lastTimestamp: Double?
    private var activeCapture: WebExportCaptureRequest?

    init(source: MediaFrameProviding, maximumSize: CGSize,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         snapshotTimeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.source = source
        self.maximumSize = maximumSize
        self.now = now
        self.sleep = sleep
        self.snapshotTimeoutNanoseconds = snapshotTimeoutNanoseconds
    }

    var frameSize: CGSize { measuredSize }
    var duration: CMTime? { nil }

    func prepareForExport() async throws {
        await finishExport()
        try Task.checkCancellation()
        guard LiveCaptureLimits.boundedSize(maximumSize) == maximumSize else {
            throw WallpaperFrameProviderError.unavailable(NSLocalizedString("export.web.invalidSize", comment: ""))
        }
        let frame = try await capture(at: nil)
        measuredSize = CGSize(width: frame.image.width, height: frame.image.height)
        prepared = true
    }

    func frame(at time: CMTime) async throws -> CVPixelBuffer? {
        try Task.checkCancellation()
        guard prepared else { throw WallpaperFrameProviderError.notPrepared }
        guard time.isNumeric, time.seconds.isFinite, time.seconds >= 0,
              lastTimestamp.map({ time.seconds > $0 }) ?? true else {
            throw WallpaperFrameProviderError.unavailable(NSLocalizedString("export.web.invalidTime", comment: ""))
        }
        if startedAt == nil { startedAt = now() }
        guard let origin = startedAt,
              let wait = LiveCaptureTiming.waitNanoseconds(origin: origin, now: now(), seconds: time.seconds) else {
            throw tooSlow()
        }
        if wait > 0 { try await sleep(wait) }
        try Task.checkCancellation()
        // Sleep can resume late (including after background suspension).
        guard LiveCaptureTiming.waitNanoseconds(origin: origin, now: now(), seconds: time.seconds) != nil else {
            throw tooSlow()
        }
        let frame = try await capture(at: time)
        guard prepared else { throw WallpaperFrameProviderError.notPrepared }
        let buffer = try MediaCaptureFrameProvider.pixelBuffer(from: frame.image)
        try Task.checkCancellation()
        // Check completion too: otherwise a slow final/only snapshot succeeds.
        guard LiveCaptureTiming.waitNanoseconds(origin: origin, now: now(), seconds: time.seconds) != nil else {
            throw tooSlow()
        }
        lastTimestamp = time.seconds
        return buffer
    }

    func finishExport() async {
        activeCapture?.cancel()
        activeCapture = nil
        prepared = false
        measuredSize = .zero
        startedAt = nil
        lastTimestamp = nil
    }

    private func capture(at time: CMTime?) async throws -> MediaFrame {
        try Task.checkCancellation()
        guard source.isFrameCaptureReady else {
            throw WallpaperFrameProviderError.unavailable(NSLocalizedString("export.web.notReady", comment: ""))
        }
        let request = WebExportCaptureRequest()
        activeCapture = request
        defer { if activeCapture === request { activeCapture = nil } }
        let frame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start(source: source, time: time, maximumSize: maximumSize,
                              timeoutNanoseconds: snapshotTimeoutNanoseconds, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
        try Task.checkCancellation()
        guard source.isFrameCaptureReady else {
            throw WallpaperFrameProviderError.unavailable(NSLocalizedString("export.web.notReady", comment: ""))
        }
        guard frame.image.width > 0, frame.image.height > 0 else {
            throw WallpaperFrameProviderError.renderFailed(NSLocalizedString("export.web.empty", comment: ""))
        }
        return frame
    }

    private func tooSlow() -> WallpaperFrameProviderError {
        .renderFailed(NSLocalizedString("export.web.tooSlow", comment: ""))
    }
}

/// WebKit's snapshot callback is not cancellable. End the await promptly and
/// ignore late callbacks, without a task group that waits for the losing capture.
@MainActor
private final class WebExportCaptureRequest {
    private var continuation: CheckedContinuation<MediaFrame, Error>?
    private var completed = false
    private var captureTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func start(source: MediaFrameProviding, time: CMTime?, maximumSize: CGSize,
               timeoutNanoseconds: UInt64, continuation: CheckedContinuation<MediaFrame, Error>) {
        guard !completed else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        captureTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                let frame = try await source.captureFrame(at: time, maximumSize: maximumSize)
                self?.complete(.success(frame))
            } catch { self?.complete(.failure(error)) }
        }
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            self?.complete(.failure(WallpaperFrameProviderError.unavailable(
                NSLocalizedString("export.web.captureTimeout", comment: ""))))
        }
    }

    func cancel() { complete(.failure(CancellationError())) }

    private func complete(_ result: Result<MediaFrame, Error>) {
        guard !completed else { return }
        completed = true
        let continuation = continuation
        self.continuation = nil
        captureTask?.cancel()
        timeoutTask?.cancel()
        captureTask = nil
        timeoutTask = nil
        continuation?.resume(with: result)
    }
}
