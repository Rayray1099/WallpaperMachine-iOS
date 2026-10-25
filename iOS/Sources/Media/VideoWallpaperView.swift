import AVFoundation
import CoreMedia
import UIKit

/// A video wallpaper: one `AVQueuePlayer` looped by `AVPlayerLooper`, drawn by an
/// `AVPlayerLayer`.
///
/// Supported input is what AVFoundation itself opens: MP4 and MOV containers
/// with H.264 or HEVC video (and AAC audio). WebM and Matroska are refused with a
/// named reason; see `MediaVideoProbe` and `docs/ios/MEDIA.md`.
///
/// The view owns only presentation. It pauses on backgrounding and on leaving
/// the window, resumes when it is visible again unless the user paused it, and
/// never starts a download or a security-scoped resource. The caller must hand it
/// a URL the app can already read (the managed library copies imports into the
/// app container).
@MainActor
final class VideoWallpaperView: UIView, MediaFrameProviding {
  let url: URL
  private(set) var playbackState: MediaPlayback.State = .idle {
    didSet {
      guard playbackState != oldValue else { return }
      onStateChange?(playbackState)
    }
  }

  /// The settings in force. Changing them never restarts the file; volume, mute,
  /// scaling and the decoder-resolution hint are applied live.
  var settings: PlaybackSettings {
    didSet { apply(settings: settings) }
  }

  /// The file's real codec and duration, available after `prepare` succeeds.
  private(set) var videoInfo: MediaPlayback.VideoInfo?

  var onStateChange: ((MediaPlayback.State) -> Void)?
  var onFailure: ((MediaPlayback.Failure) -> Void)?
  /// Called once the file has been opened and its codec is known.
  var onPrepared: ((MediaPlayback.VideoInfo) -> Void)?

  private let player = AVQueuePlayer()
  private var looper: AVPlayerLooper?
  private var item: AVPlayerItem?
  private var prepared: MediaPreparedVideo?
  private var prepareTask: Task<Void, Never>?
  private var timeControlObservation: NSKeyValueObservation?
  private var notificationTokens: [NSObjectProtocol] = []
  private var userPaused = false
  private var applicationActive = true
  private var holdsAudioSession = false
  private var diagnosticsGeneration = 0

  private var playerLayer: AVPlayerLayer {
    guard let layer = layer as? AVPlayerLayer else {
      preconditionFailure("VideoWallpaperView's layer class must stay AVPlayerLayer")
    }
    return layer
  }

  override class var layerClass: AnyClass { AVPlayerLayer.self }

  init(url: URL, settings: PlaybackSettings) {
    self.url = url
    self.settings = settings
    super.init(frame: .zero)
    backgroundColor = .black
    isOpaque = true
    playerLayer.player = player
    playerLayer.videoGravity = Self.videoGravity(for: settings.scaling)
    player.volume = MediaPlayback.Values.clampedVolume(settings.volume)
    player.isMuted = settings.isMuted
    player.automaticallyWaitsToMinimizeStalling = false
    player.preventsDisplaySleepDuringVideoPlayback = false
    observePlayer()
    observeApplication()
    prepare()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("VideoWallpaperView is created in code")
  }

  deinit {
    prepareTask?.cancel()
    timeControlObservation?.invalidate()
    for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    player.pause()
    if holdsAudioSession { MediaAudioSession.shared.endPlayback() }
  }

  // MARK: - Preparation

  /// Opens the file. Safe to call again after a failure.
  func retry() {
    guard prepareTask == nil else { return }
    prepared = nil
    videoInfo = nil
    looper = nil
    item = nil
    player.removeAllItems()
    playbackState = .idle
    prepare()
  }

  private func prepare() {
    playbackState = .preparing
    let url = self.url
    prepareTask = Task { [weak self] in
      let result = await MediaVideoProbe.prepare(url: url)
      guard !Task.isCancelled, let self else { return }
      self.prepareTask = nil
      switch result {
      case .failure(let failure):
        self.fail(failure)
      case .success(let prepared):
        self.install(prepared)
      }
    }
  }

  private func install(_ prepared: MediaPreparedVideo) {
    self.prepared = prepared
    videoInfo = prepared.info
    let item = AVPlayerItem(asset: prepared.asset)
    item.preferredForwardBufferDuration = 0
    self.item = item
    // AVPlayerLooper queues the template item repeatedly and takes ownership of
    // the queue, which is what makes the wrap gapless: the next pass is already
    // prepared before the current one ends.
    looper = AVPlayerLooper(player: player, templateItem: item)
    playerLayer.player = player
    apply(settings: settings)
    updatePreferredMaximumResolution()
    onPrepared?(prepared.info)
    MediaLog.info(
      "video wallpaper opened: \(prepared.info.codec) "
        + "\(Int(prepared.info.codedSize.width))x\(Int(prepared.info.codedSize.height)), "
        + "\(String(format: "%.2f", prepared.info.duration.seconds))s")
    syncPlayback()
    verifyLooper(after: 0.6)
  }

