import CoreMedia
import UIKit
import WebKit

/// A web wallpaper as a `WKWebView`, loaded from a project folder the user
/// imported.
///
/// Security boundary (see `WebWallpaperSecurity` for the rules):
/// - the page is loaded with `loadFileURL(entry, allowingReadAccessTo: root)`,
///   so WebKit itself refuses every file outside the project folder;
/// - the top frame cannot navigate to another project page or an outside file;
/// - external http(s) links are cancelled and reported; opening one is the UI
///   layer's decision after a confirmation, through `openExternalURL(_:)`;
/// - no page gets a general native bridge: one message handler accepts only
///   `audioSubscribed`, `audioUnsubscribed` and `randomFileRequest`, and only
///   from the main frame;
/// - the page cannot use the camera or the microphone: WebKit's capture
///   permission delegate denies both, so audio response can only come from the
///   app's own explicitly permitted microphone analyser;
/// - JavaScript dialogs and popups are refused rather than shown.
///
/// Wallpaper Engine compatibility: `wallpaperPropertyListener` (user and general
/// properties, pause, directory files), `wallpaperRegisterAudioListener` with
/// 128 bins, `wallpaperRequestRandomFileForProperty`, `wallpaperMediaIntegration`
/// constants (media listeners register but no events exist on iOS), the frame
/// rate limit on `requestAnimationFrame`, and the render-scale override of
/// `devicePixelRatio`. All of them are injected before the page's own scripts.
@MainActor
final class WebWallpaperView: UIView, MediaFrameProviding {
  let webView: WKWebView
  /// The folder WebKit may read.
  let projectRoot: URL
  /// The one document the top frame is allowed to load.
  let entryURL: URL

  private(set) var loadState: WebWallpaperLoadState = .idle {
    didSet {
      guard loadState != oldValue else { return }
      onLoadStateChange?(loadState)
    }
  }
  private(set) var loadFailure: WebWallpaperFailure?

  var onLoadStateChange: ((WebWallpaperLoadState) -> Void)?
  var onWindowVisibilityChange: ((Bool) -> Void)?
  var onFailure: ((WebWallpaperFailure) -> Void)?

  /// An http(s) navigation the page attempted. The host may show a confirmation
  /// and then call `openExternalURL(_:)`; Media never opens a browser silently.
  var onExternalNavigationRequested: ((URL) -> Void)?
  /// An immediate yes/no for a page-initiated navigation, for a host that has
  /// already presented its consent UI. Returning true opens the URL.
  var shouldOpenExternalURL: ((URL) -> Bool)?
  /// A blocked navigation, for diagnostics and for the UI to explain itself.
  var onNavigationRejected: ((WebWallpaperSecurity.Rejection) -> Void)?

  /// The Wallpaper Engine property values in force. Sending a new dictionary
  /// delivers only the changed values, as Wallpaper Engine does.
  var properties: [String: WallpaperProperty] {
    didSet { deliverUserProperties() }
  }

  /// Frames per second delivered to the page's `requestAnimationFrame`; 0 lets
  /// WebKit keep its own cadence.
  private(set) var frameRateLimit = 0
  /// Internal render scale, 0.5...1.
  private(set) var renderScale = 1.0
  private(set) var volume = 1.0
  private(set) var isMuted = false
  /// The user's pause. Backgrounding and leaving the window suspend the page too,
  /// but do not change this value.
  private(set) var isPaused = false

  private(set) var isAudioSubscribed = false
  private(set) var audioResponseEnabled = false
  private(set) var audioOutputCapabilities = WebWallpaperAudioOutput.Capabilities()

  private let messageProxy = ScriptMessageProxy()
  private var notificationTokens: [NSObjectProtocol] = []
  private var restartTask: Task<Void, Never>?
  private var restartAttempts = 0
  private var lastLoadFinished: TimeInterval?
  private var documentGeneration = 0
  private var pendingRandomRequests = Set<String>()
  private var applicationActive = true
  private var audioInFlight = false
  private var lastAudioDelivery: TimeInterval = 0
  private var holdsAudioSession = false
  private var reportedInitialFailure = false

