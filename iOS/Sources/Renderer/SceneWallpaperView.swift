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
        view.apply(settings: settings, properties: properties)
    }
    static func dismantleUIView(_ view: SceneMetalSurface, coordinator: ()) { view.shutdown() }
}

@MainActor
final class SceneMetalSurface: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var handle: OpaquePointer?
    private var configured = false
    private var geometry = CGSize.zero
    private let url: URL
    private var settings: PlaybackSettings
    private var properties: [String: WallpaperProperty]
    private let status = UILabel()
    private var observers: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    private var active = true
    private var startedAt = Date()

    init(url: URL, settings: PlaybackSettings, properties: [String: WallpaperProperty]) {
        self.url = url; self.settings = settings; self.properties = properties
        super.init(frame: .zero)
        backgroundColor = .black
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        status.textColor = .white; status.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        status.numberOfLines = 0; status.textAlignment = .center
        status.text = NSLocalizedString("Loading native scene…", comment: "")
        status.accessibilityIdentifier = "wm.scene.status"
        addSubview(status)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.active = false; self?.syncPaused() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.active = true; self?.syncPaused() }
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
        guard bounds.width > 0, bounds.height > 0 else { return }
        if handle == nil { initialize() }
        else if geometry != bounds.size { configureSurface() }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); syncPaused() }

    private func initialize() {
        guard metalLayer.device != nil else { fail("Metal is not available on this device."); return }
        var pointer: OpaquePointer?
        guard check(owe_scene_wallpaper_new(&pointer)), let pointer else { return }
        handle = pointer
        guard check(owe_scene_wallpaper_init(pointer)) else { return }
        configureSurface()
        let projectRoot = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let projectJSON = projectRoot.appendingPathComponent("project.json")
        let source = FileManager.default.fileExists(atPath: projectJSON.path) ? projectJSON : url
        // User-owned Wallpaper Engine assets may be imported to the sibling SharedAssets folder.
        // Never embed/re-distribute licensed shared resources in the application.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let assets = base.appendingPathComponent("WallpaperMachine/SharedAssets")
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.appendingPathComponent("SceneShaders")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let json = SceneWallpaperPropertyJSON.flatten(properties) ?? "{}"
        let result = source.path.withCString { s in assets.path.withCString { a in cache.path.withCString { c in json.withCString { p in
            owe_scene_wallpaper_apply_config(pointer, s, a, c, UInt32(max(1, settings.framesPerSecond)), window == nil,
                Float(min(1, max(0, settings.volume))), settings.isMuted, false, p)
        } } } }
        guard check(result) else { return }
        apply(settings: settings, properties: properties)
        startedAt = Date()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readHealth() }
        }
    }
    private func configureSurface() {
        guard let handle else { return }
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        let renderScale = min(2, max(0.1, settings.renderScale))
        let pixel = CGSize(width: max(1, bounds.width * scale * renderScale), height: max(1, bounds.height * scale * renderScale))
        metalLayer.drawableSize = pixel
        let layerPointer = Unmanaged.passUnretained(metalLayer).toOpaque()
        if configured, !check(owe_scene_wallpaper_begin_surface_reconfigure(handle)) { return }
        let result: Int32
        if configured {
            result = owe_scene_wallpaper_finish_surface_reconfigure(handle, layerPointer, UInt32(bounds.width), UInt32(bounds.height), UInt32(pixel.width), UInt32(pixel.height), Double(scale))
        } else {
            result = owe_scene_wallpaper_init_metal(handle, layerPointer, UInt32(bounds.width), UInt32(bounds.height), UInt32(pixel.width), UInt32(pixel.height), Double(scale))
        }
        if check(result) { geometry = bounds.size; configured = true }
        syncPaused()
    }
    func apply(settings: PlaybackSettings, properties: [String: WallpaperProperty]) {
        let resize = self.settings.renderScale != settings.renderScale
        self.settings = settings; self.properties = properties
        guard let handle else { return }
        _ = owe_scene_wallpaper_set_target_fps(handle, UInt32(max(1, min(120, settings.framesPerSecond))))
        _ = owe_scene_wallpaper_set_audio_volume(handle, Float(min(1, max(0, settings.volume))))
        _ = owe_scene_wallpaper_set_audio_muted(handle, settings.isMuted)
        let mode: Int32 = settings.scaling == "fill" ? 3 : settings.scaling == "stretch" ? 1 : 2
        _ = owe_scene_wallpaper_set_property_int32(handle, owe_property_scaling_mode(), mode)
        _ = owe_scene_wallpaper_set_property_bool(handle, owe_property_audio_response_enabled(), settings.microphoneEnabled)
        if let json = SceneWallpaperPropertyJSON.flatten(properties) {
            json.withCString { _ = owe_scene_wallpaper_set_property_string(handle, owe_property_project_property_preview_json(), $0) }
        }
        if resize { configureSurface() }
        syncPaused()
    }
    private func syncPaused() { if let handle { _ = owe_scene_wallpaper_set_paused(handle, !active || window == nil) } }
    private func readHealth() {
        guard let handle else { return }
        var health = owe_surface_health()
        if owe_scene_wallpaper_surface_health(UnsafeMutableRawPointer(handle), &health) == 0, health.frames_presented > 0 {
            status.isHidden = true
        } else if Date().timeIntervalSince(startedAt) > 15 {
            fail("The scene has not produced a native Metal frame. Check its assets and renderer diagnostics.")
        }
        var reason = [CChar](repeating: 0, count: 2048)
        let length = reason.withUnsafeMutableBufferPointer {
            owe_scene_wallpaper_backend_failure_reason(UnsafeMutableRawPointer(handle), $0.baseAddress, $0.count)
        }
        if length > 0 { fail(String(cString: reason)) }
    }
    private func check(_ code: Int32) -> Bool {
        // Every owe_* status function documents 0 as success and nonzero as failure.
        guard code == 0 else {
            fail(owe_last_error().map { String(cString: $0) } ?? "Native scene renderer failed.")
            return false
        }
        return true
    }
    private func fail(_ text: String) { status.text = text; status.isHidden = false }
    func shutdown() {
        healthTimer?.invalidate(); healthTimer = nil
        if let handle { _ = owe_scene_wallpaper_shutdown(handle); _ = owe_scene_wallpaper_delete(handle) }
        handle = nil; configured = false
    }
    private func pointer(_ point: CGPoint, pressed: Bool?) {
        guard let handle, bounds.width > 0, bounds.height > 0 else { return }
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
