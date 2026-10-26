// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UIKit

/// Owns the export-only native surface and its shared-assets reader lease. No
/// state is published from representable lifecycle callbacks.
@MainActor
final class SceneWallpaperExportController {
    let url: URL
    let properties: [String: WallpaperProperty]
    private let settings: PlaybackSettings
    private weak var canvas: SceneExportCanvas?
    private var lease: UUID?
    private var currentProvider: SceneLeasedExportProvider?
    private var generation = UUID()
    private var exportFrameRate: Int?
    private var appliedSettings: PlaybackSettings?
    private(set) var outputSize: CGSize

    init(url: URL, properties: [String: WallpaperProperty], settings: PlaybackSettings, outputSize: CGSize) {
        self.url = url
        self.properties = properties
        self.settings = settings
        self.outputSize = outputSize
    }

    private var captureSettings: PlaybackSettings {
        var result = settings
        result.microphoneEnabled = false
        result.isMuted = true
        result.volume = 0
        result.renderScale = 1
        result.framesPerSecond = exportFrameRate ?? min(SceneCaptureLimits.maximumFrameRate, max(1, settings.framesPerSecond))
        return result
    }

    func makeCanvas() -> SceneExportCanvas {
        let settings = captureSettings
        appliedSettings = settings
        let canvas = SceneExportCanvas(surface: SceneMetalSurface(url: url, settings: settings, properties: properties, exportFrameRate: settings.framesPerSecond),
                                       outputSize: outputSize)
        self.canvas = canvas
        return canvas
    }

    func update(_ canvas: SceneExportCanvas) {
        guard self.canvas === canvas else { return }
        canvas.outputSize = outputSize
        let settings = captureSettings
        if appliedSettings != settings {
            appliedSettings = settings
            canvas.surface.apply(url: url, settings: settings, properties: properties)
        }
    }

    func detach(_ canvas: SceneExportCanvas) {
        guard self.canvas === canvas else { return }
        self.canvas = nil
        generation = UUID()
        canvas.surface.retire() // synchronously cancels any mailbox await
        let provider = currentProvider
        let token = lease
        Task { @MainActor in
            await provider?.finishExport()
            if provider == nil, let token { self.releaseLease(token: token) }
        }
    }