  private var isSuspended: Bool { isPaused || !applicationActive || window == nil }

  init(url: URL, properties: [String: WallpaperProperty]) {
    self.properties = properties
    let resolved: WebWallpaperSecurity.Paths?
    let failure: WebWallpaperFailure?
    do {
      resolved = try WebWallpaperSecurity.paths(for: url)
      failure = nil
    } catch {
      resolved = nil
      failure = .invalidProject(error.localizedDescription)
    }
    projectRoot = resolved?.root ?? WebWallpaperSecurity.canonical(url)
    entryURL = resolved?.entry ?? WebWallpaperSecurity.canonical(url)
    webView = WKWebView(frame: .zero, configuration: Self.makeConfiguration())
    super.init(frame: .zero)
    backgroundColor = .black
    isOpaque = true
    configureWebView()
    if let failure {
      loadFailure = failure
      loadState = .failed(failure)
      MediaLog.error("web wallpaper project invalid: \(failure.localizedDescription)")
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.reportedInitialFailure else { return }
        self.reportedInitialFailure = true
        self.onFailure?(failure)
      }
    } else {
      installUserScripts()
      load()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("WebWallpaperView is created in code")
  }

  deinit {
    restartTask?.cancel()
    for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    if holdsAudioSession { MediaAudioSession.shared.endPlayback() }
  }

