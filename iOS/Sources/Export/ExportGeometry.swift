//
//  ExportGeometry.swift
//  WallpaperMachineIOS
//
//  Geometry and naming helpers shared by every export writer.
//
//  This file intentionally imports Foundation only: the layout maths is the part
//  of the exporter that can be compiled and executed outside an Apple SDK, so it
//  is kept free of CoreGraphics/UIKit/AVFoundation so it can be unit tested.
//

import Foundation

/// A pixel dimension. Export is resolution driven, so sizes are stored as integer
/// pixels rather than points.
public struct PixelSize: Hashable, Codable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var isPositive: Bool { width > 0 && height > 0 }
    public var longEdge: Int { max(width, height) }
    public var shortEdge: Int { min(width, height) }
    public var aspectRatio: Double { height == 0 ? 0 : Double(width) / Double(height) }
    public var description: String { "\(width)x\(height)" }

    /// H.264/HEVC 4:2:0 capture and most hardware encoders require even dimensions.
    /// Rounding down (never up) keeps a requested size a hard upper bound.
    public func evenized(minimum: Int = 2) -> PixelSize {
        func even(_ value: Int) -> Int {
            let clamped = max(minimum, value)
            let rounded = clamped - (clamped % 2)
            return max(minimum, rounded)
        }
        return PixelSize(width: even(width), height: even(height))
    }

    /// The same pixel geometry rotated by 90 degrees.
    public var rotated: PixelSize { PixelSize(width: height, height: width) }
}

/// A rectangle in pixel coordinates with origin at the top-left of the target.
public struct ExportRect: Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var description: String {
        "x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y)) " +
        "w=\(String(format: "%.2f", width)) h=\(String(format: "%.2f", height))"
    }
}

public enum ExportGeometry {
    /// How the source frame is placed inside the target canvas.
    ///
    /// `fit` letterboxes (both dimensions visible), `fill` crops the overflowing
    /// dimension, `stretch` ignores the source aspect ratio. `zoom` scales around
    /// the centre after the aspect pass, and the normalised offsets pan the result
    /// (1.0 == one full target dimension).
    public static func drawRect(
        source: PixelSize,
        target: PixelSize,
        mode: WallpaperExportAspectMode,
        zoom: Double = 1,
        offsetX: Double = 0,
        offsetY: Double = 0
    ) -> ExportRect {
        let safeZoom = max(0.01, zoom.isFinite ? zoom : 1)
        let targetWidth = Double(max(1, target.width))
        let targetHeight = Double(max(1, target.height))
        let sourceWidth = Double(max(1, source.width))
        let sourceHeight = Double(max(1, source.height))

        var width: Double
        var height: Double

        switch mode {
        case .stretch:
            width = targetWidth * safeZoom
            height = targetHeight * safeZoom
        case .fit, .fill:
            let horizontal = targetWidth / sourceWidth
            let vertical = targetHeight / sourceHeight
            let scale = (mode == .fit ? min(horizontal, vertical) : max(horizontal, vertical)) * safeZoom
            width = sourceWidth * scale
            height = sourceHeight * scale
        }

        let safeOffsetX = (offsetX.isFinite ? offsetX : 0).clamped(to: -1...1)
        let safeOffsetY = (offsetY.isFinite ? offsetY : 0).clamped(to: -1...1)

        var x = (targetWidth - width) / 2 + safeOffsetX * targetWidth
        var y = (targetHeight - height) / 2 + safeOffsetY * targetHeight

        // Fill and zoomed content must keep covering the canvas. Fit/stretch content
        // that is smaller than the canvas is kept fully inside it.
        if width >= targetWidth {
            x = min(0, max(targetWidth - width, x))
        } else {
            x = max(0, min(targetWidth - width, x))
        }
        if height >= targetHeight {
            y = min(0, max(targetHeight - height, y))
        } else {
            y = max(0, min(targetHeight - height, y))
        }

        return ExportRect(x: x, y: y, width: width, height: height)
    }

    /// Pixel size of the source after `preferredTransform` has been applied.
    /// Video tracks often report a landscape natural size with a 90 degree
    /// transform for portrait footage.
    public static func orientedSize(naturalSize: PixelSize, quarterTurns: Int) -> PixelSize {
        let turns = ((quarterTurns % 4) + 4) % 4
        return turns % 2 == 0 ? naturalSize : naturalSize.rotated
    }

    /// Estimated encoded frame count for a duration. Never zero so an export of a
    /// sub-frame duration still produces one frame. There is deliberately no frame
    /// ceiling here: callers that need a technical limit enforce it at the writer.
    public static func frameCount(duration: Double, frameRate: Double) -> Int {
        guard duration.isFinite, frameRate.isFinite, duration > 0, frameRate > 0 else { return 0 }
        return max(1, Int((duration * frameRate).rounded()))
    }
}

public enum ExportNaming {
    /// Characters that are safe in a ZIP member name, a `.wallpaper` bundle name
    /// and a share-sheet file name. PosterBoard treats the wallpaper folder name as
    /// opaque, but path separators and control characters must never survive.
    public static func sanitized(_ raw: String, fallback: String = "Wallpaper", maxLength: Int = 64) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_"))
        var scalars = String.UnicodeScalarView()
        for scalar in raw.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            scalars.append(allowed.contains(scalar) ? scalar : " ")
        }
        var value = String(scalars)
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        if value.isEmpty { value = fallback }
        if value.count > maxLength { value = String(value.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        // A leading dot would hide the file/folder; a leading digit is fine.
        while value.hasPrefix(".") { value.removeFirst() }
        return value.isEmpty ? fallback : value
    }

    /// Default name shown in the share sheet for a rendered export.
    public static func fileBaseName(title: String, format: WallpaperExportFormat, codec: WallpaperExportCodec) -> String {
        let base = sanitized(title, fallback: "Wallpaper")
        switch format {
        case .movie:
            return base
        case .imageSequence:
            return "\(base)-Frames"
        case .tendies:
            return base
        }
    }

    public static func movieFileName(title: String) -> String {
        "\(sanitized(title, fallback: "Wallpaper")).mp4"
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
