// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import UniformTypeIdentifiers

/// Explicit Files consent for private, user-owned shared assets. The host owns
/// renderer suspension/recreation; this view never starts rendering or a server.
struct SceneSharedAssetsView: View {
    let onWillInstall: @MainActor @Sendable () async throws -> Void
    let onInstalled: @MainActor (SceneSharedAssetsInstaller.Receipt) -> Void
    let onInstallationFinished: @MainActor () -> Void

    @State private var installer = SceneSharedAssetsInstaller()
    @State private var showingPicker = false
    @State private var installing = false
    @State private var importTask: Task<Void, Never>?
    @State private var receipt: SceneSharedAssetsInstaller.Receipt?
    @State private var statusKey: String?

    init(onWillInstall: @escaping @MainActor @Sendable () async throws -> Void,
         onInstalled: @escaping @MainActor (SceneSharedAssetsInstaller.Receipt) -> Void,
         onInstallationFinished: @escaping @MainActor () -> Void = {}) {
        self.onWillInstall = onWillInstall
        self.onInstalled = onInstalled
        self.onInstallationFinished = onInstallationFinished
    }

    var body: some View {
        Section {
            Button("scene.assets.import") { showingPicker = true }
                .disabled(installing)
                .accessibilityIdentifier("wm.settings.sharedAssets.import")
            if installing {
                ProgressView("scene.assets.installing")
                    .accessibilityIdentifier("wm.settings.sharedAssets.progress")
                Button("common.cancel", role: .cancel) { importTask?.cancel() }
            }
            if let statusKey {
                Text(LocalizedStringKey(statusKey))
                    .foregroundStyle(receipt == nil ? Color.secondary : Color.primary)
                    .accessibilityIdentifier("wm.settings.sharedAssets.status")
            }
            if let receipt {
                Text(verbatim: "\(receipt.fileCount) · \(receipt.byteCount)")
                    .font(.caption)
                    .monospacedDigit()
                if receipt.retainedBackupName != nil {
                    Text("scene.assets.backupRetained").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("scene.assets.title")
        } footer: {
            Text("scene.assets.note")
        }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { start(url) }
            case .failure:
                statusKey = "scene.assets.error.invalidArchive"
            }
        }
        .onDisappear { importTask?.cancel() }
    }

    @MainActor private func start(_ url: URL) {
        guard !installing else { return }
        receipt = nil
        statusKey = nil
        installing = true
        importTask = Task { @MainActor in
            defer {
                installing = false
                importTask = nil
                onInstallationFinished()
            }
            do {
                let result = try await installer.install(from: url, willPublish: onWillInstall)
                receipt = result
                statusKey = "scene.assets.installed"
                onInstalled(result)
            } catch is CancellationError {
                statusKey = "scene.assets.cancelled"
            } catch let error as SceneSharedAssetsInstaller.InstallError {
                statusKey = error.localizationKey
            } catch {
                // Lifecycle callbacks may throw arbitrary errors. Do not display
                // paths, filenames, credentials or tool diagnostics from them.
                statusKey = "scene.assets.error.publication"
            }
        }
    }
}