  /// `AVPlayerLooper` reports a setup it could not perform through `error`
  /// rather than by throwing, so a short grace period is the only way to catch a
  /// file whose timing cannot be looped before the surface stays black.
  private func verifyLooper(after delay: TimeInterval) {
    diagnosticsGeneration += 1
    let generation = diagnosticsGeneration
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, self.diagnosticsGeneration == generation, let looper = self.looper else { return }
      if let error = looper.error {
        self.fail(.playbackFailed("seamless looping is unavailable: \(error.localizedDescription)"))
      }
    }
  }

  // MARK: - Settings

  private func apply(settings: PlaybackSettings) {
    playerLayer.videoGravity = Self.videoGravity(for: settings.scaling)
    player.volume = MediaPlayback.Values.clampedVolume(settings.volume)
    player.isMuted = settings.isMuted
    updatePreferredMaximumResolution()
    updateAudioSession()
  }

  /// The decoder-resolution hint, which AVFoundation honours for adaptive
  /// sources and may ignore for a local file. It is a hint, not a transcode: the
  /// picture quality of a local file is always the file's own.
  private func updatePreferredMaximumResolution() {
    guard let item else { return }
    let size = bounds.size
    guard size.width > 0, size.height > 0 else { return }
    if MediaPlayback.Values.clampedRenderScale(settings.renderScale) >= 1 {
      item.preferredMaximumResolution = .zero
      return
    }
    item.preferredMaximumResolution = MediaPlayback.Values.scaledPixelSize(
      width: Double(size.width), height: Double(size.height),
      nativeScale: Double(traitCollection.displayScale), renderScale: settings.renderScale)
  }

  private func updateAudioSession() {
    let wantsAudio = !settings.isMuted && MediaPlayback.Values.clampedVolume(settings.volume) > 0
      && prepared?.info.hasAudio == true
    if wantsAudio, !holdsAudioSession {
      MediaAudioSession.shared.beginPlayback()
      holdsAudioSession = true
    } else if !wantsAudio, holdsAudioSession {
      MediaAudioSession.shared.endPlayback()
      holdsAudioSession = false
    }
  }

  // MARK: - Playback

  /// The caller's pause. It survives backgrounding: a user-paused wallpaper is
  /// not resumed when the app comes back.
  func setPaused(_ paused: Bool) {
    guard userPaused != paused else { return }
    userPaused = paused
    syncPlayback()
  }

  var isPaused: Bool { userPaused }

  private func syncPlayback() {
    guard prepared != nil else { return }
    let shouldPlay = !userPaused && applicationActive && window != nil
    if shouldPlay {
      player.play()
    } else {
      player.pause()
      playbackState = .paused
    }
  }

  private func observePlayer() {
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
      let status = player.timeControlStatus
      Task { @MainActor in self?.timeControlChanged(status) }
    }
    let center = NotificationCenter.default
    notificationTokens.append(
      center.addObserver(
        forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let failed = notification.object as? AVPlayerItem else { return }
        Task { @MainActor in self?.itemFailed(failed) }
      })
    notificationTokens.append(
      center.addObserver(
        forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let stalled = notification.object as? AVPlayerItem else { return }
        Task { @MainActor in self?.itemStalled(stalled) }
      })
  }

  private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
    guard prepared != nil else { return }
    switch status {
    case .playing:
      playbackState = .playing
    case .waitingToPlayAtSpecifiedRate:
      playbackState = .preparing
    case .paused:
      if userPaused || !applicationActive || window == nil {
        playbackState = .paused
      } else if playbackState == .playing {
        playbackState = .paused
      }
    @unknown default:
      break
    }
  }

  private func itemFailed(_ failedItem: AVPlayerItem) {
    guard player.items().contains(where: { $0 === failedItem }) else { return }
    let reason = failedItem.error?.localizedDescription ?? "the player rejected the file"
    fail(.playbackFailed(reason))
  }

  private func itemStalled(_ stalledItem: AVPlayerItem) {
    guard player.items().contains(where: { $0 === stalledItem }) else { return }
    MediaLog.warning("video wallpaper stalled: \(stalledItem.error?.localizedDescription ?? "unknown reason")")
  }

  private func fail(_ failure: MediaPlayback.Failure) {
    player.pause()
    playbackState = .failed(failure)
    MediaLog.error("video wallpaper failed: \(failure.localizedDescription)")
    onFailure?(failure)
  }

  // MARK: - Lifecycle

  private func observeApplication() {
    let center = NotificationCenter.default
    for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification] {
      notificationTokens.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.applicationBecameActive(false) }
        })
    }
    for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
      notificationTokens.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.applicationBecameActive(true) }
        })
    }
  }

  private func applicationBecameActive(_ active: Bool) {
    guard applicationActive != active else { return }
    applicationActive = active
    syncPlayback()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    syncPlayback()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updatePreferredMaximumResolution()
  }

  // MARK: - Frame capture

  var frameSource: MediaFrameSource { .video }

  var isFrameCaptureReady: Bool {
    prepared != nil && playbackState.failure == nil
  }

  func captureFrame(at time: CMTime?, maximumSize: CGSize) async throws -> MediaFrame {
    guard let prepared, let videoInfo else { throw MediaFrameError.sourceNotReady }
    let duration = videoInfo.duration
    var requested: CMTime
    if let time {
      guard time.isValid, time.seconds >= 0, time.seconds <= duration.seconds else {
        throw MediaFrameError.timeOutsideSource(time)
      }
      requested = time
    } else {
      requested = player.currentTime()
      if !requested.isValid || requested.seconds < 0 { requested = .zero }
      if requested.seconds >= duration.seconds {
        requested = CMTimeSubtract(duration, CMTime(value: 1, timescale: 600))
      }
    }

    let generator = AVAssetImageGenerator(asset: prepared.asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    if maximumSize.width > 0 || maximumSize.height > 0 {
      generator.maximumSize = maximumSize
    }

    do {
      let (image, actualTime) = try await generator.image(at: requested)
      return MediaFrame(image: image, presentationTime: actualTime, source: .video)
    } catch {
      if let known = error as? MediaFrameError { throw known }
      throw MediaFrameError.noFrameAtTime(requested)
    }
  }

  private static func videoGravity(for scaling: String) -> AVLayerVideoGravity {
    switch MediaScaling(setting: scaling) {
    case .fit: return .resizeAspect
    case .fill: return .resizeAspectFill
    case .stretch: return .resize
    }
  }
}
