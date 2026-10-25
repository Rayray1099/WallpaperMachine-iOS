import Foundation
import UIKit

/// Routes microphone analysis to the surfaces that react to it.
///
/// It is the glue between the microphone (real permission, real samples) and
/// Wallpaper Engine's two response APIs:
///
/// - a web wallpaper receives the 128-bin array its
///   `wallpaperRegisterAudioListener` expects;
/// - a scene receives the same frame through `onSceneSpectrum`, where the
///   renderer maps it to SceneScript's 16/32/64 `registerAudioBuffers`
///   resolutions (`AudioSpectrum.reduced(to:)`).
///
/// It never captures other applications' audio and never reports that it does.
@MainActor
final class MicrophoneAudioResponse {
  let analyzer: MicrophoneAudioAnalyzer
  weak var webView: WebWallpaperView?

  /// Called on the main thread with one 64-band frame per update. Scenes should
  /// attach here; no SceneScript or Metal type is imported by Media.
  var onSceneSpectrum: ((AudioSpectrum) -> Void)?
  var onFailure: ((MicrophoneFailure) -> Void)?

  private(set) var isEnabled = false
  private(set) var permission: MicrophoneAudioAnalyzer.Permission

  private var applicationActive: Bool {
    didSet { reconcileCapture() }
  }
  private var visibleWebViewCount = 0
  private var startGeneration = 0
  private var notificationTokens: [NSObjectProtocol] = []

  private var eligibility: MicrophoneCaptureEligibility {
    MicrophoneCaptureEligibility(
      isEnabled: isEnabled,
      applicationActive: applicationActive,
      visibleConsumerCount: visibleWebViewCount)
  }

  private var shouldCapture: Bool { eligibility.shouldCapture }

  init(analyzer: MicrophoneAudioAnalyzer = MicrophoneAudioAnalyzer()) {
    self.analyzer = analyzer
    applicationActive = UIApplication.shared.applicationState == .active
    permission = analyzer.permission
    analyzer.onSpectrum = { [weak self] spectrum in
      guard let self, self.shouldCapture else { return }
      self.webView?.deliverAudio(spectrum.webBins)
      self.onSceneSpectrum?(spectrum)
    }

    let center = NotificationCenter.default
    notificationTokens.append(
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in self?.setApplicationActive(true) }
      })
    notificationTokens.append(
      center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in self?.setApplicationActive(false) }
      })
    analyzer.onFailure = { [weak self] failure in
      self?.onFailure?(failure)
    }
  }

  deinit {
    for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
  }

  var latestSpectrum: AudioSpectrum { analyzer.latest }

  /// A surface registers only while it is attached to a visible window.
  func setWebSurface(_ surface: WebWallpaperView?, visible: Bool) {
    if let current = webView, current !== surface {
      current.setAudioResponseEnabled(false)
    }
    webView = surface
    visibleWebViewCount = visible && surface != nil ? 1 : 0
    surface?.setAudioResponseEnabled(isEnabled)
    reconcileCapture()
  }

  func setApplicationActive(_ active: Bool) {
    guard applicationActive != active else { return }
    applicationActive = active
  }

  /// Applies `PlaybackSettings.microphoneEnabled`; the permission prompt is only
  /// requested when the setting turns on, never at launch.
  func apply(settings: PlaybackSettings) {
    setEnabled(settings.microphoneEnabled)
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    webView?.setAudioResponseEnabled(enabled)
    reconcileCapture()
  }

  /// Re-reads the system permission without prompting, for when the user returns
  /// from Settings.
  func refreshPermission() {
    permission = MicrophoneAudioAnalyzer.currentPermission()
    reconcileCapture()
  }

  private func reconcileCapture() {
    startGeneration += 1
    let generation = startGeneration
    guard shouldCapture else {
      analyzer.stop()
      return
    }
    permission = MicrophoneAudioAnalyzer.currentPermission()
    guard permission == .granted else {
      analyzer.stop()
      return
    }
    guard !analyzer.isRunning else { return }
    Task { [weak self] in
      guard let self, self.shouldCapture, self.startGeneration == generation else { return }
      do {
        try self.analyzer.start()
        self.permission = self.analyzer.permission
      } catch let failure as MicrophoneFailure {
        self.report(failure)
      } catch {
        self.report(.engine(error.localizedDescription))
      }
    }
  }

  private func report(_ failure: MicrophoneFailure) {
    MediaLog.warning("microphone audio response unavailable: \(failure.localizedDescription)")
    onFailure?(failure)
  }
}
