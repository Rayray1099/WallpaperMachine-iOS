// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation
import SwiftUI
import UIKit

/// Capability lives only for this app process, not in preferences, backups, logs or clipboard reads.
@MainActor
final class PCConverterConnectionStore: ObservableObject {
    static let shared = PCConverterConnectionStore()
    @Published private(set) var connection: PCConverterConnection?

    func pair(link: String) throws { connection = try PCConverterConnection(link: link) }
    func disconnect() { connection = nil }
}

@MainActor
private final class PCConverterModel: ObservableObject {
    @Published private(set) var progress: PCConverterClient.Progress?
    @Published private(set) var receipt: PCConverterClient.Receipt?
    @Published private(set) var messageKey: String?
    @Published private(set) var isRunning = false
    private var operation: Task<Void, Never>?
    private var operationID: UUID?

    func showConnectionError() { messageKey = "export.pc.error.connection" }
    func clearMessage() { messageKey = nil }

    func start(item: WallpaperItem, sourceURL: URL, connection: PCConverterConnection) {
        guard !isRunning, item.kind == .video else { return }
        let id = UUID()
        operationID = id
        messageKey = nil; receipt = nil; isRunning = true
        progress = PCConverterClient.Progress(phase: .preparing)
        let client = PCConverterClient(connection: connection)
        operation = Task {
            do {
                let result = try await client.convert(sourceURL: sourceURL, entryFile: item.entryFile, title: item.title) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.operationID == id else { return }
                        self.progress = value
                    }
                }
                receipt = result
            } catch {
                messageKey = Task.isCancelled || error is CancellationError
                    ? "export.pc.cancelled"
                    : "export.pc.error." + ((error as? PCConverterError) ?? .transport).rawValue
            }
            progress = nil; isRunning = false; operation = nil; operationID = nil
        }
    }

    func cancel() { operation?.cancel() }
}

@MainActor
struct PCConverterView: View {
    let item: WallpaperItem
    let sourceURL: URL
    @ObservedObject private var connections = PCConverterConnectionStore.shared
    @StateObject private var model = PCConverterModel()
    @State private var pastedLink = ""
    @State private var sharing = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private func text(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: item.title).font(.headline)
                    Text(text("export.pc.remoteNote")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(text("export.pc.connection")) {
                    if let connection = connections.connection {
                        Text(verbatim: connection.displayAddress).font(.callout.monospaced())
                        Button(text("export.pc.disconnect")) { connections.disconnect(); model.clearMessage() }
                            .disabled(model.isRunning)
                    } else {
                        SecureField(text("export.pc.link"), text: $pastedLink)
                            .textContentType(.none)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .accessibilityIdentifier("wm.export.pc.link")
                        Button(text("export.pc.pair"), action: pair)
                            .disabled(pastedLink.isEmpty)
                            .accessibilityIdentifier("wm.export.pc.pair")
                    }
                    Text(text("export.pc.memoryOnly")).font(.footnote).foregroundStyle(.secondary)
                }
                if item.kind == .video {
                    Section {
                        Text(text("export.pc.settings"))
                        Button(text("export.pc.start")) {
                            guard let connection = connections.connection else { return }
                            model.start(item: item, sourceURL: sourceURL, connection: connection)
                        }
                        .disabled(connections.connection == nil || model.isRunning)
                        .accessibilityIdentifier("wm.export.pc.start")
                    }
                } else {
                    Text(text("export.pc.unsupported")).foregroundStyle(.secondary)
                }
                if let progress = model.progress {
                    Section {
                        Text(text("export.pc." + progress.phase.rawValue))
                        if let fraction = progress.fraction { ProgressView(value: fraction) }
                        else { ProgressView() }
                        if progress.total > 0 {
                            Text(verbatim: "\(progress.completed) / \(progress.total)").font(.caption.monospacedDigit())
                        }
                        Button(text("export.pc.cancel"), role: .cancel) { model.cancel() }
                            .accessibilityIdentifier("wm.export.pc.cancel")
                    }
                }
                if let receipt = model.receipt {
                    Section {
                        Text(text("export.pc.finished")).font(.footnote)
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: receipt.byteSize, countStyle: .file))
                        Label(text("export.pc.receipt"), systemImage: "checkmark.shield")
                        Text(verbatim: receipt.sha256).font(.caption2.monospaced()).textSelection(.enabled)
                        Button(text("export.pc.share")) { sharing = true }
                            .accessibilityIdentifier("wm.export.pc.share")
                    }
                }
                if let key = model.messageKey {
                    Text(text(key)).foregroundStyle(key == "export.pc.cancelled" ? Color.secondary : Color.red)
                }
            }
            .navigationTitle(text("export.pc.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(text("export.pc.done")) { dismiss() }.disabled(model.isRunning)
                }
            }
            .onDisappear { pastedLink = ""; model.cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.cancel() }
            }
            .interactiveDismissDisabled(model.isRunning)
            .sheet(isPresented: $sharing) {
                if let receipt = model.receipt { PCConverterShareSheet(url: receipt.outputURL) }
            }
        }
        .accessibilityIdentifier("wm.export.pc")
    }

    private func pair() {
        do { try connections.pair(link: pastedLink); pastedLink = ""; model.clearMessage() }
        catch { model.showConnectionError() }
    }
}

private struct PCConverterShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
