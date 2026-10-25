import Foundation

/// How a source picture is placed in its container, matching
/// `PlaybackSettings.scaling` (`fit`, `fill`, `stretch`).
///
/// `fit` and `fill` keep the source's aspect ratio and letterbox or crop;
/// `stretch` fills the container and distorts. An unknown string is treated as
/// `fit`, the least surprising choice for a wallpaper that is only partially
/// visible.
enum MediaScaling: String, CaseIterable, Equatable {
  case fit
  case fill
  case stretch

  init(setting: String) {
    self = MediaScaling(rawValue: setting.lowercased()) ?? .fit
  }

  /// The destination of a source picture inside a container, in points.
  ///
  /// The result is centred. Zero or non-finite inputs produce an empty rect
  /// rather than a NaN geometry that would reach a layer or a still renderer.
  func rect(sourceWidth: Double, sourceHeight: Double, containerWidth: Double, containerHeight: Double)
    -> MediaScaling.Rect
  {
    guard sourceWidth > 0, sourceHeight > 0, containerWidth > 0, containerHeight > 0,
      sourceWidth.isFinite, sourceHeight.isFinite, containerWidth.isFinite, containerHeight.isFinite
    else { return .zero }

    switch self {
    case .stretch:
      return Rect(x: 0, y: 0, width: containerWidth, height: containerHeight)
    case .fit:
      let scale = min(containerWidth / sourceWidth, containerHeight / sourceHeight)
      let width = sourceWidth * scale
      let height = sourceHeight * scale
      return Rect(
        x: (containerWidth - width) / 2, y: (containerHeight - height) / 2, width: width, height: height)
    case .fill:
      let scale = max(containerWidth / sourceWidth, containerHeight / sourceHeight)
      let width = sourceWidth * scale
      let height = sourceHeight * scale
      return Rect(
        x: (containerWidth - width) / 2, y: (containerHeight - height) / 2, width: width, height: height)
    }
  }

  /// A rectangle in container points.
  struct Rect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    var isEmpty: Bool { width <= 0 || height <= 0 }
  }
}
