import Accelerate
import Foundation

/// One channel-pair FFT for the microphone analyser.
///
/// The instance is used from the audio tap thread only: its scratch buffers are
/// preallocated so a 20-30 Hz update does not allocate inside the tap. The
/// `AudioSpectrum` it returns is a value and can be handed to the main thread.
///
/// A 2048-sample Hann-windowed FFT at the hardware sample rate gives about 21 Hz
/// bins at 44.1 kHz, enough for the lowest logarithmic band; the magnitudes are
/// folded into 64 bands by `AudioSpectrumMapping`, so the scene and web surfaces
/// both receive Wallpaper Engine's layout.
final class MicrophoneSpectrumAnalyzer {
  let fftSize: Int
  let sampleRate: Double

  private let log2n: vDSP_Length
  private let setup: FFTSetup
  private let window: UnsafeMutablePointer<Float>
  private let windowed: UnsafeMutablePointer<Float>
  private let real: UnsafeMutablePointer<Float>
  private let imag: UnsafeMutablePointer<Float>
  private let magnitudes: UnsafeMutablePointer<Float>
  private var split: DSPSplitComplex
  private let ranges: [Range<Int>]
  /// Compensates the forward real FFT's factor of two and the Hann window's
  /// coherent gain, so a full-scale sine lands near 1.0.
  private let fftScale: Float
  private var previousLeft: [Float]
  private var previousRight: [Float]

  init?(sampleRate: Double, fftSize: Int = 2048, bandCount: Int = AudioSpectrum.bandCount) {
    guard sampleRate >= 8_000, fftSize >= 256, fftSize & (fftSize - 1) == 0 else { return nil }
    let half = fftSize / 2
    let log2n = vDSP_Length(fftSize.trailingZeroBitCount)
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }

    let window = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
    let windowed = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
    let real = UnsafeMutablePointer<Float>.allocate(capacity: half)
    let imag = UnsafeMutablePointer<Float>.allocate(capacity: half)
    let magnitudes = UnsafeMutablePointer<Float>.allocate(capacity: half)
    windowed.initialize(repeating: 0, count: fftSize)
    real.initialize(repeating: 0, count: half)
    imag.initialize(repeating: 0, count: half)
    magnitudes.initialize(repeating: 0, count: half)

    var hann = [Float](repeating: 0, count: fftSize)
    vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
    hann.withUnsafeBufferPointer { buffer in
      if let base = buffer.baseAddress {
        window.initialize(from: base, count: fftSize)
      }
    }

    self.fftSize = fftSize
    self.sampleRate = sampleRate
    self.log2n = log2n
    self.setup = setup
    self.window = window
    self.windowed = windowed
    self.real = real
    self.imag = imag
    self.magnitudes = magnitudes
    self.split = DSPSplitComplex(realp: real, imagp: imag)
    self.ranges = AudioSpectrumMapping.bandBinRanges(
      sampleRate: sampleRate, fftSize: fftSize, bandCount: bandCount)
    self.fftScale = 2 / Float(fftSize)
    self.previousLeft = [Float](repeating: 0, count: bandCount)
    self.previousRight = [Float](repeating: 0, count: bandCount)
  }

  deinit {
    vDSP_destroy_fftsetup(setup)
    window.deallocate()
    windowed.deallocate()
    real.deallocate()
    imag.deallocate()
    magnitudes.deallocate()
  }

  /// Analyses one buffer. `left` and `right` point at `frameCount` interleaved
  /// floats each; pass nil for `right` to use the left channel for both. Frames
  /// beyond `fftSize` are ignored; a short buffer is zero-padded.
  func analyze(
    left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frameCount: Int
  ) -> AudioSpectrum? {
    guard frameCount > 0, !ranges.isEmpty else { return nil }
    let frames = min(frameCount, fftSize)
    let leftLevels = analyseChannel(left, frames: frames)
    let rightLevels: [Float]
    if let right {
      rightLevels = analyseChannel(right, frames: frames)
    } else {
      rightLevels = leftLevels
    }
    previousLeft = AudioSpectrumMapping.smoothed(previous: previousLeft, current: leftLevels)
    previousRight = AudioSpectrumMapping.smoothed(previous: previousRight, current: rightLevels)
    return AudioSpectrum(left: previousLeft, right: previousRight)
  }

  private func analyseChannel(_ samples: UnsafePointer<Float>, frames: Int) -> [Float] {
    let half = fftSize / 2
    windowed.initialize(repeating: 0, count: fftSize)
    vDSP_vmul(samples, 1, window, 1, windowed, 1, vDSP_Length(frames))
    windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
      vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
    }
    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
    vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(half))
    let magnitudeArray = Array(UnsafeBufferPointer(start: magnitudes, count: half))
    return AudioSpectrumMapping.levels(
      magnitudes: magnitudeArray, ranges: ranges, scale: fftScale)
  }
}
