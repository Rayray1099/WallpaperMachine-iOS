//
//  WallpaperExportSettings.swift
//  WallpaperMachineIOS
//
//  User-configurable export settings. Foundation only so the validation and
//  bitrate/timeline maths can be unit tested without an Apple SDK.
//

import Foundation

/// What the exporter writes.
public enum WallpaperExportFormat: String, Codable, CaseIterable, Sendable {
    /// MP4 (H.264 or HEVC) rendered video.
    case movie
    /// Numbered PNG/JPEG frames written into a directory.
    case imageSequence
    /// PosterBoard `.tendies` archive (JPEG image sequence + CAML manifest).
    case tendies
}

public enum WallpaperExportCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case hevc

    public var fileExtension: String { "mp4" }

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

public enum WallpaperExportQualityPreset: String, Codable, CaseIterable, Sendable {
    case low
    case standard
    case high
    case maximum

    /// Bits per pixel per frame before the codec adjustment. These are encoder
    /// guidance values, not measured quality: AVAssetWriter is asked for an
    /// average bitrate and may undershoot on static content.
    fileprivate var bitsPerPixelPerFrame: Double {
        switch self {
        case .low: return 0.035
        case .standard: return 0.060
        case .high: return 0.090
        case .maximum: return 0.140
        }
    }
}

public struct WallpaperExportQuality: Hashable, Codable, Sendable {
    public var preset: WallpaperExportQualityPreset
    /// Explicit average bitrate in bits per second. Zero (the default) derives the
    /// bitrate from the preset, pixel count and frame rate.
    public var customBitrate: Int

    public init(preset: WallpaperExportQualityPreset = .high, customBitrate: Int = 0) {
        self.preset = preset
        self.customBitrate = customBitrate
    }

    public func averageBitrate(pixelSize: PixelSize, frameRate: Int, codec: WallpaperExportCodec) -> Int {
        if customBitrate > 0 { return customBitrate }
        let pixels = Double(max(1, pixelSize.width) * max(1, pixelSize.height))
        let fps = Double(max(1, frameRate))
        let codecFactor = codec == .hevc ? 0.65 : 1.0
        let raw = pixels * fps * preset.bitsPerPixelPerFrame * codecFactor
        let floor = 500_000.0
        let rounded = max(floor, raw).rounded(toMultipleOf: 100_000)
        // Well below Int.max (9.22e18) but representable as a Double so the
        // conversion cannot trap even for absurd custom resolutions.
        return Int(min(rounded, 9.0e18))
    }
}

public enum WallpaperExportAspectMode: String, Codable, CaseIterable, Sendable {
    /// Whole source visible, letterboxed against the configured canvas colour.
    case fit
    /// Source fills the canvas; overflowing edges are cropped.
    case fill
    /// Source aspect ratio is ignored.
    case stretch
}

public enum WallpaperExportImageFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    public var cameraFormat: String { fileExtension }
}

public enum WallpaperExportResolutionPreset: String, Codable, CaseIterable, Sendable {
    /// Match this device's native pixel size.
    case device
    case iPadPro13M4
    case iPadPro129
    case iPadPro11
    case iPadAir11
    case iPad102
    case iPadMini
    case fullHD1080
    case custom

    /// Native portrait pixel size for preset iPad hardware. `nil` for `.device`
    /// and `.custom`, which are resolved from the device screen or user input.
    public var fixedPixelSize: PixelSize? {
        switch self {
        case .device, .custom:
            return nil
        case .iPadPro13M4:
            return PixelSize(width: 2064, height: 2752)
        case .iPadPro129:
            return PixelSize(width: 2048, height: 2732)
        case .iPadPro11:
            return PixelSize(width: 1668, height: 2388)
        case .iPadAir11:
            return PixelSize(width: 1640, height: 2360)
        case .iPad102:
            return PixelSize(width: 1620, height: 2160)
        case .iPadMini:
            return PixelSize(width: 1488, height: 2266)
        case .fullHD1080:
            return PixelSize(width: 1080, height: 1920)
        }
    }
}

public struct WallpaperExportResolution: Hashable, Codable, Sendable {
    public var preset: WallpaperExportResolutionPreset
    public var customWidth: Int
    public var customHeight: Int

