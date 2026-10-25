//
//  FrameCompositor.swift
//  WallpaperMachineIOS
//
//  Places a decoded/rendered frame inside the configured export canvas using the
//  same geometry the pure tests exercise (fit/fill/stretch, zoom, normalised pan)
//  and renders it into a CVPixelBuffer or CGImage.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ExportRenderPlan: Sendable, Equatable {
    public var pixelSize: PixelSize
    public var aspectMode: WallpaperExportAspectMode
    public var zoom: Double
    public var offsetX: Double
    public var offsetY: Double
    public var backgroundRed: Double
    public var backgroundGreen: Double
    public var backgroundBlue: Double
    /// True for opaque outputs (MP4, JPEG frames); false keeps alpha (PNG frames).
    public var fillsBackground: Bool

    public init(
        pixelSize: PixelSize,
        aspectMode: WallpaperExportAspectMode,
        zoom: Double = 1,
        offsetX: Double = 0,
        offsetY: Double = 0,
        backgroundRed: Double = 0,
        backgroundGreen: Double = 0,
        backgroundBlue: Double = 0,
        fillsBackground: Bool = true
    ) {
        self.pixelSize = pixelSize
        self.aspectMode = aspectMode
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.backgroundRed = backgroundRed
        self.backgroundGreen = backgroundGreen
        self.backgroundBlue = backgroundBlue
        self.fillsBackground = fillsBackground
    }

    public var canvas: CGRect {
        CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
    }
}

public enum FrameCompositorError: LocalizedError {
    case emptyFrame
    case pixelBufferPoolUnavailable
    case pixelBufferCreationFailed(Int32)
    case imageCreationFailed

    public var errorDescription: String? {
        switch self {
        case .emptyFrame:
            return String(localized: "The source frame is empty.")
        case .pixelBufferPoolUnavailable:
            return String(localized: "The video encoder did not provide a pixel buffer pool.")
        case .pixelBufferCreationFailed(let status):
            return String(localized: "Could not allocate a video frame.") + " (CVReturn \(status))"
        case .imageCreationFailed:
            return String(localized: "Could not convert the rendered frame to an image.")
        }
    }
}

public final class FrameCompositor {
    public let plan: ExportRenderPlan
    private let context: CIContext
    private let colorSpace: CGColorSpace
    private let background: CIImage

    public init(plan: ExportRenderPlan) {
        self.plan = plan
        self.context = CIContext(options: [.cacheIntermediates: false])
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let color = CIColor(red: plan.backgroundRed, green: plan.backgroundGreen,
                            blue: plan.backgroundBlue, alpha: 1)
        self.background = CIImage(color: color).cropped(to: plan.canvas)
    }

    // MARK: - Rendering

    /// Composites a decoded video frame. `preferredTransform` is the track
    /// transform so portrait footage is upright before the aspect pass.
    public func render(source: CVPixelBuffer, preferredTransform: CGAffineTransform? = nil) throws -> CIImage {
        var image = CIImage(cvPixelBuffer: source)
        if let preferredTransform, !preferredTransform.isIdentity {
            image = image.transformed(by: preferredTransform)
        }
        return try render(source: image)
    }

    public func render(source: CGImage) throws -> CIImage {
        try render(source: CIImage(cgImage: source))
    }

    public func render(source: CIImage) throws -> CIImage {
        var image = source
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite, !extent.isNull else {
            throw FrameCompositorError.emptyFrame
        }
        if extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        }
        return composite(image)
    }

    private func composite(_ image: CIImage) -> CIImage {
        let sourceExtent = image.extent
        let sourceSize = PixelSize(width: max(1, Int(sourceExtent.width.rounded())),
                                   height: max(1, Int(sourceExtent.height.rounded())))
        let rect = ExportGeometry.drawRect(source: sourceSize,
                                           target: plan.pixelSize,
                                           mode: plan.aspectMode,
                                           zoom: plan.zoom,
                                           offsetX: plan.offsetX,
                                           offsetY: plan.offsetY)
        let scaleX = rect.width / Double(sourceExtent.width)
        let scaleY = rect.height / Double(sourceExtent.height)
        var placed = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // ExportRect uses a top-left origin; CoreImage uses a bottom-left origin.
        let flippedY = Double(plan.pixelSize.height) - rect.y - rect.height
        placed = placed.transformed(by: CGAffineTransform(translationX: rect.x, y: flippedY))

        if plan.fillsBackground {
            placed = placed.composited(over: background)
        }
        return placed.cropped(to: plan.canvas)
    }

    // MARK: - Outputs

    public func pixelBuffer(for image: CIImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess else {
            throw FrameCompositorError.pixelBufferCreationFailed(status)
        }
        guard let buffer else {
            throw FrameCompositorError.pixelBufferCreationFailed(status)
        }
        context.render(image, to: buffer, bounds: plan.canvas, colorSpace: colorSpace)
        return buffer
    }

    public func cgImage(for image: CIImage) throws -> CGImage {
        guard let rendered = context.createCGImage(image, from: plan.canvas) else {
            throw FrameCompositorError.imageCreationFailed
        }
        return rendered
    }
}
