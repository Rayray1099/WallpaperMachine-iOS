import Foundation

/// One frame of the microphone spectrum, in the shape both Wallpaper Engine
/// surfaces consume.
///
/// Wallpaper Engine's web API takes 128 values per frame: the first 64 are the
/// left channel's frequency bands, the last 64 the right channel's, each from
/// low bass to treble. The scene API takes 16, 32 or 64 bands, so `reduced(to:)`
/// folds this spectrum into any of those resolutions.
///
/// This is microphone input only. The app has no public iOS API that captures
/// other applications' audio, and nothing here claims to.
struct AudioSpectrum: Equatable, Sendable {
  static let bandCount = 64
  static let webBinCount = bandCount * 2

  /// 64 bands, quietest to loudest frequency.
  var left: [Float]
  var right: [Float]

  init(left: [Float], right: [Float]) {
    self.left = Self.normalised(left)
    self.right = Self.normalised(right)
  }

  static let silent = AudioSpectrum(
    left: [Float](repeating: 0, count: bandCount),
    right: [Float](repeating: 0, count: bandCount))

  /// The 128 values `wallpaperRegisterAudioListener` expects.
  var webBins: [Float] { left + right }

  var peak: Float { max(left.max() ?? 0, right.max() ?? 0) }

  var isSilent: Bool { peak <= 0.0001 }

  /// Folds the 64 bands into `count` bands by taking each group's peak, which
  /// keeps a beat visible at 16 bands. Returns the left channel; callers that
  /// need stereo fold `left` and `right` separately.
  func reduced(to count: Int) -> [Float] {
    Self.reduce(left, to: count)
  }

  func reducedStereo(to count: Int) -> (left: [Float], right: [Float]) {
    (Self.reduce(left, to: count), Self.reduce(right, to: count))
  }

  private static func reduce(_ bands: [Float], to count: Int) -> [Float] {
    guard count > 0 else { return [] }
    guard count < bands.count else { return Array(bands.prefix(count)) }
    var result = [Float](repeating: 0, count: count)
    for index in 0..<count {
      let lower = index * bands.count / count
      let upper = max(lower + 1, (index + 1) * bands.count / count)
      var peak: Float = 0
      for band in lower..<min(upper, bands.count) {
        peak = max(peak, bands[band])
      }
      result[index] = peak
    }
    return result
  }

  private static func normalised(_ bands: [Float]) -> [Float] {
    var result = [Float](repeating: 0, count: bandCount)
    for index in 0..<min(bands.count, bandCount) {
      let value = bands[index]
      result[index] = value.isFinite ? min(max(value, 0), 1) : 0
    }
    return result
  }
}

/// The arithmetic that turns FFT magnitudes into Wallpaper Engine's bands. Kept
/// apart from Accelerate so the mapping can be tested without audio hardware.
enum AudioSpectrumMapping {
  /// The level below which a band is treated as silent.
  static let floorDecibels: Float = -80

  /// 64 logarithmic bands from 40 Hz to 16 kHz (or just under Nyquist on a
  /// lower-rate device). Every range holds at least one FFT bin and ranges do
  /// not overlap.
  static func bandBinRanges(
    sampleRate: Double, fftSize: Int, bandCount: Int = AudioSpectrum.bandCount,
    minimumFrequency: Double = 40, maximumFrequency: Double = 16_000
  ) -> [Range<Int>] {
    let binCount = fftSize / 2
    guard sampleRate > 0, binCount > 0, bandCount > 0 else { return [] }
    let nyquist = sampleRate / 2
    let high = min(maximumFrequency, nyquist * 0.95)
    let low = max(minimumFrequency, 10)
    guard high > low else { return [] }
    let binWidth = sampleRate / Double(fftSize)
    let ratio = high / low
    var ranges: [Range<Int>] = []
    ranges.reserveCapacity(bandCount)
    for index in 0..<bandCount {
      let startFrequency = low * pow(ratio, Double(index) / Double(bandCount))
      let endFrequency = low * pow(ratio, Double(index + 1) / Double(bandCount))
      let lower = min(binCount - 1, max(0, Int(startFrequency / binWidth)))
      let upper = min(binCount, max(lower + 1, Int((endFrequency / binWidth).rounded(.up))))
      ranges.append(lower..<upper)
    }
    return ranges
  }

  /// Per-band peak magnitude, converted to decibels and normalised so 0 dB is
  /// 1 and `floorDecibels` is 0. `scale` normalises the FFT's own gain and
  /// windowing; values are clamped to 0...1 because the platform's analyser
  /// can overshoot on transients.
  static func levels(
    magnitudes: [Float], ranges: [Range<Int>], scale: Float,
    floorDecibels: Float = AudioSpectrumMapping.floorDecibels
  ) -> [Float] {
    guard !ranges.isEmpty else { return [] }
    var result = [Float](repeating: 0, count: ranges.count)
    for (index, range) in ranges.enumerated() {
      var peak: Float = 0
      for bin in range where bin < magnitudes.count {
        peak = max(peak, magnitudes[bin])
      }
      let amplitude = max(peak * scale, 1e-7)
      let decibels = 20 * log10(amplitude)
      result[index] = min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
    }
    return result
  }

  /// Attack/release smoothing: a rising band follows quickly, a falling one
  /// decays slowly, so bars do not flicker at 20-30 updates a second.
  static func smoothed(
    previous: [Float], current: [Float], attack: Float = 0.55, release: Float = 0.18
  ) -> [Float] {
    guard previous.count == current.count else { return current }
    var result = [Float](repeating: 0, count: current.count)
    for index in 0..<current.count {
      let factor = current[index] > previous[index] ? attack : release
      result[index] = previous[index] + (current[index] - previous[index]) * factor
    }
    return result
  }
}
