import SwiftUI
import UIKit

/// Preview column and editable inspector for one wallpaper.
struct WMItemDetailView: View {
    @ObservedObject var model: WMAppModel
    let item: WallpaperItem

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                if proxy.size.width >= 820 {
                    HStack(alignment: .top, spacing: 20) {
                        previewColumn
                            .frame(maxWidth: .infinity)
                        inspectorColumn
                            .frame(width: 330)
                    }
                    .padding(20)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        previewColumn
                        inspectorColumn
                    }
                    .padding(16)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationTitle(Text(verbatim: item.title))
        .wmErrorAlert(model: model)
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            WMPreviewStage(
                item: item,
                url: model.playbackURL(for: item),
                settings: model.library.settings,
                microphoneResponse: model.microphoneResponse
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)

            WMControlBar(model: model, item: item)

            Text("inspector.iosOnlyNote")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inspectorColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            WMDetailsSection(item: item)
            WMPlaybackSection(model: model, item: item)
            WMPropertiesSection(model: model, item: item)
            WMCollectionsSection(model: model, item: item)
            WMPlaylistSection(model: model, item: item)
            WMRemoveSection(model: model, item: item)
        }
    }
}

// MARK: - Control bar

struct WMControlBar: View {
    @ObservedObject var model: WMAppModel
    let item: WallpaperItem

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    model.toggleFavorite(item)
                } label: {
                    Label(favoriteKey, systemImage: item.isFavorite ? "heart.fill" : "heart")
                }
                .accessibilityIdentifier("wm.preview.favorite")

                Button {
                    model.togglePlaylistMembership(item)
                } label: {
                    Label(playlistKey, systemImage: model.isInPlaylist(item) ? "minus.circle" : "plus.circle")
                }
                .accessibilityIdentifier("wm.preview.playlist")

                if model.canPlayPlaylist {
                    Button {
                        model.togglePlaylistPlayback()
                    } label: {
                        Label(playbackKey, systemImage: model.isPlaylistPlaying ? "pause.fill" : "play.fill")
                    }
                    .accessibilityIdentifier("wm.preview.playpause")

                    Button {
                        model.advancePlaylist(by: -1)
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    .accessibilityLabel(Text("preview.previous"))
                    .accessibilityIdentifier("wm.preview.previous")

                    Button {
                        model.advancePlaylist(by: 1)
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    .accessibilityLabel(Text("preview.next"))
                    .accessibilityIdentifier("wm.preview.next")
                }

                Divider()
                    .frame(height: 24)

                Button {
                    model.beginExport(item)
                } label: {
                    Label("preview.export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("wm.export")

                Button {
                    model.isFullscreenPresented = true
                } label: {
                    Label("preview.fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityIdentifier("wm.preview.fullscreen")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var favoriteKey: LocalizedStringKey {
        item.isFavorite ? "preview.unfavorite" : "preview.favorite"
    }

    private var playlistKey: LocalizedStringKey {
        model.isInPlaylist(item) ? "playlist.remove" : "playlist.add"
    }

    private var playbackKey: LocalizedStringKey {
        model.isPlaylistPlaying ? "playlist.pause" : "playlist.play"
    }
}

// MARK: - Inspector sections

private struct WMDetailsSection: View {
    let item: WallpaperItem

    var body: some View {
        WMInspectorCard("inspector.details") {
            VStack(alignment: .leading, spacing: 8) {
                detailRow(label: Text("inspector.kind"), value: Text(item.kind.wmLocalizedKey))
                detailRow(
                    label: Text("inspector.added"),
                    value: Text(verbatim: item.addedAt.formatted(date: .abbreviated, time: .omitted))
                )
                if let workshopID = item.workshopID, !workshopID.isEmpty {
                    detailRow(label: Text("inspector.workshopID"), value: Text(verbatim: workshopID))
                }
            }
        }
    }

    private func detailRow(label: Text, value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            label
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

private struct WMPlaybackSection: View {
    @ObservedObject var model: WMAppModel
    let item: WallpaperItem

    var body: some View {
        if item.kind == .web {
            WMInspectorCard("inspector.playback") {
                Text("inspector.playback.webNote")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            WMInspectorCard("inspector.playback") {
                VStack(alignment: .leading, spacing: 12) {
                    if showsAudioControls {
                        HStack {
                            Text("settings.volume")
                            Spacer()
                            Text(verbatim: "\(Int((model.library.settings.volume * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.callout)
                        Slider(value: volumeBinding, in: 0...1)
                            .accessibilityLabel(Text("settings.volume"))
                            .accessibilityIdentifier("wm.item.volume")

                        Toggle("settings.mute", isOn: muteBinding)
                            .accessibilityIdentifier("wm.item.mute")
                    }

                    if showsRenderControls {
                        HStack {
                            Text("settings.fps")
                            Spacer()
                            Picker("settings.fps", selection: fpsBinding) {
                                ForEach(fpsOptions, id: \.self) { fps in
                                    Text(verbatim: WMLocalized.format("settings.fpsValue", fps))
                                        .tag(fps)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("wm.item.fps")
                        }
                        .font(.callout)

                        HStack {
                            Text("settings.renderScale")
                            Spacer()
                            Text(verbatim: "\(Int((model.library.settings.renderScale * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.callout)
                        Slider(value: renderScaleBinding, in: 0.25...1.0, step: 0.05)
                            .accessibilityLabel(Text("settings.renderScale"))
                            .accessibilityIdentifier("wm.item.renderScale")
                    }

                    if showsScalingControl {
                        HStack {
                            Text("settings.scaling")
                            Spacer()
                            Picker("settings.scaling", selection: scalingBinding) {
                                Text("settings.scaling.fit").tag("fit")
                                Text("settings.scaling.fill").tag("fill")
                                Text("settings.scaling.stretch").tag("stretch")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("wm.item.scaling")
                        }
                        .font(.callout)
                    }

                    Text("inspector.playback.footnote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var showsAudioControls: Bool {
        item.kind == .scene || item.kind == .video
    }

    private var showsRenderControls: Bool {
        item.kind == .scene || item.kind == .video
    }

    private var showsScalingControl: Bool {
        item.kind == .image
    }

    private var fpsOptions: [Int] {
        let standard = [24, 30, 60, 120]
        let current = model.library.settings.framesPerSecond
        return standard.contains(current) ? standard : [current] + standard
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { model.library.settings.volume },
            set: { value in
                model.updateSettings { $0.volume = value }
            }
        )
    }

    private var muteBinding: Binding<Bool> {
        Binding(
            get: { model.library.settings.isMuted },
            set: { value in
                model.updateSettings { $0.isMuted = value }
            }
        )
    }

    private var fpsBinding: Binding<Int> {
        Binding(
            get: { model.library.settings.framesPerSecond },
            set: { value in
                model.updateSettings { $0.framesPerSecond = value }
            }
        )
    }

    private var renderScaleBinding: Binding<Double> {
        Binding(
            get: { model.library.settings.renderScale },
            set: { value in
                model.updateSettings { $0.renderScale = value }
            }
        )
    }

    private var scalingBinding: Binding<String> {
        Binding(
            get: { model.library.settings.scaling },
            set: { value in
                model.updateSettings { $0.scaling = value }
            }
        )
    }
}

private struct WMCollectionsSection: View {
    @ObservedObject var model: WMAppModel
    let item: WallpaperItem

    var body: some View {
        WMInspectorCard("inspector.collections") {
            VStack(alignment: .leading, spacing: 10) {
                if model.sortedCollections.isEmpty {
                    Text("collection.none")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sortedCollections, id: \.self) { name in
                        Toggle(
                            isOn: Binding(
                                get: { item.collections.contains(name) },
                                set: { isOn in
                                    model.setCollectionMembership(name, isOn: isOn, itemID: item.id)
                                }
                            )
                        ) {
                            Text(verbatim: name)
                        }
                        .accessibilityIdentifier("wm.collection.membership.\(name)")
                    }
                }

                Button {
                    model.beginCreatingCollection(addingItemID: item.id)
                } label: {
                    Label("collection.new", systemImage: "folder.badge.plus")
                }
                .font(.callout)
                .accessibilityIdentifier("wm.collection.new")
            }
        }
    }
}

private struct WMPlaylistSection: View {
    @ObservedObject var model: WMAppModel
    let item: WallpaperItem

    var body: some View {
        WMInspectorCard("inspector.playlist") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    model.togglePlaylistMembership(item)
                } label: {
                    Label(
                        playlistMembershipKey,
                        systemImage: model.isInPlaylist(item) ? "minus.circle" : "plus.circle"
                    )
                }
                .font(.callout)
                .accessibilityIdentifier("wm.playlist.membership")

                Button {
                    model.startPlaylistEditor()
                } label: {
                    Label("playlist.editor.title", systemImage: "list.bullet.rectangle")
                }
                .font(.callout)
                .accessibilityIdentifier("wm.playlist.edit")

                Text(verbatim: WMLocalized.format("library.itemCount", model.playlistItems.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var playlistMembershipKey: LocalizedStringKey {
        model.isInPlaylist(item) ? "playlist.remove" : "playlist.add"
    }
}

private struct WMRemoveSection: View {
    @ObservedObject var model: WMAppModel
    let item: WallpaperItem

    var body: some View {
        Button(role: .destructive) {
            model.requestRemoval(item)
        } label: {
            Label("library.remove", systemImage: "trash")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .accessibilityIdentifier("wm.item.remove")
    }
}