  private static func makeConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    // Web wallpapers keep their own state (tasks, favourites) in localStorage,
    // as they do under Wallpaper Engine. The data store is per app, not shared
    // with Safari.
    configuration.websiteDataStore = .default()
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.allowsInlineMediaPlayback = true
    configuration.allowsAirPlayForMediaPlayback = false
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    // A page outside the window tree is throttled, not allowed to spin.
    configuration.preferences.inactiveSchedulingPolicy = .suspend
    return configuration
  }

  private func configureWebView() {
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    webView.allowsLinkPreview = false
    webView.isOpaque = false
    webView.backgroundColor = .black
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.bounces = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.underPageBackgroundColor = .black
    webView.isInspectable = false
    addSubview(webView)
    messageProxy.owner = self
    // The controller retains the proxy and the proxy holds the view weakly, so
    // the pair cannot keep the wallpaper alive.
    webView.configuration.userContentController.add(
      messageProxy, name: WebWallpaperScript.messageHandlerName)
    MediaAudioSession.shared.beginPlayback()
    holdsAudioSession = true
    observeApplication()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    webView.frame = bounds
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onWindowVisibilityChange?(window != nil)
    syncSuspension()
  }

  // MARK: - Loading

  /// Loads the project entry again after a failure. The URL is not re-resolved.
  func retry() {
    guard loadFailure != nil || loadState == .failed(.contentProcessTerminated) || !isLoaded else {
      return
    }
    loadFailure = nil
    restartAttempts = 0
    loadState = .idle
    installUserScripts()
    load()
  }

  private var isLoaded: Bool {
    if case .loaded = loadState { return true }
    return false
  }

  private func load() {
    guard loadFailure == nil else { return }
    loadState = .loading
    // The scripts carry the frame limit and render scale for this document's
    // very first requestAnimationFrame / devicePixelRatio read.
    installUserScripts()
    pendingRandomRequests.removeAll()
    isAudioSubscribed = false
    audioOutputCapabilities = WebWallpaperAudioOutput.Capabilities()
    webView.loadFileURL(entryURL, allowingReadAccessTo: projectRoot)
  }

  private func installUserScripts() {
    let seed = WebWallpaperScript.Seed(
      framePacing: true,
      frameLimit: MediaPlayback.Values.frameLimit(frameRateLimit, ceiling: 60),
      renderScale: renderScale)
    let controller = webView.configuration.userContentController
    controller.removeAllUserScripts()
    for injection in WebWallpaperScript.injections(seed: seed) {
      controller.addUserScript(
        WKUserScript(
          source: injection.source, injectionTime: .atDocumentStart,
          forMainFrameOnly: injection.forMainFrameOnly))
    }
  }

  private func replayCommittedState() {
    deliverUserProperties()
    deliverGeneralProperties()
    deliverRenderScale()
    deliverPaused()
    deliverAudioOutput()
  }

  // MARK: - Settings

  /// Applies the app-wide playback settings. The web view has no settings in
  /// its contract, so this is the convenience the integration layer calls.
  func apply(settings: PlaybackSettings) {
    setVolume(settings.volume, muted: settings.isMuted)
    setFrameRateLimit(settings.framesPerSecond)
    setRenderScale(settings.renderScale)
    setAudioResponseEnabled(settings.microphoneEnabled)
  }

  func setVolume(_ volume: Double, muted: Bool) {
    let clamped = Double(MediaPlayback.Values.clampedVolume(volume))
    guard self.volume != clamped || isMuted != muted else { return }
    self.volume = clamped
    isMuted = muted
    deliverAudioOutput()
  }

  func setFrameRateLimit(_ fps: Int) {
    let clamped = min(max(fps, 0), 240)
    guard frameRateLimit != clamped else { return }
    frameRateLimit = clamped
    installUserScripts()
    deliverGeneralProperties()
  }

  func setRenderScale(_ scale: Double) {
    let clamped = WebWallpaperScript.clampedRenderScale(scale)
    guard renderScale != clamped else { return }
    renderScale = clamped
    installUserScripts()
    deliverRenderScale()
  }

  /// The page's audio-response setting. Delivery also requires the page to have
  /// registered its listener and the microphone adapter to be running.
  func setAudioResponseEnabled(_ enabled: Bool) {
    audioResponseEnabled = enabled
  }

  /// The user's pause. Freezing is host-side as well as cooperative: media is
  /// suspended and the page is told through `setPaused`.
  func setPaused(_ paused: Bool) {
    guard isPaused != paused else { return }
    isPaused = paused
    syncSuspension()
  }

  private func syncSuspension() {
    let suspended = isSuspended
    webView.setAllMediaPlaybackSuspended(suspended, completionHandler: {})
    deliverPaused()
  }

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
    syncSuspension()
  }

  // MARK: - Delivery

  private func deliverUserProperties() {
    guard isLoaded else { return }
    run(
      "window.__mweWallpaperHost.applyUserProperties(properties)",
      arguments: ["properties": Self.userPropertiesPayload(properties)])
  }

  private func deliverGeneralProperties() {
    guard isLoaded else { return }
    let limit = MediaPlayback.Values.frameLimit(frameRateLimit, ceiling: 60)
    run(
      """
      window.__mweWallpaperHost.applyGeneralProperties(general);
      window.__mweWallpaperHost.setFrameLimit(limit);
      """,
      arguments: ["general": ["fps": frameRateLimit], "limit": limit])
  }

  private func deliverRenderScale() {
    guard isLoaded else { return }
    run(
      "window.__mweWallpaperHost.setRenderScale(scale)",
      arguments: ["scale": renderScale])
  }

  private func deliverPaused() {
    guard isLoaded else { return }
    let suspended = isSuspended
    run("window.__mweWallpaperHost.setPaused(paused)", arguments: ["paused": suspended])
  }

  private func deliverAudioOutput() {
    guard isLoaded else { return }
    let generation = documentGeneration
    let volume = volume
    let muted = isMuted
    Task { @MainActor [weak self] in
      guard let self, self.documentGeneration == generation else { return }
      let capabilities = await WebWallpaperAudioOutput.apply(
        volume: volume, muted: muted, to: self.webView)
      guard self.documentGeneration == generation else { return }
      self.audioOutputCapabilities = capabilities
      if !capabilities.installed {
        MediaLog.warning("web wallpaper audio output script did not run")
      }
    }
  }

  /// One 128-value audio frame (64 left, then 64 right), as Wallpaper Engine's
  /// listener contract specifies. Dropped unless the page asked for it, the user
  /// allowed it, the view is live, and no earlier delivery is still in flight.
  func deliverAudio(_ bins: [Float]) {
    guard audioResponseEnabled, isAudioSubscribed, isLoaded, !isSuspended else { return }
    guard bins.count == AudioSpectrum.webBinCount, bins.allSatisfy({ $0.isFinite }) else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastAudioDelivery >= 1.0 / 30.0, !audioInFlight else { return }
    lastAudioDelivery = now
    audioInFlight = true
    let generation = documentGeneration
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.audioInFlight = false }
      guard self.documentGeneration == generation, self.audioResponseEnabled,
        self.isAudioSubscribed
      else { return }
      do {
        _ = try await self.webView.callAsyncJavaScript(
          "return window.__mweWallpaperHost.deliverAudio(bins)",
          arguments: ["bins": bins.map { Double($0) }], in: nil, contentWorld: .page)
      } catch {
        MediaLog.debug("web wallpaper audio frame dropped: \(error.localizedDescription)")
      }
    }
  }

  private func run(_ script: String, arguments: [String: Any]) {
    guard isLoaded else { return }
    let generation = documentGeneration
    Task { @MainActor [weak self] in
      guard let self, self.documentGeneration == generation else { return }
      do {
        _ = try await self.webView.callAsyncJavaScript(
          script, arguments: arguments, in: nil, contentWorld: .page)
      } catch {
        MediaLog.debug("web wallpaper host call failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Frame capture

  var frameSource: MediaFrameSource { .web }

  var isFrameCaptureReady: Bool {
    // WebKit can only snapshot a view that is in a window and has rendered.
    isLoaded && window != nil
  }

  func captureFrame(at time: CMTime?, maximumSize: CGSize) async throws -> MediaFrame {
    guard isFrameCaptureReady else { throw MediaFrameError.sourceNotReady }
    let configuration = WKSnapshotConfiguration()
    configuration.afterScreenUpdates = true
    let image: UIImage = try await withCheckedThrowingContinuation { continuation in
      webView.takeSnapshot(with: configuration) { image, error in
        if let image {
          continuation.resume(returning: image)
        } else {
          continuation.resume(throwing: error ?? MediaFrameError.snapshotUnavailable)
        }
      }
    }
    guard let full = MediaImage.cgImage(from: image) else {
      throw MediaFrameError.snapshotUnavailable
    }
    guard let scaled = MediaImage.downscaled(full, maximumSize: maximumSize) else {
      throw MediaFrameError.snapshotUnavailable
    }
    return MediaFrame(image: scaled, presentationTime: nil, source: .web)
  }

  // MARK: - Page messages

  private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: WebWallpaperView?

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      // A frame the page embeds is not the wallpaper and may belong to a remote
      // site; it may not subscribe to audio or ask for project files.
      guard message.frameInfo.isMainFrame else { return }
      let body = message.body
      let owner = owner
      Task { @MainActor in owner?.receiveScriptMessage(body) }
    }
  }

  private func receiveScriptMessage(_ body: Any) {
    guard isLoaded else { return }
    guard let payload = body as? [String: Any], let type = payload["type"] as? String else {
      MediaLog.debug("web wallpaper: malformed host message dropped")
      return
    }
    switch type {
    case "audioSubscribed":
      isAudioSubscribed = true
    case "audioUnsubscribed":
      isAudioSubscribed = false
    case "randomFileRequest":
      guard let requestId = payload["requestId"] as? String, !requestId.isEmpty,
        let propertyId = payload["propertyId"] as? String, !propertyId.isEmpty,
        pendingRandomRequests.count < 32
      else {
        MediaLog.debug("web wallpaper: malformed random file request dropped")
        return
      }
      answerRandomFile(requestId: requestId, propertyId: propertyId)
    default:
      MediaLog.debug("web wallpaper: unknown host message \(type) dropped")
    }
  }

  /// Answers `wallpaperRequestRandomFileForProperty` with a path inside the
  /// project, or an empty string when the property has no readable file. The
  /// page receives the same value shape the desktop host gives it: an absolute
  /// path without its leading slash, ready for `file:///` + value.
  private func answerRandomFile(requestId: String, propertyId: String) {
    let token = "\(documentGeneration):\(requestId)"
    pendingRandomRequests.insert(token)
    guard let property = properties[propertyId] else {
      replyRandomFile(token: token, propertyId: propertyId, path: "")
      return
    }
    let candidates = Self.stringValues(from: property.value)
    guard let chosen = candidates.randomElement(),
      let file = WebWallpaperSecurity.containedFile(chosen, root: projectRoot)
    else {
      replyRandomFile(token: token, propertyId: propertyId, path: "")
      return
    }
    replyRandomFile(
      token: token, propertyId: propertyId,
      path: WebWallpaperSecurity.pageValue(for: file))
  }

  private func replyRandomFile(token: String, propertyId: String, path: String) {
    guard pendingRandomRequests.remove(token) != nil,
      let separator = token.firstIndex(of: ":")
    else { return }
    let requestId = String(token[token.index(after: separator)...])
    run(
      "window.__mweWallpaperHost.deliverRandomFile(requestId, property, path)",
      arguments: ["requestId": requestId, "property": propertyId, "path": path])
  }

  /// Opens an external URL only after the host has confirmed it. Media checks
  /// the scheme again, so a host mistake cannot hand the page an arbitrary URL.
  func openExternalURL(_ url: URL) {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      MediaLog.warning("web wallpaper: refused to open non-web URL")
      return
    }
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
  }

  // MARK: - Initial state serialisation

  private static func userPropertiesPayload(_ properties: [String: WallpaperProperty]) -> [String: Any] {
    // `JSON.parse` on the page turns each value into the object Wallpaper Engine
    // delivers: `{ "propertyId": { "value": ??} }`. The typed model's extra
    // fields are deliberately not sent; author pages read `.value`.
    var payload: [String: Any] = [:]
    payload.reserveCapacity(properties.count)
    for (key, property) in properties {
      guard let data = try? JSONEncoder().encode(property.value),
        let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      else {
        payload[key] = ["value": NSNull()]
        continue
      }
      payload[key] = ["value": object]
    }
    return payload
  }

  private static func stringValues(from value: JSONValue) -> [String] {
    guard let data = try? JSONEncoder().encode(value),
      let object = try? JSONSerialization.jsonObject(with: data)
    else { return [] }
    if let string = object as? String { return [string] }
    if let array = object as? [Any] { return array.compactMap { $0 as? String } }
    return []
  }
}

