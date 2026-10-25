import Foundation

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

  init(analyzer: MicrophoneAudioAnalyzer = MicrophoneAudioAnalyzer()) {
    self.analyzer = analyzer
    permission = analyzer.permission
    analyzer.onSpectrum = { [weak self] spectrum in
      guard let self, self.isEnabled else { return }
      self.webView?.deliverAudio(spectrum.webBins)
      self.onSceneSpectrum?(spectrum)
    }
    analyzer.onFailure = { [weak self] failure in
      self?.onFailure?(failure)
    }
  }

  var latestSpectrum: AudioSpectrum { analyzer.latest }

  /// Applies `PlaybackSettings.microphoneEnabled`; the permission prompt is only
  /// requested when the setting turns on, never at launch.
  func apply(settings: PlaybackSettings) {
    setEnabled(settings.microphoneEnabled)
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    guard enabled else {
      analyzer.stop()
      permission = analyzer.permission
      webView?.setAudioResponseEnabled(false)
      return
    }
    webView?.setAudioResponseEnabled(true)
    Task { [weak self] in
      await self?.startIfPermitted()
    }
  }

  /// Re-reads the system permission without prompting, for when the user returns
  /// from Settings.
  func refreshPermission() {
    permission = MicrophoneAudioAnalyzer.currentPermission()
    guard isEnabled else { return }
    if permission == .granted, !analyzer.isRunning {
      Task { [weak self] in await self?.startIfPermitted() }
    } else if permission != .granted, analyzer.isRunning {
      analyzer.stop()
    }
  }

  private func startIfPermitted() async {
    guard isEnabled else { return }
    permission = await analyzer.requestPermission()
    guard isEnabled else { return }
    switch permission {
    case .granted:
      do {
        try analyzer.start()
      } catch let failure as MicrophoneFailure {
        report(failure)
      } catch {
        report(.engine(error.localizedDescription))
      }
    case .denied:
      report(.permissionDenied)
    case .undetermined:
      report(.permissionNotDetermined)
    }
  }

  private func report(_ failure: MicrophoneFailure) {
    MediaLog.warning("microphone audio response unavailable: \(failure.localizedDescription)")
    onFailure?(failure)
  }
}