    public init(preset: WallpaperExportResolutionPreset = .device, customWidth: Int = 1080, customHeight: Int = 1920) {
        self.preset = preset
        self.customWidth = customWidth
        self.customHeight = customHeight
    }

    public static let device = WallpaperExportResolution(preset: .device)

    public func pixelSize(devicePixelSize: PixelSize) -> PixelSize {
        switch preset {
        case .device:
            return devicePixelSize
        case .custom:
            return PixelSize(width: customWidth, height: customHeight)
        default:
            return preset.fixedPixelSize ?? devicePixelSize
        }
    }
}

/// PosterBoard archive options. Evidence for every field is recorded in
/// docs/ios/EXPORT.md.
public struct TendiesExportSettings: Hashable, Codable, Sendable {
    /// Logical (point) screen class used for the `.wallpaper`, `.ca` and metadata
    /// names, e.g. `810w-1080h@2x~ipad`.
    public var screenClass: TendiesScreenClass
    /// Display name. Empty means "use the wallpaper title".
    public var wallpaperName: String
    /// PosterKit wallpaper family. The Nugget/Placard templates use "Chip".
    public var family: String
    /// Wallpaper identifier. Zero means "pick a random identifier at export time".
    public var identifier: Int
    /// JPEG quality for the frame sequence (0.1...1.0).
    public var frameQuality: Double
    /// How `main.caml` expresses the animation. See TendiesAnimationEncoding.
    public var animationEncoding: TendiesAnimationEncoding
    /// Writes a generated PRPosterMetadata record so the system picker shows the
    /// user's name instead of the template family name.
    public var includesDisplayNameMetadata: Bool

    public init(
        screenClass: TendiesScreenClass = .iPad102,
        wallpaperName: String = "",
        family: String = "Chip",
        identifier: Int = 0,
        frameQuality: Double = 0.82,
        animationEncoding: TendiesAnimationEncoding = .contentsKeyframe,
        includesDisplayNameMetadata: Bool = true
    ) {
        self.screenClass = screenClass
        self.wallpaperName = wallpaperName
        self.family = family
        self.identifier = identifier
        self.frameQuality = frameQuality
        self.animationEncoding = animationEncoding
        self.includesDisplayNameMetadata = includesDisplayNameMetadata
    }
}

public struct WallpaperExportSettings: Hashable, Codable, Sendable {
    public var format: WallpaperExportFormat
    public var codec: WallpaperExportCodec
    public var resolution: WallpaperExportResolution
    /// Frames per second. Integer because every consumer (the frame clock, CAML
    /// `frameDuration`, and the system picker) is integer driven.
    public var frameRate: Int
    /// Seconds. Clamped to the source duration by the exporter for movie sources.
    public var duration: Double
    public var quality: WallpaperExportQuality
    public var aspectMode: WallpaperExportAspectMode
    /// 1.0 = no zoom. Values above 1.0 enlarge the source before positioning.
    public var zoom: Double
    /// Normalised pan, -1...1 of the target dimension.
    public var offsetX: Double
    public var offsetY: Double
    public var imageFormat: WallpaperExportImageFormat
    public var imageQuality: Double
    /// Also packages the frame directory as a ZIP so the share sheet produces one
    /// archive. The frame directory is kept either way.
    public var zipImageSequence: Bool
    public var tendies: TendiesExportSettings
    /// Letterbox colour (sRGB components) for `fit` / zoomed-out content.
    public var backgroundRed: Double
    public var backgroundGreen: Double
    public var backgroundBlue: Double

    public init(
        format: WallpaperExportFormat = .movie,
        codec: WallpaperExportCodec = .h264,
        resolution: WallpaperExportResolution = .device,
        frameRate: Int = 30,
        duration: Double = 8,
        quality: WallpaperExportQuality = WallpaperExportQuality(),
        aspectMode: WallpaperExportAspectMode = .fill,
        zoom: Double = 1,
        offsetX: Double = 0,
        offsetY: Double = 0,
        imageFormat: WallpaperExportImageFormat = .png,
        imageQuality: Double = 0.9,
        zipImageSequence: Bool = true,
        tendies: TendiesExportSettings = TendiesExportSettings(),
        backgroundRed: Double = 0,
        backgroundGreen: Double = 0,
        backgroundBlue: Double = 0
    ) {
        self.format = format
        self.codec = codec
        self.resolution = resolution
        self.frameRate = frameRate
        self.duration = duration
        self.quality = quality
        self.aspectMode = aspectMode
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.imageFormat = imageFormat
        self.imageQuality = imageQuality
        self.zipImageSequence = zipImageSequence
        self.tendies = tendies
        self.backgroundRed = backgroundRed
        self.backgroundGreen = backgroundGreen
        self.backgroundBlue = backgroundBlue
    }