    func prepare(outputSize: CGSize, frameRate: Int, frameCount: Int) async throws -> WallpaperFrameProvider {
        try Task.checkCancellation()
        guard lease == nil else { throw SceneFrameCaptureError.busy }
        guard SceneCaptureLimits.native.validatedSize(outputSize) == outputSize else { throw SceneFrameCaptureError.invalidSize }
        guard (1...SceneCaptureLimits.maximumFrameRate).contains(frameRate) else {
            throw WallpaperExportValidationError.invalidFrameRate(frameRate)
        }
        guard (1...(OfflineSceneFrameCapture.maximumFrameIndex + 1)).contains(frameCount) else {
            throw OfflineSceneCaptureError.invalidSequence
        }
        let coordinator = SceneSharedAssetsCoordinator.shared
        let token = try coordinator.beginExport()
        lease = token
        generation = UUID()
        let session = generation
        self.outputSize = outputSize
        exportFrameRate = frameRate
        do {
            if let canvas {
                // Every export starts a fresh native manual-clock session,
                // including repeated exports or a changed immutable frame rate.
                let settings = captureSettings
                appliedSettings = settings
                canvas.replaceSurface(SceneMetalSurface(url: url, settings: settings, properties: properties,
                                                         exportFrameRate: frameRate))
                canvas.outputSize = outputSize
                canvas.layoutNativeSurface()
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                guard generation == session, lease == token else { throw CancellationError() }
                if let canvas {
                    canvas.layoutNativeSurface()
                    if let failure = canvas.surface.frameCaptureFailure {
                        throw WallpaperFrameProviderError.unavailable(failure)
                    }
                    if canvas.window != nil, canvas.surface.isOfflineFrameCaptureReady,
                       canvas.surface.nativeCapturePixelSize == outputSize {
                        let provider = SceneLeasedExportProvider(
                            base: OfflineSceneWallpaperExportProvider(source: canvas.surface, outputSize: outputSize, frameRate: frameRate),
                            release: { [weak self] in
                                coordinator.endExport(token: token)
                                self?.releaseLease(token: token)
                            })
                        currentProvider = provider
                        return provider
                    }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw WallpaperFrameProviderError.unavailable(NSLocalizedString("scene.capture.loadTimeout", comment: ""))
        } catch {
            if lease == token { canvas?.surface.finishOfflineCapture() }
            releaseLease(token: token)
            throw error
        }
    }

    func finishExport() async {
        generation = UUID()
        let token = lease
        let provider = currentProvider
        await provider?.finishExport()
        if let token, lease == token {
            canvas?.surface.finishOfflineCapture()
            releaseLease(token: token)
        }
    }

    private func releaseLease(token: UUID? = nil) {
        guard let current = lease, token == nil || current == token else { return }
        lease = nil
        currentProvider = nil
        exportFrameRate = nil
        SceneSharedAssetsCoordinator.shared.endExport(token: current)
    }
}

/// The Metal surface keeps full native point bounds even though its visual
/// preview is small. A view transform only scales the preview; it never changes
/// the layer's drawable or asks the renderer to invent pixels by upscaling.
@MainActor
final class SceneExportCanvas: UIView {
    private(set) var surface: SceneMetalSurface
    var outputSize: CGSize { didSet { if outputSize != oldValue { setNeedsLayout() } } }

    init(surface: SceneMetalSurface, outputSize: CGSize) {
        self.surface = surface
        self.outputSize = outputSize
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .black
        addSubview(surface)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func replaceSurface(_ surface: SceneMetalSurface) {
        self.surface.retire()
        self.surface.removeFromSuperview()
        self.surface = surface
        addSubview(surface)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutNativeSurface()
    }

    func layoutNativeSurface() {
        guard SceneCaptureLimits.native.validatedSize(outputSize) == outputSize,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard scale.isFinite, scale > 0 else { return }
        let nativeSize = CGSize(width: outputSize.width / scale, height: outputSize.height / scale)
        let previewScale = min(bounds.width / nativeSize.width, bounds.height / nativeSize.height)
        let nativeBounds = CGRect(origin: .zero, size: nativeSize)
        let changed = surface.bounds != nativeBounds || surface.window != nil && surface.nativeCapturePixelSize != outputSize
        if surface.bounds != nativeBounds { surface.bounds = nativeBounds }
        surface.center = CGPoint(x: bounds.midX, y: bounds.midY)
        surface.transform = CGAffineTransform(scaleX: previewScale, y: previewScale)
        if changed { surface.setNeedsLayout() }
        surface.layoutIfNeeded()
    }
}

@MainActor
struct SceneWallpaperExportPreview: UIViewRepresentable {
    let controller: SceneWallpaperExportController
    func makeCoordinator() -> SceneWallpaperExportController { controller }
    func makeUIView(context: Context) -> SceneExportCanvas { controller.makeCanvas() }
    func updateUIView(_ view: SceneExportCanvas, context: Context) { controller.update(view) }
    static func dismantleUIView(_ view: SceneExportCanvas, coordinator: SceneWallpaperExportController) { coordinator.detach(view) }
}

/// Keeps the resource lease until the service has finished the provider. A
/// failed prepare also releases it: the service does not finish failed prepares.
@MainActor
private final class SceneLeasedExportProvider: WallpaperFrameProvider {
    private let base: OfflineSceneWallpaperExportProvider
    private var release: (() -> Void)?
    private var finished = false

    init(base: OfflineSceneWallpaperExportProvider, release: @escaping () -> Void) {
        self.base = base
        self.release = release
    }
    var frameSize: CGSize { base.frameSize }
    var duration: CMTime? { nil }
    func prepareForExport() async throws {
        guard !finished else { throw WallpaperFrameProviderError.notPrepared }
        do { try await base.prepareForExport() }
        catch { await finishExport(); throw error }
    }
    func frame(at time: CMTime) async throws -> CVPixelBuffer? {
        guard !finished else { throw WallpaperFrameProviderError.notPrepared }
        return try await base.frame(at: time)
    }
    func finishExport() async {
        guard !finished else { return }
        finished = true
        await base.finishExport()
        let release = release
        self.release = nil
        release?()
    }
}
