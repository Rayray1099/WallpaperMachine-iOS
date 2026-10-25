// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UIKit
import Metal
import QuartzCore

/// UIKit host for the original WallpaperMachine C++ Metal scene engine and Rust shaders.
/// No synthetic animation, video fallback, or preview-image substitution is used here.
struct SceneWallpaperView: UIViewRepresentable {
    let url: URL
    let settings: PlaybackSettings
    let properties: [String: WallpaperProperty]
    func makeUIView(context: Context) -> SceneMetalSurface {
        SceneMetalSurface(url: url, settings: settings, properties: properties)
    }
    func updateUIView(_ view: SceneMetalSurface, context: Context) {
        view.apply(url: url, settings: settings, properties: properties)
    }
    static func dismantleUIView(_ view: SceneMetalSurface, coordinator: ()) { view.shutdown() }
}

/// Narrow environment seams for deterministic UIKit host tests. Native calls still
/// use the real C ABI; only the isolated simulator test target links a recorder.
@MainActor
struct SceneHostEnvironment {
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var prepareResources: () throws -> SceneResourceDirectories = { try SceneResourceDirectories.prepare() }
    var initiallyActive: () -> Bool = { UIApplication.shared.applicationState == .active }
    var prepareMetal: (CAMetalLayer) -> Void = { $0.device = MTLCreateSystemDefaultDevice() }
    var metalAvailable: (CAMetalLayer) -> Bool = { $0.device != nil }
    var displayScale: (UIView) -> Double = { Double($0.window?.screen.scale ?? $0.traitCollection.displayScale) }
    var automaticallyPollHealth = true
}

