// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Validated physical surface pixels and a bounded internal-raster request.
struct SceneSurfaceGeometry: Equatable {
    let logicalWidth: Double
    let logicalHeight: Double
    let screenScale: Double
    /// Retained separately so equality also notices changes within a clamp range.
    let renderScale: Double
    let effectiveRenderScale: Double

    /// Native width/height and CAMetalLayer.drawableSize use these physical pixels.
    let outputWidth: UInt32
    let outputHeight: UInt32
    /// Requested internal pixels, not the layer's drawable size. The current
    /// Metal backend carries these ABI fields but sizes targets using the native
    /// render-scale property, authored canvas, resolution policy and device cap.
    let renderWidth: UInt32
    let renderHeight: UInt32

    init?(logicalWidth: Double, logicalHeight: Double, screenScale: Double, renderScale: Double) {
        guard logicalWidth.isFinite, logicalWidth > 0,
              logicalHeight.isFinite, logicalHeight > 0,
              screenScale.isFinite, screenScale > 0,
              renderScale.isFinite, renderScale > 0 else { return nil }

        // SceneWallpaper's SET_RENDER_SCALE and SceneRaster clamp to .25...1.
        // Using the older iOS .1...2 clamp here would describe unavailable quality.
        let effectiveRenderScale = min(1, max(0.25, renderScale))
        guard let outputWidth = Self.pixelDimension(logicalWidth * screenScale),
              let outputHeight = Self.pixelDimension(logicalHeight * screenScale),
              Self.nativeLayoutIsRepresentable(pixels: outputWidth, scale: screenScale),
              Self.nativeLayoutIsRepresentable(pixels: outputHeight, scale: screenScale),
              let renderWidth = Self.pixelDimension(Double(outputWidth) * effectiveRenderScale),
              let renderHeight = Self.pixelDimension(Double(outputHeight) * effectiveRenderScale) else { return nil }

        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.screenScale = screenScale
        self.renderScale = renderScale
        self.effectiveRenderScale = effectiveRenderScale
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
    }

    private static func pixelDimension(_ value: Double) -> UInt32? {
        // The C ABI is uint32_t but surface info narrows to uint16_t. Reject an
        // oversized request instead of wrapping or silently reducing resolution.
        let maximum = Double(UInt16.max)
        guard value.isFinite, value >= 0, value <= maximum else { return nil }
        let rounded = max(1, value.rounded(.toNearestOrAwayFromZero))
        guard rounded <= maximum else { return nil }
        return UInt32(rounded)
    }

    private static func nativeLayoutIsRepresentable(pixels: UInt32, scale: Double) -> Bool {
        // MetalRender divides output pixels by display scale, rounds to uint32_t
        // logical points, then builds int32_t presentation rectangles. Reject
        // pathological finite scales that overflow that native round trip too.
        let logical = (Double(pixels) / scale).rounded(.toNearestOrAwayFromZero)
        guard logical.isFinite, logical <= Double(UInt32.max) else { return false }
        let presented = (max(1, logical) * scale).rounded(.toNearestOrAwayFromZero)
        return presented.isFinite && presented <= Double(Int32.max)
    }
}
