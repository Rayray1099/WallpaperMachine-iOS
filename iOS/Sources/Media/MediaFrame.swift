import CoreGraphics
import CoreMedia
import Foundation

/// Where a captured still came from. The export pipeline labels the result with
/// this, so a provider that cannot render is never presented as a working source.
enum MediaFrameSource: String, Equatable, Sendable {
  case video
  case web
  case scene
  case image
}

/// One rendered still, at the provider's own colour space and orientation.
///
/// `presentationTime` is the source time the still represents for a time-based
/// provider (video), and nil for a live surface (web, scene) whose frame has no
/// timeline of its own.
struct MediaFrame: @unchecked Sendable {
  var image: CGImage
  var presentationTime: CMTime?
  var source: MediaFrameSource

  var pixelSize: CGSize {
    CGSize(width: image.width, height: image.height)
  }
}

/// Why a still could not be produced. These are developer-facing reasons: the
/// export UI decides how to phrase an unavailable provider, and must not claim
/// the still exists when this is thrown.
enum MediaFrameError: Error, Equatable, LocalizedError {
  /// The provider has not rendered a first frame yet, or its file could not be
  /// opened. `isFrameCaptureReady` is false at the same time.
  case sourceNotReady
  /// The source cannot produce stills at all (for example an unsupported
  /// container), and this is the reason the player itself uses.
  case unsupportedSource(String)
  /// A time-based provider has no frame at the requested time.
  case noFrameAtTime(CMTime)
  /// A time outside the source's own duration was clamped or refused.
  case timeOutsideSource(CMTime)
  /// WebKit returned no image for the current page.
  case snapshotUnavailable

  var errorDescription: String? {
    switch self {
    case .sourceNotReady:
      return "The wallpaper has not rendered a frame that can be captured yet."
    case .unsupportedSource(let reason):
      return reason
    case .noFrameAtTime(let time):
      return "The video has no frame at \(CMTimeGetSeconds(time)) seconds."
    case .timeOutsideSource(let time):
      return "\(CMTimeGetSeconds(time)) seconds is outside the video."
    case .snapshotUnavailable:
      return "The web wallpaper did not provide an image to capture."
    }
  }
}

/// A wallpaper surface that can hand the export pipeline a real frame.
///
/// `VideoWallpaperView` and `WebWallpaperView` implement this. The renderer's
/// scene view can adopt it too (a Metal readback), which lets the export agent
/// treat every kind of wallpaper the same way instead of reaching into each
/// renderer. A provider that returns false from `isFrameCaptureReady` must throw
/// rather than return a placeholder image.
@MainActor
protocol MediaFrameProviding: AnyObject {
  var frameSource: MediaFrameSource { get }
  var isFrameCaptureReady: Bool { get }
  /// Captures the current frame, or the frame at `time` when the source has a
  /// timeline. `maximumSize` is a pixel bound on the long edge; `.zero` asks
  /// for the source's own resolution.
  func captureFrame(at time: CMTime?, maximumSize: CGSize) async throws -> MediaFrame
}

extension MediaFrameProviding {
  /// A still of the frame that is showing now, at the source's resolution.
  func captureFrame() async throws -> MediaFrame {
    try await captureFrame(at: nil, maximumSize: .zero)
  }

  /// A still no larger than `maximumSize` in either dimension.
  func captureFrame(maximumSize: CGSize) async throws -> MediaFrame {
    try await captureFrame(at: nil, maximumSize: maximumSize)
  }
}
