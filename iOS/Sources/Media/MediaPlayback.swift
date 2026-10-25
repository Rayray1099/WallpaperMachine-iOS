import CoreGraphics
import CoreMedia
import Foundation

/// Values and vocabulary shared by the media players. Playback-specific
/// mechanics stay in `VideoWallpaperView`; this type only names states, failures
/// and the clamps that `PlaybackSettings` needs before they reach a player.
enum MediaPlayback {
  /// The visible state of one player. `preparing` covers opening the file and
  /// waiting for the first playable item; `failed` is terminal until a retry.
  enum State: Equatable {
    case idle
    case preparing
    case playing
    case paused
    case failed(Failure)

    var isPlaying: Bool { self == .playing }

    var failure: Failure? {
      guard case .failed(let failure) = self else { return nil }
      return failure
    }
  }

  /// A refusal or failure with a reason stable enough to log and to show. The
  /// UI decides how to phrase these; Media never claims a file plays when this
  /// is set.
  enum Failure: Error, Equatable, LocalizedError {
    /// AVFoundation cannot open the container (WebM and Matroska, for example).
    case unsupportedContainer(format: String, detail: String)
    /// The URL is not a readable local file: a remote URL, a missing file, or
    /// a file the app may not read.
    case unreadableFile(String)
    /// AVFoundation opened the file but found no video track.
    case noVideoTrack
    /// A playable file failed after it was opened.
    case playbackFailed(String)
    /// The codec is named in the container but this device cannot decode it.
    case unsupportedCodec(String)

    var errorDescription: String? {
      switch self {
      case .unsupportedContainer(let format, let detail):
        return "\(format) is not supported by the system video player: \(detail)"
      case .unreadableFile(let detail):
        return "The video file could not be read: \(detail)"
      case .noVideoTrack:
        return "The file has no video track."
      case .playbackFailed(let detail):
        return "Video playback failed: \(detail)"
      case .unsupportedCodec(let codec):
        return "\(codec) cannot be decoded on this device."
      }
    }
  }

  /// What the file is, as AVFoundation reported it after opening. This is
  /// descriptive only; it is never inferred from the file extension.
  struct VideoInfo: Equatable {
    /// "H.264", "HEVC", "VP9", "AV1", or the four-character code.
    var codec: String
    /// The coded size before the track's preferred transform.
    var codedSize: CGSize
    /// One pass of the file.
    var duration: CMTime
    /// Nominal frames per second, 0 when the file does not say.
    var nominalFrameRate: Double
    var hasAudio: Bool
  }

  /// Clamps that keep hostile or stale settings from reaching a player.
  enum Values {
    /// A finite volume in 0...1. A missing or non-finite value means full
    /// volume; mute is a separate setting.
    static func clampedVolume(_ volume: Double) -> Float {
      guard volume.isFinite else { return 1 }
      return Float(min(max(volume, 0), 1))
    }

    /// The render scale AVFoundation and the web page accept: at least a
    /// quarter of native, never above it.
    static func clampedRenderScale(_ scale: Double) -> Double {
      guard scale.isFinite else { return 1 }
      return min(max(scale, 0.25), 1)
    }

    /// A frame-rate limit for a page or a renderer, 0 for "no limit". Above
    /// `ceiling` there is nothing to enforce.
    static func frameLimit(_ fps: Int, ceiling: Int = 60) -> Int {
      guard fps > 0, fps < ceiling else { return 0 }
      return fps
    }

    /// The pixel size a view asks a decoder to produce for a render scale. Used
    /// as `AVPlayerItem.preferredMaximumResolution`; a local file is decoded at
    /// its own resolution when the system ignores the hint.
    static func scaledPixelSize(
      width: Double, height: Double, nativeScale: Double, renderScale: Double
    ) -> CGSize {
      let scale = clampedRenderScale(renderScale)
      let factor = max(nativeScale, 1) * scale
      return CGSize(
        width: max(1, (width * factor).rounded(.up)),
        height: max(1, (height * factor).rounded(.up)))
    }
  }
}
