import SwiftUI
import UIKit

/// Shared "cannot render" state. The detail is the engine's own reason; the UI never
/// substitutes a still or a blank black rectangle for a failed surface.
struct WMUnavailableSurface: View {
    let detail: String
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
            Text("preview.unavailable")
                .font(.headline)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let onRetry {
                Button("preview.retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("wm.preview.retry")
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Video

/// SwiftUI host for Media's AVFoundation video surface.
struct WMVideoWallpaperView: View {
    let url: URL
    let settings: PlaybackSettings
    var isPaused = false

    @State private var failureDetail: String?
    @State private var retryToken = 0

    var body: some View {
        ZStack {
            Color.black
            WMVideoSurface(
                url: url,
                settings: settings,
                isPaused: isPaused,
                retryToken: retryToken,
                onFailure: { detail in
                    failureDetail = detail
                }
            )
            .id(url)

            if let failureDetail {
                WMUnavailableSurface(detail: failureDetail) {
                    self.failureDetail = nil
                    retryToken += 1
                }
            }
        }
        .onChange(of: url) { _, _ in
            failureDetail = nil
        }
    }
}

private struct WMVideoSurface: UIViewRepresentable {
    let url: URL
    let settings: PlaybackSettings
    let isPaused: Bool
    let retryToken: Int
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure, retryToken: retryToken)
    }

    func makeUIView(context: Context) -> VideoWallpaperView {
        let view = VideoWallpaperView(url: url, settings: settings)
        view.setPaused(isPaused)
        view.onFailure = { failure in
            context.coordinator.report(failure.localizedDescription)
        }
        return view
    }

    func updateUIView(_ uiView: VideoWallpaperView, context: Context) {
        context.coordinator.onFailure = onFailure
        uiView.settings = settings
        uiView.setPaused(isPaused)
        if context.coordinator.retryToken != retryToken {
            context.coordinator.retryToken = retryToken
            uiView.retry()
        }
    }

    @MainActor
    final class Coordinator {
        var onFailure: (String) -> Void
        var retryToken: Int

        init(onFailure: @escaping (String) -> Void, retryToken: Int) {
            self.onFailure = onFailure
            self.retryToken = retryToken
        }

        func report(_ detail: String) {
            onFailure(detail)
        }
    }
}

// MARK: - Web

/// SwiftUI host for Media's local WKWebView wallpaper, including the host-owned
/// confirmation before a page can open an external link.
struct WMWebWallpaperView: View {
    let url: URL
    let properties: [String: WallpaperProperty]
    let settings: PlaybackSettings
    let microphoneResponse: MicrophoneAudioResponse

    @Environment(\.openURL) private var openURL

    @State private var failureDetail: String?
    @State private var pendingExternalURL: URL?

    var body: some View {
        ZStack {
            Color.black
            WMWebSurface(
                url: url,
                properties: properties,
                settings: settings,
                microphoneResponse: microphoneResponse,
                onFailure: { detail in
                    failureDetail = detail
                },
                onExternalURL: { url in
                    pendingExternalURL = url
                }
            )
            .id(url)

            if let failureDetail {
                WMUnavailableSurface(detail: failureDetail)
            }
        }
        .onChange(of: url) { _, _ in
            failureDetail = nil
            pendingExternalURL = nil
        }
        .confirmationDialog(
            "preview.external.title",
            isPresented: Binding(
                get: { pendingExternalURL != nil },
                set: { presented in
                    if !presented { pendingExternalURL = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingExternalURL
        ) { target in
            Button("preview.external.open") {
                openURL(target)
                pendingExternalURL = nil
            }
            Button("common.cancel", role: .cancel) {
                pendingExternalURL = nil
            }
        } message: { target in
            Text(verbatim: target.absoluteString)
        }
    }
}

private struct WMWebSurface: UIViewRepresentable {
    let url: URL
    let properties: [String: WallpaperProperty]
    let settings: PlaybackSettings
    let microphoneResponse: MicrophoneAudioResponse
    let onFailure: (String) -> Void
    let onExternalURL: (URL) -> Void

    func makeUIView(context: Context) -> WebWallpaperView {
        let view = WebWallpaperView(url: url, properties: properties)
        view.onFailure = { failure in
            context.coordinator.report(failure.localizedDescription)
        }
        view.onWindowVisibilityChange = { [weak view] visible in
            guard let view else { return }
            context.coordinator.visibilityChanged(visible, view: view)
        }
        view.onExternalNavigationRequested = { url in
            context.coordinator.external(url)
        }
        view.apply(settings: settings)
        return view
    }

    func updateUIView(_ uiView: WebWallpaperView, context: Context) {
        context.coordinator.onFailure = onFailure
        context.coordinator.onExternalURL = onExternalURL
        context.coordinator.microphoneResponse = microphoneResponse
        uiView.properties = properties
        uiView.apply(settings: settings)
    }

    static func dismantleUIView(_ uiView: WebWallpaperView, coordinator: Coordinator) {
        coordinator.visibilityChanged(false, view: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onFailure: onFailure,
            onExternalURL: onExternalURL,
            microphoneResponse: microphoneResponse)
    }

    @MainActor
    final class Coordinator {
        var onFailure: (String) -> Void
        var onExternalURL: (URL) -> Void
        var microphoneResponse: MicrophoneAudioResponse

        init(
            onFailure: @escaping (String) -> Void,
            onExternalURL: @escaping (URL) -> Void,
            microphoneResponse: MicrophoneAudioResponse
        ) {
            self.onFailure = onFailure
            self.onExternalURL = onExternalURL
            self.microphoneResponse = microphoneResponse
        }

        func visibilityChanged(_ visible: Bool, view: WebWallpaperView) {
            if visible {
                microphoneResponse.setWebSurface(view, visible: true)
            } else if microphoneResponse.webView === view {
                microphoneResponse.setWebSurface(nil, visible: false)
            }
        }

        func report(_ detail: String) {
            onFailure(detail)
        }

        func external(_ url: URL) {
            onExternalURL(url)
        }
    }
}
