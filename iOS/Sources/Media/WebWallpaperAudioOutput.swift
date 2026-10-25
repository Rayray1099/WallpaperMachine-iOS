import Foundation
import WebKit

/// Page output volume for a web wallpaper.
///
/// iOS exposes no public `WKWebView` media-volume API, so the injected
/// `__wmAudioOutput` script owns it: HTML media elements are scaled while
/// keeping the page's own per-element volume, and WebAudio is routed through a
/// master `GainNode` at each context's destination. The returned capabilities
/// describe what that page actually allowed the script to reach, so a caller
/// never reports "volume works" for audio the script could not see.
enum WebWallpaperAudioOutput {
  struct Capabilities: Equatable {
    var installed = false
    var mediaElements = false
    var webAudio = false
    /// How many `AudioContext`s the script has routed at the time of the call.
    var contexts = 0
    /// How many `<video>`/`<audio>` elements the script has wrapped.
    var elements = 0
  }

  /// Applies the host volume and mute state. Returns the page's capabilities for
  /// this call; a page that removed the script or never ran it reports all
  /// false.
  @MainActor
  static func apply(volume: Double, muted: Bool, to webView: WKWebView) async -> Capabilities {
    let clamped = Double(MediaPlayback.Values.clampedVolume(volume))
    do {
      let result = try await webView.callAsyncJavaScript(
        "if (!window.__wmAudioOutput) return null; return window.__wmAudioOutput.set(volume, muted)",
        arguments: ["volume": clamped, "muted": muted], in: nil, contentWorld: .page)
      guard let payload = result as? [String: Any] else { return Capabilities() }
      return Capabilities(
        installed: payload["installed"] as? Bool ?? false,
        mediaElements: payload["mediaElements"] as? Bool ?? false,
        webAudio: payload["webAudio"] as? Bool ?? false,
        contexts: payload["contexts"] as? Int ?? 0,
        elements: payload["elements"] as? Int ?? 0)
    } catch {
      MediaLog.debug("web wallpaper volume unavailable: \(error.localizedDescription)")
      return Capabilities()
    }
  }

  /// Whether the script is present in the page. Used after a load to distinguish
  /// "the page has no audio" from "the host script did not run".
  @MainActor
  static func isInstalled(in webView: WKWebView) async -> Bool {
    do {
      return (try await webView.evaluateJavaScript("typeof window.__wmAudioOutput === 'object'") as? Bool)
        ?? false
    } catch {
      return false
    }
  }
}
