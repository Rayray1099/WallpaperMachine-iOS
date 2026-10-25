// SPDX-License-Identifier: GPL-3.0-only
// Compile with SceneSurfaceGeometry.swift; Foundation only, no app launch or XCTest.
import Foundation

@main
struct SceneGeometryRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: SceneSurfaceGeometry: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        var checks = 0
        func require(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure(description: label) }
            checks += 1
        }
        func geometry(_ width: Double, _ height: Double, _ screenScale: Double, _ renderScale: Double) throws -> SceneSurfaceGeometry {
            guard let value = SceneSurfaceGeometry(logicalWidth: width, logicalHeight: height,
                                                  screenScale: screenScale, renderScale: renderScale) else {
                throw Failure(description: "Rejected valid geometry: \(width)x\(height) @\(screenScale), render \(renderScale)")
            }
            checks += 1
            return value
        }
        func rejects(_ width: Double, _ height: Double, _ screenScale: Double, _ renderScale: Double, _ label: String) throws {
            try require(SceneSurfaceGeometry(logicalWidth: width, logicalHeight: height,
                                             screenScale: screenScale, renderScale: renderScale) == nil, label)
        }

        // Execute the old host arithmetic alongside the actual helper. This is
        // a numerical contract regression, not a native or Metal frame test.
        for scale in [2.0, 3.0] {
            let width = 390.0, height = 844.0, quality = 0.5
            let oldNativeWidth = UInt32(width), oldNativeHeight = UInt32(height)
            let oldDrawableWidth = UInt32(max(1, width * scale * quality))
            let oldDrawableHeight = UInt32(max(1, height * scale * quality))
            let fixed = try geometry(width, height, scale, quality)
            try require(oldNativeWidth != fixed.outputWidth && oldNativeHeight != fixed.outputHeight,
                        "Baseline must reproduce point/physical output mismatch")
            try require(oldDrawableWidth != fixed.outputWidth && oldDrawableHeight != fixed.outputHeight,
                        "Baseline must reproduce quality-scaled drawable mismatch")
            print("BASELINE @\(Int(scale))x: old native output \(oldNativeWidth)x\(oldNativeHeight) points treated as pixels; physical output \(fixed.outputWidth)x\(fixed.outputHeight). Old .5 drawable \(oldDrawableWidth)x\(oldDrawableHeight) incorrectly changes presentation size.")
        }

        // Physical output never depends on quality; internal requests use the
        // native .25...1 clamp, including legacy stored .1 and 2 settings.
        for scale in [1.0, 2.0, 3.0] {
            for (requested, effective) in [(0.1, 0.25), (0.5, 0.5), (1.0, 1.0), (2.0, 1.0)] {
                let value = try geometry(320, 180, scale, requested)
                try require(value.outputWidth == UInt32(320 * scale) && value.outputHeight == UInt32(180 * scale),
                            "Quality changed physical output at @\(scale), render \(requested)")
                try require(value.renderWidth == UInt32(320 * scale * effective) && value.renderHeight == UInt32(180 * scale * effective),
                            "Wrong internal request at @\(scale), render \(requested)")
                try require(value.renderScale == requested && value.effectiveRenderScale == effective,
                            "Requested/effective render scales were not retained separately")
            }
        }
        let fractional = try geometry(100.25, 50.75, 2, 0.5)
        try require(fractional.outputWidth == 201 && fractional.outputHeight == 102,
                    "Fractional physical output must round halves away from zero")
        try require(fractional.renderWidth == 101 && fractional.renderHeight == 51,
                    "Internal request must round the integer physical output, not independently rescale points")
        let roundingCases: [(Double, UInt32)] = [(1.49, 1), (1.5, 2), (2.49, 2), (2.5, 3), (2.51, 3)]
        for (input, expected) in roundingCases {
            let value = try geometry(input, input, 1, 1)
            try require(value.outputWidth == expected && value.outputHeight == expected, "Nondeterministic fractional rounding")
        }
        for scale in [1.0, 2.0, 3.0] {
            let one = try geometry(1, 1, scale, 0.1)
            try require(one.outputWidth == UInt32(scale) && one.outputHeight == UInt32(scale), "1x1 point output lost display scale")
            try require(one.renderWidth == 1 && one.renderHeight == 1, "Subpixel internal request must keep one pixel")
        }
        let tiny = try geometry(Double.leastNonzeroMagnitude, 0.01, 1, 0.5)
        try require(tiny.outputWidth == 1 && tiny.outputHeight == 1 && tiny.renderWidth == 1 && tiny.renderHeight == 1,
                    "Positive subpixel dimensions must keep one pixel")

        let portrait = try geometry(390, 844, 3, 0.5)
        let landscape = try geometry(844, 390, 3, 0.5)
        try require(landscape.outputWidth == portrait.outputHeight && landscape.outputHeight == portrait.outputWidth &&
                    landscape.renderWidth == portrait.renderHeight && landscape.renderHeight == portrait.renderWidth,
                    "Rotation must exchange both output and internal axes")
        let samePortrait = try geometry(390, 844, 3, 0.5)
        try require(portrait == samePortrait, "Equal geometry must be a stable cache key")
        try require(portrait != landscape, "Rotation must invalidate cache")
        let twoX = try geometry(390, 844, 2, 0.5)
        try require(twoX != portrait && twoX.outputWidth != portrait.outputWidth, "Equal bounds with a new screen scale must invalidate cache")
        let samePixels = try geometry(585, 1266, 2, 0.5)
        try require(samePixels.outputWidth == portrait.outputWidth && samePixels.outputHeight == portrait.outputHeight && samePixels != portrait,
                    "Bounds/scale changes must not disappear behind identical pixel extents")
        let tinyTwoX = try geometry(0.1, 0.1, 2, 1)
        let tinyThreeX = try geometry(0.1, 0.1, 3, 1)
        try require(tinyTwoX.outputWidth == tinyThreeX.outputWidth && tinyTwoX.outputHeight == tinyThreeX.outputHeight && tinyTwoX != tinyThreeX,
                    "Equal bounds and quantized-equal output must still notice a screen-scale change")
        let closeBounds = try geometry(390.01, 844.01, 3, 0.5)
        try require(closeBounds.outputWidth == portrait.outputWidth && closeBounds.outputHeight == portrait.outputHeight && closeBounds != portrait,
                    "Subpixel logical bounds changes must invalidate cache")
        let closeQuality = try geometry(390, 844, 3, 0.500001)
        try require(closeQuality.renderWidth == portrait.renderWidth && closeQuality.renderHeight == portrait.renderHeight && closeQuality != portrait,
                    "Quantized-equal quality changes must invalidate cache")
        let low = try geometry(320, 180, 2, 0.1)
        let alsoLow = try geometry(320, 180, 2, 0.2)
        try require(low.effectiveRenderScale == alsoLow.effectiveRenderScale && low != alsoLow,
                    "Clamped-equal requested render-scale changes must invalidate cache")

        // Reject before any floating-point-to-integer conversion can trap or
        // reach the C ABI's uint32_t -> uint16_t narrowing with invalid values.
        for invalid in [Double.nan, Double.infinity, -Double.infinity, -1, 0, -0.0] {
            try rejects(invalid, 180, 2, 1, "Invalid logical width accepted")
            try rejects(320, invalid, 2, 1, "Invalid logical height accepted")
            try rejects(320, 180, invalid, 1, "Invalid screen scale accepted")
            try rejects(320, 180, 2, invalid, "Invalid render scale accepted")
        }
        let maximum = Double(UInt16.max)
        let largest = try geometry(maximum, maximum, 1, 1)
        try require(largest.outputWidth == UInt32(UInt16.max) && largest.outputHeight == UInt32(UInt16.max) &&
                    largest.renderWidth == UInt32(UInt16.max) && largest.renderHeight == UInt32(UInt16.max),
                    "Valid ABI limit must survive without wrapping")
        let scaledLimit = try geometry(maximum / 3, maximum / 3, 3, 1)
        try require(scaledLimit.outputWidth == UInt32(UInt16.max) && scaledLimit.outputHeight == UInt32(UInt16.max),
                    "Valid @3x ABI limit was rejected")
        for oversized in [maximum.nextUp, maximum + 0.1, maximum + 1, Double(UInt32.max), Double.greatestFiniteMagnitude] {
            try rejects(oversized, 1, 1, 0.25, "Oversized output width accepted or silently reduced")
            try rejects(1, oversized, 1, 0.25, "Oversized output height accepted or silently reduced")
        }
        try rejects(320, 180, Double.greatestFiniteMagnitude, 1, "Overflowing screen-scaled output accepted")
        try rejects(Double.greatestFiniteMagnitude, 1, 3, 1, "Infinite output product accepted")
        try rejects(1, 1, Double.leastNonzeroMagnitude, 1, "Native logical round trip overflow accepted")
        try rejects(1e-10, 1e-10, 1e10, 1, "Native presentation rectangle overflow accepted")
        try rejects(Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, 1e-308, 1,
                    "Huge logical geometry with small physical output must reject native logical conversion overflow")
        let hugeQuality = try geometry(320, 180, 2, Double.greatestFiniteMagnitude)
        try require(hugeQuality.effectiveRenderScale == 1 && hugeQuality.renderWidth == hugeQuality.outputWidth,
                    "Positive finite quality must clamp before multiplication")
        let tinyQuality = try geometry(320, 180, 2, Double.leastNonzeroMagnitude)
        try require(tinyQuality.effectiveRenderScale == 0.25 && tinyQuality.renderWidth == 160,
                    "Positive subnormal quality must clamp to the native minimum")

        print("PASS: physical 1x/2x/3x output, native render-scale clamp, fractional rounding, one-pixel minimum, rotation/cache identity, invalid/overflow/u16 bounds (\(checks) checks)")
        print("Scope: Foundation numerical regression only; no app, device, GPU or Metal rendering verification.")
        print("Native contract: render_width/height are ABI requests, not observed allocations; actual raster uses native render-scale property, scene resolution/canvas and device limits.")
    }
}