// MARK: - WKNavigationDelegate

extension WebWallpaperView: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
    let decision = WebWallpaperSecurity.navigation(
      for: navigationAction.request.url, isMainFrame: isMainFrame,
      entry: entryURL, root: projectRoot)
    switch decision {
    case .allow:
      decisionHandler(.allow)
    case .cancel(let rejection):
      decisionHandler(.cancel)
      reject(rejection)
    }
  }

  private func reject(_ rejection: WebWallpaperSecurity.Rejection) {
    switch rejection {
    case .external(let url):
      onExternalNavigationRequested?(url)
      if shouldOpenExternalURL?(url) == true {
        openExternalURL(url)
      } else {
        MediaLog.info("web wallpaper external navigation awaiting confirmation: \(url.host ?? "unknown")")
      }
    case .fileOutsideRoot(let url):
      MediaLog.warning("web wallpaper blocked a file outside its project: \(url.lastPathComponent)")
    case .navigationAway(let url):
      MediaLog.debug("web wallpaper blocked navigation away from its entry: \(url.lastPathComponent)")
    case .unsupportedScheme(let scheme):
      MediaLog.warning("web wallpaper blocked a \(scheme) URL")
    case .missingURL:
      MediaLog.debug("web wallpaper blocked a navigation without a URL")
    }
    onNavigationRejected?(rejection)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    documentGeneration += 1
    pendingRandomRequests.removeAll()
    isAudioSubscribed = false
    loadState = .loading
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    restartAttempts = 0
    lastLoadFinished = ProcessInfo.processInfo.systemUptime
    loadState = .loaded
    replayCommittedState()
    if isSuspended {
      webView.setAllMediaPlaybackSuspended(true, completionHandler: {})
    }
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    failLoad(error)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    failLoad(error)
  }

  private func failLoad(_ error: Error) {
    guard !error.isFrameLoadInterrupted else { return }
    let failure = WebWallpaperFailure.loadFailed(error.localizedDescription)
    loadState = .failed(failure)
    onFailure?(failure)
    MediaLog.error("web wallpaper failed to load: \(error.localizedDescription)")
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    let now = ProcessInfo.processInfo.systemUptime
    if let lastLoadFinished, now - lastLoadFinished > 30 {
      restartAttempts = 0
    }
    guard restartAttempts < 3 else {
      let failure = WebWallpaperFailure.contentProcessTerminated
      loadState = .failed(failure)
      onFailure?(failure)
      MediaLog.error("web wallpaper content process terminated; restart budget exhausted")
      return
    }
    restartAttempts += 1
    loadState = .loading
    let delay = pow(2, Double(restartAttempts - 1))
    restartTask?.cancel()
    restartTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      self.load()
    }
    MediaLog.warning(
      "web wallpaper content process terminated; restart \(restartAttempts) of 3 in \(delay)s")
  }
}