@MainActor
final class SceneMetalSurface: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var handle: OpaquePointer?
    private var configured = false
    private var lastPaused: Bool?
    private var appliedRenderScale: Double?
    private var needsSettings = true
    private var geometry: SceneSurfaceGeometry?
    private var session: SceneHostSession
    private var startupWait = SceneStartupWait()
    private var settings: PlaybackSettings
    private var properties: [String: WallpaperProperty]
    private let status = UILabel()
    private var observers: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    private var active: Bool
    private let environment: SceneHostEnvironment

    private var mayRender: Bool {
        active && window != nil && bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
    }
    private var now: TimeInterval { environment.now() }

    init(url: URL, settings: PlaybackSettings, properties: [String: WallpaperProperty],
         environment: SceneHostEnvironment? = nil) {
        let environment = environment ?? SceneHostEnvironment()
        self.environment = environment
        session = SceneHostSession(url: url)
        self.settings = settings; self.properties = properties
        active = environment.initiallyActive()
        super.init(frame: .zero)
        backgroundColor = .black
        environment.prepareMetal(metalLayer)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        status.textColor = .white; status.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        status.numberOfLines = 0; status.textAlignment = .center
        status.text = NSLocalizedString("Loading native scene…", comment: "")
        status.accessibilityIdentifier = "wm.scene.status"
        addSubview(status)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setApplicationActive(false) }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setApplicationActive(true) }
        })
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
        isMultipleTouchEnabled = false
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    deinit {
        healthTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let handle { _ = owe_scene_wallpaper_shutdown(handle); _ = owe_scene_wallpaper_delete(handle) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        status.frame = bounds.insetBy(dx: 12, dy: 12)
        guard syncPaused() else { return }
        guard bounds.width > 0, bounds.height > 0, window != nil else { return }
        if handle == nil, !session.attempted { initialize() }
        else if handle != nil, configureSurface(), needsSettings { _ = applyNativeSettings() }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.displayScale != traitCollection.displayScale { setNeedsLayout() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard syncPaused() else { return }
        // Screen scale can change without changing point bounds.
        guard window != nil else { return }
        if handle == nil { setNeedsLayout() }
        else if bounds.width > 0, bounds.height > 0, configureSurface(), needsSettings { _ = applyNativeSettings() }
    }

    /// Shared by application notifications and deterministic lifecycle tests.
    func setApplicationActive(_ active: Bool) {
        self.active = active
        _ = syncPaused()
    }

    private func initialize() {
        guard session.beginInitialization() else { return }
        guard environment.metalAvailable(metalLayer) else { terminate("Metal is not available on this device."); return }
        let resources: SceneResourceDirectories
        do {
            // An empty mount supplies no licensed resources a project may require.
            resources = try environment.prepareResources()
        } catch {
            terminate(NSLocalizedString("scene.resources.unavailable", comment: "Scene resource directory preparation failed"))
            return
        }
        var initialized = false
        defer { if !initialized { shutdown() } }
        var pointer: OpaquePointer?
        guard check(owe_scene_wallpaper_new(&pointer)) else { return }
        guard let pointer else { terminate(NSLocalizedString("scene.renderer.unavailable", comment: "Native handle allocation failed")); return }
        handle = pointer
        guard check(owe_scene_wallpaper_init(pointer)), configureSurface(), applyNativeSettings() else { return }
        let url = session.url
        let projectRoot = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let projectJSON = projectRoot.appendingPathComponent("project.json")
        let source = FileManager.default.fileExists(atPath: projectJSON.path) ? projectJSON : url
        let cachePath = resources.shaderCache?.path ?? ""
        let json = SceneWallpaperPropertyJSON.flatten(properties) ?? "{}"
        let result = source.path.withCString { s in resources.sharedAssets.path.withCString { a in cachePath.withCString { c in json.withCString { p in
            owe_scene_wallpaper_apply_config(pointer, s, a, c, UInt32(max(1, min(120, settings.framesPerSecond))), !mayRender,
                Float(min(1, max(0, settings.volume))), settings.isMuted, false, p)
        } } } }
        guard check(result), syncPaused() else { return }
        startupWait.reset(now: now)
        startupWait.setWaiting(eligible: mayRender, now: now)
        if environment.automaticallyPollHealth {
            healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                // Read the current session/handle, never a captured former native pointer.
                Task { @MainActor in self?.readHealth() }
            }
        }
        initialized = true
    }
    @discardableResult private func configureSurface() -> Bool {
        guard let handle, session.failure == nil else { return false }
        guard let candidate = SceneSurfaceGeometry(logicalWidth: Double(bounds.width), logicalHeight: Double(bounds.height),
                                                   screenScale: environment.displayScale(self),
                                                   renderScale: settings.renderScale) else {
            terminate(NSLocalizedString("scene.surface.invalid", comment: "Invalid native scene surface geometry"))
            return false
        }
        if configured, let geometry,
           geometry.outputWidth == candidate.outputWidth, geometry.outputHeight == candidate.outputHeight,
           geometry.screenScale == candidate.screenScale {
            // Internal quality is changed by set_render_scale, not by shrinking the drawable.
            self.geometry = candidate
            return true
        }
        if configured, !check(owe_scene_wallpaper_begin_surface_reconfigure(handle)) { return false }
        // A live layer is changed only after the native renderer releases its surface.
        metalLayer.contentsScale = candidate.screenScale
        metalLayer.drawableSize = CGSize(width: Double(candidate.outputWidth), height: Double(candidate.outputHeight))
        let layerPointer = Unmanaged.passUnretained(metalLayer).toOpaque()
        let result: Int32
        if configured {
            result = owe_scene_wallpaper_finish_surface_reconfigure(handle, layerPointer, candidate.outputWidth, candidate.outputHeight,
                candidate.renderWidth, candidate.renderHeight, candidate.screenScale)
        } else {
            result = owe_scene_wallpaper_init_metal(handle, layerPointer, candidate.outputWidth, candidate.outputHeight,
                candidate.renderWidth, candidate.renderHeight, candidate.screenScale)
        }
        guard check(result) else { return false }
        geometry = candidate; configured = true
        return syncPaused()
    }
    func apply(url: URL, settings: PlaybackSettings, properties: [String: WallpaperProperty]) {
        if session.url != url {
            shutdown()
            session.select(url)
            startupWait.reset(now: now)
            showStatus(NSLocalizedString("Loading native scene…", comment: ""))
        }
        self.settings = settings; self.properties = properties
        needsSettings = true
        guard session.failure == nil else { return }
        guard syncPaused() else { return }
        // A transient collapsed layout is paused, not a terminal geometry error.
        // Keep the new settings pending until a positive-size layout can validate them.
        guard bounds.width > 0, bounds.height > 0, window != nil else { return }
        if handle == nil {
            if !session.attempted, bounds.width > 0, bounds.height > 0 { initialize() }
            return
        }
        guard configureSurface(), applyNativeSettings() else { return }
        _ = syncPaused()
    }
    private func applyNativeSettings() -> Bool {
        guard let handle, let geometry, session.failure == nil else { return false }
        // This is the engine's actual internal target scale (.25...1). Surface
        // render_width/height alone do not change Metal's target allocation.
        if appliedRenderScale != geometry.effectiveRenderScale {
            guard check(owe_scene_wallpaper_set_render_scale(handle, geometry.effectiveRenderScale)) else { return false }
            appliedRenderScale = geometry.effectiveRenderScale
        }
        guard check(owe_scene_wallpaper_set_target_fps(handle, UInt32(max(1, min(120, settings.framesPerSecond))))),
              check(owe_scene_wallpaper_set_audio_volume(handle, Float(min(1, max(0, settings.volume))))),
              check(owe_scene_wallpaper_set_audio_muted(handle, settings.isMuted)) else { return false }
        let mode: Int32 = settings.scaling == "fill" ? 3 : settings.scaling == "stretch" ? 1 : 2
        guard check(owe_scene_wallpaper_set_property_int32(handle, owe_property_scaling_mode(), mode)),
              check(owe_scene_wallpaper_set_property_bool(handle, owe_property_audio_response_enabled(), settings.microphoneEnabled)) else { return false }
        if let json = SceneWallpaperPropertyJSON.flatten(properties) {
            guard json.withCString({ check(owe_scene_wallpaper_set_property_string(handle, owe_property_project_property_preview_json(), $0)) }) else { return false }
        }
        needsSettings = false
        return true
    }
    @discardableResult private func syncPaused() -> Bool {
        startupWait.setWaiting(eligible: mayRender && handle != nil && session.failure == nil, now: now)
        guard let handle else { return session.failure == nil }
        let paused = !mayRender
        guard lastPaused != paused else { return true }
        guard check(owe_scene_wallpaper_set_paused(handle, paused)) else { return false }
        lastPaused = paused
        return true
    }
    func readHealth() {
        guard let handle, session.failure == nil else { return }
        var reason = [CChar](repeating: 0, count: 2048)
        let length = reason.withUnsafeMutableBufferPointer {
            owe_scene_wallpaper_backend_failure_reason(UnsafeMutableRawPointer(handle), $0.baseAddress, $0.count)
        }
        // Backend failure takes priority over old frame counts and the generic deadline.
        if length > 0 { showStatus(String(cString: reason)); return }
        var health = owe_surface_health()
        guard owe_scene_wallpaper_surface_health(UnsafeMutableRawPointer(handle), &health) == 0 else {
            terminate(NSLocalizedString("scene.health.unavailable", comment: "Native scene health query failed"))
            return
        }
        if health.frames_presented > 0 {
            status.isHidden = true
        } else if startupWait.hasTimedOut(now: now) {
            showStatus("The scene has not produced a native Metal frame. Check its assets and renderer diagnostics.")
        }
    }
    private func check(_ code: Int32) -> Bool {
        guard code == 0 else {
            let message = owe_last_error().map { String(cString: $0) } ?? ""
            terminate(message.isEmpty ? NSLocalizedString("scene.renderer.unavailable", comment: "Native scene failure") : message)
            return false
        }
        return true
    }
    private func showStatus(_ text: String) { status.text = text; status.isHidden = false }
    private func terminate(_ text: String) {
        session.recordFailure(text)
        showStatus(session.failure ?? text)
        shutdown()
    }
    func shutdown() {
        session.stop()
        startupWait.setWaiting(eligible: false, now: now)
        healthTimer?.invalidate(); healthTimer = nil
        if let handle { _ = owe_scene_wallpaper_shutdown(handle); _ = owe_scene_wallpaper_delete(handle) }
        handle = nil; configured = false; geometry = nil
        lastPaused = nil; appliedRenderScale = nil; needsSettings = true
    }
    private func pointer(_ point: CGPoint, pressed: Bool?) {
        guard let handle, session.failure == nil, mayRender else { return }
        _ = owe_scene_wallpaper_mouse_enter(handle, true)
        _ = owe_scene_wallpaper_mouse_input(handle, Double(point.x / bounds.width), Double(point.y / bounds.height))
        if let pressed { _ = owe_scene_wallpaper_mouse_button(handle, 0, pressed) }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { pointer(touch.location(in: self), pressed: true) } }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { pointer(touch.location(in: self), pressed: nil) } }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { if let touch = touches.first { pointer(touch.location(in: self), pressed: false) } }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }
    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        pointer(gesture.location(in: self), pressed: nil)
        if gesture.state == .ended, let handle { _ = owe_scene_wallpaper_mouse_enter(handle, false) }
    }
}
