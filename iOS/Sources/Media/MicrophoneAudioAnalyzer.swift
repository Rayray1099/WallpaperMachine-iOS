import AVFAudio
import Foundation

/// Why microphone analysis is unavailable. These are reported, never swallowed:
/// the UI has to tell the user whether the toggle needs permission, an input
/// device, or nothing at all.
enum MicrophoneFailure: Error, Equatable, LocalizedError {
  /// The user (or a device policy) denied the microphone.
  case permissionDenied
  /// The app has not asked yet; `requestPermission` is the only way forward.
  case permissionNotDetermined
  /// No audio input is available (for example a simulator without one).
  case noInput
  /// The audio session could not switch to recording.
  case audioSession(String)
  /// `AVAudioEngine` could not start or the tap could not be installed.
  case engine(String)

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      return "Microphone access is off. Enable it in Settings to use audio-responsive wallpapers."
    case .permissionNotDetermined:
      return "Microphone access has not been requested yet."
    case .noInput:
      return "No microphone input is available."
    case .audioSession(let detail):
      return "The microphone could not start: \(detail)"
    case .engine(let detail):
      return "Microphone analysis failed: \(detail)"
    }
  }
}

/// Captures the microphone and publishes a Wallpaper Engine-shaped spectrum.
///
/// The user must turn this on and grant microphone permission; `start()` refuses
/// otherwise. Only the microphone is read: iOS has no public API for capturing
/// other applications' audio, and the app must not claim otherwise.
///
/// Call `start`/`stop`/`requestPermission` from the main thread; the audio tap
/// runs on its own thread and returns spectra to the main queue.
final class MicrophoneAudioAnalyzer: @unchecked Sendable {
  enum Permission: String, Equatable, Sendable {
    case undetermined
    case denied
    case granted
  }

  /// 2048 frames at 44.1-48 kHz is about 21-23 spectra a second, close to the
  /// roughly 30 Hz Wallpaper Engine delivers and cheap enough for a wallpaper.
  static let tapBufferSize: AVAudioFrameCount = 2048
  static let fftSize = 2048

  private(set) var permission: Permission
  private(set) var isRunning = false
  private(set) var latest: AudioSpectrum = .silent

  var onSpectrum: ((AudioSpectrum) -> Void)?
  var onFailure: ((MicrophoneFailure) -> Void)?

  private let engine = AVAudioEngine()
  private var processor: MicrophoneSpectrumAnalyzer?
  private var tapInstalled = false
  private var observerTokens: [NSObjectProtocol] = []
  private var resumesAfterInterruption = false

  init() {
    permission = Self.currentPermission()
    installSessionObservers()
  }

  deinit {
    for token in observerTokens { NotificationCenter.default.removeObserver(token) }
    if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
    if isRunning {
      engine.stop()
      MediaAudioSession.shared.endMicrophone()
    }
  }

  static func currentPermission() -> Permission {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: return .granted
    case .denied: return .denied
    case .undetermined: return .undetermined
    @unknown default: return .undetermined
    }
  }

  /// Shows the system prompt when it has not been shown. Returns the resulting
  /// permission; never prompts twice.
  @discardableResult
  func requestPermission() async -> Permission {
    let status = Self.currentPermission()
    guard status == .undetermined else {
      permission = status
      return status
    }
    let granted = await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
    permission = granted ? .granted : .denied
    return permission
  }

  /// Starts capturing. Throws `MicrophoneFailure` when permission is missing,
  /// there is no input, or the audio session/engine refuses to start.
  func start() throws {
    guard !isRunning else { return }
    let status = Self.currentPermission()
    permission = status
    switch status {
    case .undetermined: throw MicrophoneFailure.permissionNotDetermined
    case .denied: throw MicrophoneFailure.permissionDenied
    case .granted: break
    }

    do {
      try MediaAudioSession.shared.beginMicrophone()
    } catch {
      throw MicrophoneFailure.audioSession(error.localizedDescription)
    }

    do {
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        throw MicrophoneFailure.noInput
      }
      guard let processor = MicrophoneSpectrumAnalyzer(sampleRate: format.sampleRate, fftSize: Self.fftSize)
      else {
        throw MicrophoneFailure.engine("the analyser could not be created for \(format.sampleRate) Hz")
      }
      self.processor = processor
      let channels = Int(format.channelCount)
      input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: format) {
        [weak self, processor] buffer, _ in
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let left = UnsafePointer(channelData[0])
        let right = channels > 1 ? UnsafePointer(channelData[1]) : nil
        guard let spectrum = processor.analyze(left: left, right: right, frameCount: frames)
        else { return }
        DispatchQueue.main.async { [weak self] in
          guard let self, self.isRunning else { return }
          self.latest = spectrum
          self.onSpectrum?(spectrum)
        }
      }
      tapInstalled = true
      engine.prepare()
      try engine.start()
      isRunning = true
      MediaLog.info(
        "microphone analysis started: \(Int(format.sampleRate)) Hz, \(channels) channel(s)")
    } catch {
      teardownEngine()
      MediaAudioSession.shared.endMicrophone()
      if let failure = error as? MicrophoneFailure { throw failure }
      throw MicrophoneFailure.engine(error.localizedDescription)
    }
  }

  /// Stops capturing and releases the microphone. The page is sent a silent
  /// frame once so a visualiser settles instead of freezing on the last peak.
  func stop() {
    guard isRunning || tapInstalled else { return }
    let wasRunning = isRunning
    isRunning = false
    resumesAfterInterruption = false
    teardownEngine()
    MediaAudioSession.shared.endMicrophone()
    latest = .silent
    if wasRunning { onSpectrum?(.silent) }
  }

  private func teardownEngine() {
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    engine.stop()
    processor = nil
  }

  // MARK: - Session interruptions

  private func installSessionObservers() {
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()
    observerTokens.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: session, queue: .main
      ) { [weak self] notification in
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        self?.handleInterruption(type)
      })
  }

  private func handleInterruption(_ type: AVAudioSession.InterruptionType) {
    switch type {
    case .began:
      guard isRunning else { return }
      resumesAfterInterruption = true
      isRunning = false
      teardownEngine()
      MediaAudioSession.shared.endMicrophone()
      MediaLog.info("microphone analysis paused for an audio interruption")
    case .ended:
      guard resumesAfterInterruption else { return }
      resumesAfterInterruption = false
      // An interruption that did not leave the app with the microphone is not
      // retried automatically; the next explicit start reports the reason.
      do {
        try start()
      } catch {
        MediaLog.warning("microphone analysis did not resume: \(error.localizedDescription)")
      }
    @unknown default:
      break
    }
  }
}
