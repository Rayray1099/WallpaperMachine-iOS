//
//  TendiesScreenClass.swift
//  WallpaperMachineIOS
//
//  PosterBoard names wallpapers, animation bundles and `logicalScreenClass` by a
//  "screen class": logical point size, scale and idiom, for example
//  `810w-1080h@2x~ipad`. Evidence for the exact syntax and the iPad presets is in
//  docs/ios/EXPORT.md; the important finding is that the numbers are points, not
//  pixels (Nugget's iPad VideoCAML template and Poster-Lab's iPhone export both
//  use point dimensions, while a pixel-sized variant seen in the wild is treated
//  as an unverified alternative).
//

import Foundation

public struct TendiesScreenClass: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Idiom: String, Codable, CaseIterable, Sendable {
        case phone
        case pad

        /// PosterBoard suffix: `~iphone` / `~ipad`.
        public var suffix: String {
            switch self {
            case .phone: return "iphone"
            case .pad: return "ipad"
            }
        }

        /// Scale used by every known template of this idiom.
        public var canonicalScale: Int {
            switch self {
            case .phone: return 3
            case .pad: return 2
            }
        }
    }

    public var widthPoints: Int
    public var heightPoints: Int
    public var scale: Int
    public var idiom: Idiom

    public init(widthPoints: Int, heightPoints: Int, scale: Int, idiom: Idiom) {
        // Store raw values: invalid custom input must be rejected by `isValid`
        // rather than silently coerced into a different screen class.
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.scale = scale
        self.idiom = idiom
    }

    public init(widthPoints: Int, heightPoints: Int, idiom: Idiom) {
        self.init(widthPoints: widthPoints, heightPoints: heightPoints,
                  scale: idiom.canonicalScale, idiom: idiom)
    }

    /// `810w-1080h@2x~ipad` — the token used for `.wallpaper` and `.ca` bundle
    /// names and for `Wallpaper.plist`'s `logicalScreenClass`.
    public var name: String { "\(widthPoints)w-\(heightPoints)h@\(scale)x~\(idiom.suffix)" }

    public var description: String { name }

    public var pixelSize: PixelSize {
        PixelSize(width: widthPoints * scale, height: heightPoints * scale)
    }

    public var isValid: Bool {
        widthPoints > 0 && heightPoints > 0 && (1...4).contains(scale)
    }

    // MARK: - Presets

    /// The iPad template that Nugget, Placard and Eagle ship for video/layered
    /// wallpapers (iPad 10.2", 810x1080 pt @2x).
    public static let iPad102 = TendiesScreenClass(widthPoints: 810, heightPoints: 1080, idiom: .pad)
    public static let iPadMini6 = TendiesScreenClass(widthPoints: 744, heightPoints: 1133, idiom: .pad)
    public static let iPad97 = TendiesScreenClass(widthPoints: 768, heightPoints: 1024, idiom: .pad)
    public static let iPadAir109 = TendiesScreenClass(widthPoints: 820, heightPoints: 1180, idiom: .pad)
    public static let iPadPro11 = TendiesScreenClass(widthPoints: 834, heightPoints: 1194, idiom: .pad)
    public static let iPadPro11M4 = TendiesScreenClass(widthPoints: 834, heightPoints: 1210, idiom: .pad)
    public static let iPadPro129 = TendiesScreenClass(widthPoints: 1024, heightPoints: 1366, idiom: .pad)
    public static let iPadPro13M4 = TendiesScreenClass(widthPoints: 1032, heightPoints: 1376, idiom: .pad)

    public static let iPhone13 = TendiesScreenClass(widthPoints: 390, heightPoints: 844, idiom: .phone)
    public static let iPhone15Pro = TendiesScreenClass(widthPoints: 393, heightPoints: 852, idiom: .phone)
    public static let iPhone15ProMax = TendiesScreenClass(widthPoints: 430, heightPoints: 932, idiom: .phone)
    public static let iPhone16ProMax = TendiesScreenClass(widthPoints: 440, heightPoints: 956, idiom: .phone)
    public static let iPhoneSE = TendiesScreenClass(widthPoints: 375, heightPoints: 667, idiom: .phone)

    public struct Preset: Identifiable, Hashable, Sendable {
        public let id: String
        public let screenClass: TendiesScreenClass
        public init(id: String, screenClass: TendiesScreenClass) {
            self.id = id
            self.screenClass = screenClass
        }
    }

    /// Ordered iPad-first preset list for the export picker. iPad numbers are the
    /// logical point sizes Apple's UIKit reports for each device family.
    public static let presets: [Preset] = [
        Preset(id: "ipad-pro-13-m4", screenClass: .iPadPro13M4),
        Preset(id: "ipad-pro-12-9", screenClass: .iPadPro129),
        Preset(id: "ipad-pro-11-m4", screenClass: .iPadPro11M4),
        Preset(id: "ipad-pro-11", screenClass: .iPadPro11),
        Preset(id: "ipad-air-10-9", screenClass: .iPadAir109),
        Preset(id: "ipad-10-2", screenClass: .iPad102),
        Preset(id: "ipad-mini-6", screenClass: .iPadMini6),
        Preset(id: "ipad-9-7", screenClass: .iPad97),
        Preset(id: "iphone-16-pro-max", screenClass: .iPhone16ProMax),
        Preset(id: "iphone-15-pro-max", screenClass: .iPhone15ProMax),
        Preset(id: "iphone-15-pro", screenClass: .iPhone15Pro),
        Preset(id: "iphone-13", screenClass: .iPhone13),
        Preset(id: "iphone-se", screenClass: .iPhoneSE)
    ]
}
