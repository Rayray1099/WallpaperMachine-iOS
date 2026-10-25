import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Decodes actual animation frames within the cache's existing frame/pixel budgets.
enum WorkshopAnimationDecoder {
    static let maximumDimension = 2_048

    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let count = WorkshopAnimationBudget.frameCount(CGImageSourceGetCount(source))
        else { return nil }

        var frames: [UIImage] = []
        var durations: [TimeInterval] = []
        var totalPixels = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
                let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                WorkshopAnimationBudget.canAddFrame(width: width, height: height, totalPixels: totalPixels)
            else { return nil }
            let scale = min(1, Double(maximumDimension) / Double(max(width, height)))
            let targetSize = Int((Double(max(width, height)) * scale).rounded(.up))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetSize,
                kCGImageSourceShouldCache: false,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, index, options as CFDictionary)
            else { return nil }
            frames.append(UIImage(cgImage: cgImage))
            totalPixels += width * height
            let props = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (props?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (props?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            durations.append(WorkshopAnimationBudget.duration(delay))
        }
        guard frames.count > 1 else { return nil }
        return UIImage.animatedImage(with: frames, duration: durations.reduce(0, +))
    }
}
