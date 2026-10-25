//
//  WallpaperFrameProvider.swift
//  WallpaperMachineIOS
//
//  The integration contract between the exporter and the components that can
//  render a wallpaper frame:
//
//  - Video: `WallpaperExportService` can decode the item itself, but Media may
//    supply a provider that reuses its looping player pipeline.
//  - Scene: Renderer must supply a provider that renders the C++/Metal scene
//    offscreen at a requested media time.
//  - Web: Media must supply a provider that snapshots the WKWebView at a requested
//    media time (honest about snapshot latency; it is not a 60 fps capture).
//
//  When no provider is supplied for a scene/web item the exporter fails with an
//  explicit error. It never substitutes the author preview still.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

@MainActor
public protocol WallpaperFrameProvider: AnyObject {
    /// Native size the provider renders at. The exporter scales this into the
    /// configured output resolution using the selected aspect/positioning.
    var frameSize: CGSize { get }
    /// Optional known duration. Nil means "unknown"; the configured export
    /// duration is used as-is.
    var duration: CMTime? { get }
    /// Allocates capture resources. Throws when the item cannot be rendered.
    func prepareForExport() async throws
    /// Renders one frame at the requested media time. Returning nil means the
    /// provider has no frame for that time (the exporter treats it as a failure to
    /// avoid silently skipping time); throwing reports a real rendering error.
    func frame(at time: CMTime) async throws -> CVPixelBuffer?
    /// Releases capture resources. Must be safe to call after a failed prepare.
    func finishExport() async
}

public extension WallpaperFrameProvider {
    var duration: CMTime? { nil }
}

/// Type-erased provider so the app layer can keep a single property without
/// exposing the concrete renderer/media capture types.
@MainActor
public final class AnyWallpaperFrameProvider: WallpaperFrameProvider {
    private let base: WallpaperFrameProvider

    public init(_ base: WallpaperFrameProvider) {
        self.base = base
    }

    public var frameSize: CGSize { base.frameSize }
    public var duration: CMTime? { base.duration }

    public func prepareForExport() async throws {
        try await base.prepareForExport()
    }

    public func frame(at time: CMTime) async throws -> CVPixelBuffer? {
        try await base.frame(at: time)
    }

    public func finishExport() async {
        await base.finishExport()
    }
}

public enum WallpaperFrameProviderError: LocalizedError, Equatable {
    case notPrepared
    case renderFailed(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            return String(localized: "The frame provider was not prepared before rendering.")
        case .renderFailed(let reason):
            return String(localized: "The frame provider could not render a frame.") + " " + reason
        case .unavailable(let reason):
            return String(localized: "The frame provider is unavailable.") + " " + reason
        }
    }
}
