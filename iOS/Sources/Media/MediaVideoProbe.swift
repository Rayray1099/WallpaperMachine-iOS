import AVFoundation
import CoreMedia
import Foundation

/// The container family a file begins with, decided from its own bytes rather
/// than its extension. WebM and Matroska are called out because AVFoundation
/// never opens them, so the video view can refuse them explicitly instead of
/// surfacing a generic decode error.
enum MediaContainerKind: Equatable {
  case mp4OrQuickTime
  case webM
  case matroska
  case unknown

  var displayName: String? {
    switch self {
    case .mp4OrQuickTime: return nil
    case .webM: return "WebM"
    case .matroska: return "Matroska"
    case .unknown: return nil
    }
  }
}

/// A video the probe accepted, with the asset it opened so the player does not
/// index the file a second time.
struct MediaPreparedVideo {
  var asset: AVURLAsset
  var info: MediaPlayback.VideoInfo
}

/// Opens a local video and reports what AVFoundation actually found.
///
/// This is the source of truth for "supported": no extension list promises a
/// codec, and WebM or Matroska is refused with the container named. The probe is
/// asynchronous because `AVURLAsset` loads its tracks off the calling thread.
enum MediaVideoProbe {
  /// How much of the file is read to identify its container. Matroska's
  /// `DocType` sits in the first EBML header, far inside this window.
  static let signatureByteCount = 4096

  /// The container family, from the first bytes. Pure, so the tests can prove
  /// the EBML and ISO-BMFF signatures without a media file.
  static func containerKind(firstBytes data: Data) -> MediaContainerKind {
    let bytes = [UInt8](data.prefix(64))

    // EBML header: 1A 45 DF A3. The DocType follows in the same header.
    if bytes.count >= 4, bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
      let header = [UInt8](data.prefix(signatureByteCount))
      if containsASCII(header, "matroska") { return .matroska }
      return .webM
    }

    // ISO base media (MP4/MOV): a box whose type sits at offset 4. QuickTime
    // files can begin with `moov`, `wide`, `free` or `skip` instead of `ftyp`.
    if bytes.count >= 8 {
      let box = String(bytes: bytes[4..<8], encoding: .isoLatin1)?.lowercased()
      if let box, ["ftyp", "moov", "mdat", "wide", "free", "skip"].contains(box) {
        return .mp4OrQuickTime
      }
    }
    return .unknown
  }

  /// Reads just the signature window. A file that cannot be opened reports
  /// `.unknown` here and is refused by `prepare` with the read error.
  static func containerKind(url: URL) -> MediaContainerKind {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: signatureByteCount), !data.isEmpty else {
      return .unknown
    }
    return containerKind(firstBytes: data)
  }

  /// Opens `url` and returns the asset and its real properties, or the reason
  /// it cannot be shown. Call this off the main thread; it reads the file.
  static func prepare(url: URL) async -> Result<MediaPreparedVideo, MediaPlayback.Failure> {
    guard url.isFileURL else {
      return .failure(.unreadableFile("the URL is not a local file"))
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      return .failure(.unreadableFile("the file is missing or not readable"))
    }

    let container = containerKind(url: url)
    switch container {
    case .webM, .matroska:
      let name = container.displayName ?? "WebM"
      return .failure(
        .unsupportedContainer(
          format: name,
          detail:
            "AVFoundation cannot open Matroska or WebM. The project's native WebM reader "
            + "(Renderer/Media/Apple/WebMReader) is built for macOS only; wiring it into the iOS "
            + "target is a renderer build change, not a media-player setting."))
    case .mp4OrQuickTime, .unknown:
      break
    }

    let asset = AVURLAsset(
      url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    do {
      guard try await asset.load(.isPlayable) else {
        return .failure(
          .unsupportedContainer(
            format: url.pathExtension.uppercased(),
            detail: "AVFoundation reports the file is not playable"))
      }
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      guard let track = videoTracks.first else { return .failure(.noVideoTrack) }

      let descriptions = try await track.load(.formatDescriptions)
      let codec = descriptions.first.map(codecName(for:)) ?? "unknown"
      let codedSize = try await track.load(.naturalSize)
      let frameRate = try await track.load(.nominalFrameRate)
      let duration = try await asset.load(.duration)
      let audioTracks = try await asset.loadTracks(withMediaType: .audio)
      guard duration.isValid, duration.seconds.isFinite, duration.seconds > 0 else {
        return .failure(.playbackFailed("the file has no finite duration"))
      }

      return .success(
        MediaPreparedVideo(
          asset: asset,
          info: MediaPlayback.VideoInfo(
            codec: codec,
            codedSize: codedSize,
            duration: duration,
            nominalFrameRate: Double(frameRate),
            hasAudio: !audioTracks.isEmpty)))
    } catch {
      return .failure(.playbackFailed(error.localizedDescription))
    }
  }

  /// A person-facing codec name from a Core Media subtype.
  static func codecName(for description: CMFormatDescription) -> String {
    let subtype = CMFormatDescriptionGetMediaSubType(description)
    let avc = fourCharacterCode("avc1")
    let avc3 = fourCharacterCode("avc3")
    let hvc = fourCharacterCode("hvc1")
    let hev = fourCharacterCode("hev1")
    let vp9 = fourCharacterCode("vp09")
    let av1 = fourCharacterCode("av01")
    let dvh = fourCharacterCode("dvh1")
    let dvhe = fourCharacterCode("dvhe")
    if subtype == avc || subtype == avc3 { return "H.264" }
    if subtype == hvc || subtype == hev { return "HEVC" }
    if subtype == vp9 { return "VP9" }
    if subtype == av1 { return "AV1" }
    if subtype == dvh || subtype == dvhe { return "Dolby Vision HEVC" }
    return fourCharacterString(subtype)
  }

  /// "avc1" as a `FourCharCode`, for comparisons that do not rely on magic
  /// numbers. The bytes are ASCII by definition.
  static func fourCharacterCode(_ text: String) -> FourCharCode {
    var code: FourCharCode = 0
    for byte in text.utf8.prefix(4) {
      code = (code << 8) | FourCharCode(byte)
    }
    return code
  }

  private static func fourCharacterString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
      UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
      UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
    ]
    return String(bytes: bytes, encoding: .isoLatin1) ?? "unknown"
  }

  private static func containsASCII(_ bytes: [UInt8], _ text: String) -> Bool {
    let needle = [UInt8](text.utf8)
    guard !needle.isEmpty, bytes.count >= needle.count else { return false }
    for start in 0...(bytes.count - needle.count) where Array(bytes[start..<(start + needle.count)]) == needle {
      return true
    }
    return false
  }
}