// MARK: - WKUIDelegate

extension WebWallpaperView: WKUIDelegate {
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      onExternalNavigationRequested?(url)
      if shouldOpenExternalURL?(url) == true { openExternalURL(url) }
    }
    return nil
  }

  func webView(
    _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
  ) {
    MediaLog.debug("web wallpaper alert suppressed: \(message.prefix(200))")
    completionHandler()
  }

  func webView(
    _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(false)
  }

  func webView(
    _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?, initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (String?) -> Void
  ) {
    completionHandler(nil)
  }

  @available(iOS 18.4, *)
  func webView(
    _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
  ) {
    completionHandler(nil)
  }

  /// A wallpaper page never receives camera or microphone access from WebKit.
  /// The app's own microphone analyser is the only audio-response input, and it
  /// asks the user directly.
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    MediaLog.info("web wallpaper capture permission denied for \(origin.host)")
    decisionHandler(.deny)
  }

  func webView(
    _ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
    completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
  ) {
    completionHandler(nil)
  }
}

enum WebWallpaperLoadState: Equatable {
  case idle
  case loading
  case loaded
  case failed(WebWallpaperFailure)
}

enum WebWallpaperFailure: Error, Equatable, LocalizedError {
  case invalidProject(String)
  case loadFailed(String)
  case contentProcessTerminated

  var errorDescription: String? {
    switch self {
    case .invalidProject(let detail):
      return "The web wallpaper project is not usable: \(detail)"
    case .loadFailed(let detail):
      return "The web wallpaper failed to load: \(detail)"
    case .contentProcessTerminated:
      return "The web wallpaper stopped unexpectedly and could not be restarted."
    }
  }
}

extension Error {
  /// WebKit reports a cancelled provisional load as an error; a cancelled page
  /// load is not a wallpaper failure.
  fileprivate var isFrameLoadInterrupted: Bool {
    let error = self as NSError
    return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
  }
}
