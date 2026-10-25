import SwiftUI

/// Immersive preview. This is the app's only fullscreen mode; iPadOS does not let a
/// third-party app take over the Home Screen or Lock Screen, so the UI never pretends
/// otherwise.
struct WMFullscreenPreview: View {
    @ObservedObject var model: WMAppModel

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let item = model.selectedItem {
                WMPreviewStage(
                    item: item,
                    url: model.playbackURL(for: item),
                    settings: model.library.settings
                )
                .id(item.id)
                .ignoresSafeArea()

                controls(for: item)
            } else {
                VStack(spacing: 14) {
                    Text("preview.noSelection.title")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button("common.close") {
                        model.isFullscreenPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: model.selectedItemID) { _, newValue in
            if newValue == nil {
                model.isFullscreenPresented = false
            }
        }
    }

    private func controls(for item: WallpaperItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Text(verbatim: item.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    model.toggleFavorite(item)
                } label: {
                    Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                }
                .accessibilityLabel(Text(favoriteKey(for: item)))
                .accessibilityIdentifier("wm.fullscreen.favorite")

                Button {
                    model.isFullscreenPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(Text("common.close"))
                .accessibilityIdentifier("wm.fullscreen.close")
            }
            .font(.title3)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.black.opacity(0.55))

            Spacer()

            if model.canPlayPlaylist {
                HStack(spacing: 26) {
                    Button {
                        model.advancePlaylist(by: -1)
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .accessibilityLabel(Text("preview.previous"))
                    .accessibilityIdentifier("wm.fullscreen.previous")

                    Button {
                        model.togglePlaylistPlayback()
                    } label: {
                        Image(systemName: model.isPlaylistPlaying ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(Text(playbackKey))
                    .accessibilityIdentifier("wm.fullscreen.playpause")

                    Button {
                        model.advancePlaylist(by: 1)
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .accessibilityLabel(Text("preview.next"))
                    .accessibilityIdentifier("wm.fullscreen.next")
                }
                .font(.title2)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.black.opacity(0.55))
            }
        }
        .tint(.white)
    }

    private func favoriteKey(for item: WallpaperItem) -> LocalizedStringKey {
        item.isFavorite ? "preview.unfavorite" : "preview.favorite"
    }

    private var playbackKey: LocalizedStringKey {
        model.isPlaylistPlaying ? "playlist.pause" : "playlist.play"
    }
}
