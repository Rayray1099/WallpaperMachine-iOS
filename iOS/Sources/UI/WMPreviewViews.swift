import Combine
import SwiftUI
import UIKit

/// Routes a wallpaper to its real native renderer.
///
/// Scene walls go to the Metal scene host, video walls to the AVFoundation player,
/// web walls to the local WKWebView host and image walls to a native image view.
/// There is no preview-still substitute: a surface that cannot render reports why.
struct WMPreviewStage: View {
    let item: WallpaperItem
    let url: URL
    let settings: PlaybackSettings
    let microphoneResponse: MicrophoneAudioResponse

    var body: some View {
        ZStack {
            Color.black
            switch item.kind {
            case .scene:
                SceneWallpaperView(
                    url: url,
                    settings: settings,
                    properties: item.properties
                )
            case .video:
                WMVideoWallpaperView(url: url, settings: settings)
            case .web:
                WMWebWallpaperView(
                    url: url,
                    properties: item.properties,
                    settings: settings,
                    microphoneResponse: microphoneResponse)
            case .image:
                WMImageWallpaperView(url: url, scaling: settings.scaling)
            }
        }
        .accessibilityIdentifier("wm.preview")
    }
}

@MainActor
final class WMImagePreviewLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var failed = false

    func load(url: URL) async {
        failed = false
        let loaded = await WMThumbnailCache.shared.image(for: url, maxPixelSize: 2600)
        image = loaded
        failed = loaded == nil
    }
}

/// Native image surface for `image` wallpaper items, honoring the shared scaling mode.
struct WMImageWallpaperView: View {
    let url: URL
    let scaling: String

    @StateObject private var loader = WMImagePreviewLoader()

    private var mode: WMWallpaperScaling {
        WMWallpaperScaling(setting: scaling)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .modifier(WMImageScalingModifier(mode: mode, size: proxy.size))
                } else if loader.failed {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                        Text("preview.unavailable.message")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(20)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .task(id: url) {
            await loader.load(url: url)
        }
    }
}

private struct WMImageScalingModifier: ViewModifier {
    let mode: WMWallpaperScaling
    let size: CGSize

    @ViewBuilder
    func body(content: Content) -> some View {
        switch mode {
        case .fill:
            content
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        case .stretch:
            content
                .frame(width: size.width, height: size.height)
                .clipped()
        case .fit:
            content
                .scaledToFit()
                .frame(width: size.width, height: size.height)
        }
    }
}
