import SwiftUI
import UIKit

/// Shared chrome for modal tools, so every sheet has a visible title and a close
/// control that does not depend on the embedded view's own navigation.
struct WMSheetContainer<Content: View>: View {
    let titleKey: LocalizedStringKey
    let onClose: () -> Void
    let content: Content

    init(
        titleKey: LocalizedStringKey,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.titleKey = titleKey
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(titleKey)
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("common.close"))
                .accessibilityIdentifier("wm.sheet.close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

// MARK: - Workshop

struct WMWorkshopSheet: View {
    @ObservedObject var model: WMAppModel

    var body: some View {
        WMSheetContainer(titleKey: "workshop.title", onClose: { model.isWorkshopPresented = false }) {
            WorkshopBrowserView(library: model.library, contentDownloads: model.workshopDownloads)
                .accessibilityIdentifier("wm.workshop")
        }
        .wmErrorAlert(model: model)
    }
}

// MARK: - Export

struct WMExportSheet: View {
    @ObservedObject var model: WMAppModel
    let target: WMExportTarget

    var body: some View {
        WMSheetContainer(titleKey: "export.title", onClose: { model.exportTarget = nil }) {
            WallpaperExportView(
                item: target.item,
                sourceURL: target.sourceURL,
                settings: model.library.settings
            )
            .accessibilityIdentifier("wm.export")
        }
        .wmErrorAlert(model: model)
    }
}

// MARK: - Playlist editor

struct WMPlaylistEditorView: View {
    @ObservedObject var model: WMAppModel

    var body: some View {
        WMSheetContainer(titleKey: "playlist.editor.title", onClose: { model.isPlaylistEditorPresented = false }) {
            if model.playlistItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "play.square.stack")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("playlist.empty.message")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("playlist.reorderHint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                    List {
                        ForEach(model.playlistItems) { item in
                            HStack(spacing: 10) {
                                Text(verbatim: item.title)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(item.kind.wmLocalizedKey)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onMove { source, destination in
                            model.movePlaylist(from: source, to: destination)
                        }
                        .onDelete { offsets in
                            model.deletePlaylistItems(at: offsets)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
        }
        .wmErrorAlert(model: model)
    }
}

// MARK: - New collection

struct WMNewCollectionSheet: View {
    @ObservedObject var model: WMAppModel

    @FocusState private var nameFocused: Bool

    var body: some View {
        WMSheetContainer(titleKey: "collection.new.title", onClose: { model.cancelNewCollection() }) {
            Form {
                Section {
                    TextField("collection.namePlaceholder", text: $model.newCollectionName)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            model.commitNewCollection()
                        }
                        .accessibilityIdentifier("wm.collection.name")
                } footer: {
                    if isDuplicate {
                        Text("collection.name.duplicate")
                            .foregroundStyle(.red)
                    } else {
                        Text("collection.new.footnote")
                    }
                }

                Section {
                    Button("collection.new.create") {
                        model.commitNewCollection()
                    }
                    .disabled(!model.canCreateCollection)
                    .accessibilityIdentifier("wm.collection.create")
                }
            }
            .onAppear {
                nameFocused = true
            }
        }
        .wmErrorAlert(model: model)
    }

    private var isDuplicate: Bool {
        let trimmed = model.newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !model.canCreateCollection
    }
}

// MARK: - Document export

/// Presents the system document picker for a backup file the library store already
/// wrote. The UI does not build the archive itself.
struct WMDocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}
