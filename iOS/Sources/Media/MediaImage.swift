import CoreGraphics
import UIKit

/// Conversions between UIKit's snapshot images and the `CGImage` the export
/// pipeline consumes.
enum MediaImage {
  /// A `CGImage` for a `UIImage`, rendering one when the image is backed by a
  /// `CIImage` or a symbol rather than a bitmap.
  static func cgImage(from image: UIImage) -> CGImage? {
    if let cgImage = image.cgImage { return cgImage }
    let size = image.size
    guard size.width >= 1, size.height >= 1 else { return nil }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }.cgImage
  }

  /// Scales a still down to fit `maximumSize` in pixels. A zero or larger-than-
  /// source bound returns the source unchanged; it never upscales.
  static func downscaled(_ image: CGImage, maximumSize: CGSize) -> CGImage? {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    guard width > 0, height > 0 else { return nil }
    let maximumWidth = maximumSize.width
    let maximumHeight = maximumSize.height
    guard maximumWidth > 0 || maximumHeight > 0 else { return image }
    var scale = 1.0
    if maximumWidth > 0 { scale = min(scale, maximumWidth / width) }
    if maximumHeight > 0 { scale = min(scale, maximumHeight / height) }
    guard scale < 1 else { return image }
    let target = CGSize(
      width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: target, format: format)
    let rendered = renderer.image { _ in
      UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: target))
    }
    return rendered.cgImage
  }
}
