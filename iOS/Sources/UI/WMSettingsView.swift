import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Global playback/settings surface plus real backup, microphone permission and
/// shortcut documentation. Every control here changes a value the renderer, media
/// hosts or the library store actually reads.
struct WMSettingsView: View {
    @ObservedObject var model: WMAppModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var isRestorePickerPresented = false
    @State private var pendingRestoreURL: URL?

    var body: some View {
        WMSheetContainer(titleKey: "settings.title", onClose: { model.isSettingsPresented = false }) {
            Form {
                playbackSection
                playlistSection
                microphoneSection
                librarySection
                shortcutsSection
                aboutSection
            }
            .onAppear {
                model.refreshMicrophonePermission()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.refreshMicrophonePermission()
                }
            }
        }
        .fileImporter(
            isPresented: $isRestorePickerPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                pendingRestoreURL = urls.first
            case .failure(let error):
                model.presentError(error.localizedDescription)
            }
        }
        .confirmationDialog(
            "settings.library.restore.confirm.title",
            isPresented: Binding(
                get: { pendingRestoreURL != nil },
                set: { presented in
                    if !presented { pendingRestoreURL = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("settings.library.restore.confirm.action", role: .destructive) {
                if let url = pendingRestoreURL {
                    model.restoreBackup(from: url)
                }
                pendingRestoreURL = nil
            }
            Button("common.cancel", role: .cancel) {
                pendingRestoreURL = nil
            }
        } message: {
            Text("settings.library.restore.confirm.message")
        }
        .sheet(item: $model.backupExport, onDismiss: { model.finishBackupExport() }) { export in
            WMDocumentExporter(urls: [export.url], onFinish: { model.finishBackupExport() })
        }
        .wmErrorAlert(model: model)
    }

    // MARK: - Playback

    private var playbackSection: some View {
        Section {
            HStack {
                Text("settings.volume")
                Spacer()
                Text(verbatim: "\(Int((model.library.settings.volume * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: volumeBinding, in: 0...1)
                .accessibilityLabel(Text("settings.volume"))
                .accessibilityIdentifier("wm.settings.volume")

            Toggle("settings.mute", isOn: muteBinding)
                .accessibilityIdentifier("wm.settings.mute")

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
                .accessibilityIdentifier("wm.settings.fps")
            }

            HStack {
                Text("settings.renderScale")
                Spacer()
                Text(verbatim: "\(Int((model.library.settings.renderScale * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: renderScaleBinding, in: 0.25...1.0, step: 0.05)
                .accessibilityLabel(Text("settings.renderScale"))
                .accessibilityIdentifier("wm.settings.renderScale")

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
                .accessibilityIdentifier("wm.settings.scaling")
            }
        } header: {
            Text("settings.playback")
        } footer: {
            Text("settings.playback.footnote")
        }
    }

    // MARK: - Playlist

    private var playlistSection: some View {
        Section {
            HStack {
                Text("settings.playlist.interval")
                Spacer()
                Text(verbatim: WMLocalized.format("settings.seconds", Int(model.library.settings.playlistInterval.rounded())))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: playlistIntervalBinding, in: 2...600, step: 1)
                .accessibilityLabel(Text("settings.playlist.interval"))
                .accessibilityIdentifier("wm.settings.playlistInterval")
            Button {
                model.startPlaylistEditor()
            } label: {
                Label("playlist.editor.title", systemImage: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("wm.settings.playlist.edit")
        } header: {
            Text("settings.playlist")
        } footer: {
            Text("settings.playlist.footnote")
        }
    }

    // MARK: - Microphone

    private var microphoneSection: some View {
        Section {
            Toggle("settings.microphone", isOn: microphoneBinding)
                .accessibilityIdentifier("wm.settings.microphone")

            HStack {
                Text("settings.microphone.status")
                Spacer()
                Text(verbatim: WMLocalized.string(model.microphone.statusKey))
                    .foregroundStyle(.secondary)
            }

            if model.microphone.permission == .denied {
                Button {
                    model.openMicrophoneSystemSettings()
                } label: {
                    Label("settings.microphone.openSettings", systemImage: "gear")
                }
                .accessibilityIdentifier("wm.settings.microphone.openSettings")
            }
        } header: {
            Text("settings.microphone.section")
        } footer: {
            Text("settings.microphone.footnote")
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        Section {
            HStack {
                Text("settings.library.items")
                Spacer()
                Text(verbatim: "\(model.library.items.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                model.exportBackup()
            } label: {
                Label("settings.library.export", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("wm.settings.exportBackup")

            Button {
                isRestorePickerPresented = true
            } label: {
                Label("settings.library.restore", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("wm.settings.restoreBackup")
        } header: {
            Text("settings.library")
        } footer: {
            Text("settings.library.footnote")
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        Section("settings.keyboard") {
            shortcutRow("settings.keyboard.import", keys: "⌘O")
            shortcutRow("settings.keyboard.search", keys: "⌘F")
            shortcutRow("settings.keyboard.favorite", keys: "⇧⌘D")
            shortcutRow("settings.keyboard.fullscreen", keys: "⌃⌘F")
            shortcutRow("settings.keyboard.playlist", keys: "⇧⌘P")
            shortcutRow("settings.keyboard.next", keys: "⌘→")
            shortcutRow("settings.keyboard.previous", keys: "⌘←")
            shortcutRow("settings.title", keys: "⌘,")
        }
    }

    private func shortcutRow(_ titleKey: LocalizedStringKey, keys: String) -> some View {
        HStack {
            Text(titleKey)
            Spacer()
            Text(verbatim: keys)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("settings.about") {
            HStack {
                Text("settings.about.version")
                Spacer()
                Text(verbatim: versionString)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("settings.about.build")
                Spacer()
                Text(verbatim: buildString)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("settings.about.language")
                Spacer()
                Text("settings.about.language.system")
                    .foregroundStyle(.secondary)
            }
            Text("settings.about.language.footnote")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("settings.about.note")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var buildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    // MARK: - Bindings

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

    private var playlistIntervalBinding: Binding<Double> {
        Binding(
            get: { model.library.settings.playlistInterval },
            set: { value in
                model.updateSettings { $0.playlistInterval = value }
            }
        )
    }

    private var microphoneBinding: Binding<Bool> {
        Binding(
            get: { model.library.settings.microphoneEnabled },
            set: { value in
                model.setMicrophoneEnabled(value)
            }
        )
    }
}