    /// Defaults that respect a wallpaper's own playback cadence where one exists.
    public init(playbackFrameRate: Int) {
        self.init(frameRate: max(1, playbackFrameRate))
    }

    public func timeline(duration: Double? = nil) -> ExportTimeline {
        ExportTimeline(frameRate: frameRate, duration: duration ?? self.duration)
    }
}

public struct ExportTimeline: Hashable, Sendable {
    public let frameRate: Int
    public let duration: Double

    public init(frameRate: Int, duration: Double) {
        self.frameRate = frameRate
        self.duration = duration
    }

    public var frameCount: Int {
        ExportGeometry.frameCount(duration: duration, frameRate: Double(frameRate))
    }

    public func time(forFrameAt index: Int) -> Double {
        guard frameRate > 0 else { return 0 }
        return Double(index) / Double(frameRate)
    }

    public func presentationTime(forFrameAt index: Int) -> Double {
        // Sample time 0 and frame duration 1/fps: the last frame starts at
        // (count - 1) / fps and the movie ends at count / fps.
        time(forFrameAt: index)
    }

    public var actualDuration: Double {
        guard frameRate > 0 else { return 0 }
        return Double(frameCount) / Double(frameRate)
    }
}

public enum WallpaperExportValidationError: Error, Equatable, CustomStringConvertible {
    case invalidDuration(Double)
    case invalidFrameRate(Int)
    case invalidResolution(PixelSize)
    case invalidImageQuality(Double)
    case invalidIdentifier(Int)

    public var description: String {
        switch self {
        case .invalidDuration(let value):
            return "Duration must be a positive number of seconds (received \(value))."
        case .invalidFrameRate(let value):
            return "Frame rate must be between 1 and 120 (received \(value))."
        case .invalidResolution(let size):
            return "Resolution must be a positive pixel size (received \(size))."
        case .invalidImageQuality(let value):
            return "Image quality must be between 0.1 and 1.0 (received \(value))."
        case .invalidIdentifier(let value):
            return "Wallpaper identifier must be zero (automatic) or a positive integer (received \(value))."
        }
    }
}

public extension WallpaperExportSettings {
    /// Validates the settings that do not need device or source information.
    func validate() throws {
        guard duration.isFinite, duration > 0, duration <= 24 * 60 * 60 else {
            throw WallpaperExportValidationError.invalidDuration(duration)
        }
        guard (1...120).contains(frameRate) else {
            throw WallpaperExportValidationError.invalidFrameRate(frameRate)
        }
        guard (0.1...1.0).contains(imageQuality) else {
            throw WallpaperExportValidationError.invalidImageQuality(imageQuality)
        }
        guard (0.1...1.0).contains(tendies.frameQuality) else {
            throw WallpaperExportValidationError.invalidImageQuality(tendies.frameQuality)
        }
        guard tendies.identifier == 0 || (1...Int(Int32.max)).contains(tendies.identifier) else {
            throw WallpaperExportValidationError.invalidIdentifier(tendies.identifier)
        }
        if resolution.preset == .custom {
            guard resolution.customWidth > 0, resolution.customHeight > 0 else {
                throw WallpaperExportValidationError.invalidResolution(
                    PixelSize(width: resolution.customWidth, height: resolution.customHeight))
            }
        }
    }

    /// Pixel size this export will render. Movie output must be even sized; the
    /// `.tendies` frame assets use the same even size so a single frame render can
    /// feed every writer.
    func targetPixelSize(devicePixelSize: PixelSize, requireEven: Bool = true) -> PixelSize {
        let requested = resolution.pixelSize(devicePixelSize: devicePixelSize)
        return requireEven ? requested.evenized() : requested
    }
}

private extension Double {
    func rounded(toMultipleOf step: Double) -> Double {
        guard step > 0 else { return self }
        return (self / step).rounded() * step
    }
}
