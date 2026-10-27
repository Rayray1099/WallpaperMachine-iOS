import SwiftUI
import UIKit

/// Adaptive shell: three-column split on iPad, a navigation stack when the
/// horizontal size class is compact (iPhone, Slide Over, narrow Split View).
struct WMRootView: View {
    @ObservedObject var model: WMAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                WMCompactLibraryView(model: model)
            } else {
                WMRegularLibraryView(model: model)
            }
        }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: WMImportContentTypes.allowed,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                model.importURLs(urls)
            case .failure(let error):
                model.presentError(error.localizedDescription)
            }
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            WMSettingsView(model: model)
        }
        .sheet(isPresented: $model.isWorkshopPresented) {
            WMWorkshopSheet(model: model)
        }
        .sheet(isPresented: $model.isPixivPresented) {
            WMPixivSheet(model: model)
        }
        .sheet(item: $model.exportTarget) { target in
            WMExportSheet(model: model, target: target)
        }
        .sheet(isPresented: $model.isPlaylistEditorPresented) {
            WMPlaylistEditorView(model: model)
        }
        .sheet(isPresented: $model.isCreatingCollection) {
            WMNewCollectionSheet(model: model)
        }
        .fullScreenCover(isPresented: $model.isFullscreenPresented) {
            WMFullscreenPreview(model: model)
        }
        .onChange(of: model.library.errorMessage) { _, newValue in
            guard let newValue else { return }
            model.errorMessage = newValue
            model.library.errorMessage = nil
        }
        .wmErrorAlert(model: model)
        .confirmationDialog(
            "inspector.remove.confirm.title",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { presented in
                    if !presented { model.pendingDeletion = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: model.pendingDeletion
        ) { item in
            Button("common.delete", role: .destructive) {
                model.remove(item)
            }
            Button("common.cancel", role: .cancel) {
                model.pendingDeletion = nil
            }
        } message: { item in
            Text(verbatim: WMLocalized.format("inspector.remove.confirm.message", item.title))
        }
        .confirmationDialog(
            "collection.delete.confirm.title",
            isPresented: Binding(
                get: { model.pendingCollectionDeletion != nil },
                set: { presented in
                    if !presented { model.pendingCollectionDeletion = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: model.pendingCollectionDeletion
        ) { name in
            Button("common.delete", role: .destructive) {
                model.deleteCollection(name)
            }
            Button("common.cancel", role: .cancel) {
                model.pendingCollectionDeletion = nil
            }
        } message: { name in
            Text(verbatim: WMLocalized.format("collection.delete.confirm.message", name))
        }
    }
}

/// Regular width: sidebar / searchable grid / preview and inspector.
struct WMRegularLibraryView: View {
    @ObservedObject var model: WMAppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WMSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } content: {
            WMLibraryGridView(model: model)
                .navigationSplitViewColumnWidth(min: 340, ideal: 560)
        } detail: {
            if let item = model.selectedItem {
                WMItemDetailView(model: model, item: item)
                    .id(item.id)
            } else {
                WMNoSelectionView(model: model)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// Compact width: one stack, scope menu in place of the sidebar.
struct WMCompactLibraryView: View {
    @ObservedObject var model: WMAppModel

    @FocusState private var searchFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12, alignment: .top)
    ]

    var body: some View {
        NavigationStack(path: $model.compactNavigationPath) {
            content
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        scopeMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.presentImporter()
                        } label: {
                            Label("library.import", systemImage: "plus")
                        }
                        .accessibilityIdentifier("wm.import")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.isSettingsPresented = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel(Text("settings.title"))
                        .accessibilityIdentifier("wm.settings")
                    }
                }
                .navigationDestination(for: UUID.self) { id in
                    if let item = model.item(withID: id) {
                        WMItemDetailView(model: model, item: item)
                            .id(item.id)
                    } else {
                        Text("preview.unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }

    private var content: some View {
        Group {
            if model.filteredItems.isEmpty {
                WMEmptyStateView(model: model)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.filteredItems) { item in
                            NavigationLink(value: item.id) {
                                WMItemCard(
                                    item: item,
                                    previewURL: model.library.previewURL(for: item),
                                    isSelected: false
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("wm.item.\(item.id.uuidString)")
                            .contextMenu {
                                WMItemContextMenu(model: model, item: item)
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .overlay {
            if model.library.isImporting {
                WMImportingOverlay()
            }
        }
        .searchable(
            text: $model.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("library.searchPrompt")
        )
        .searchFocused($searchFocused)
        .accessibilityIdentifier("wm.search")
        .onChange(of: model.searchFocusRequest) { _, _ in
            searchFocused = true
        }
    }

    private var scopeMenu: some View {
        Menu {
            Button {
                model.selectScope(.all)
            } label: {
                scopeLabel(Text("library.all"), selected: model.sidebarSelection == .all)
            }
            Button {
                model.selectScope(.favorites)
            } label: {
                scopeLabel(Text("library.favorites"), selected: model.sidebarSelection == .favorites)
            }

            if !model.sortedCollections.isEmpty {
                Divider()
                ForEach(model.sortedCollections, id: \.self) { name in
                    Button {
                        model.selectScope(.collection(name))
                    } label: {
                        scopeLabel(
                            Text(verbatim: name),
                            selected: model.sidebarSelection == .collection(name)
                        )
                    }
                }
            }

            Divider()

            Button {
                model.selectScope(.playlist)
            } label: {
                scopeLabel(Text("playlist.open"), selected: model.sidebarSelection == .playlist)
            }

            Divider()

            Button {
                model.isWorkshopPresented = true
            } label: {
                Label("workshop.title", systemImage: "square.grid.2x2")
            }
            .accessibilityIdentifier("wm.workshop")

            Button {
                model.isPixivPresented = true
            } label: {
                Label("pixiv.title", systemImage: "photo.on.rectangle.angled")
            }
            .accessibilityIdentifier("wm.pixiv")

            Button {
                model.beginCreatingCollection()
            } label: {
                Label("collection.new", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("library.browse", systemImage: "line.3.horizontal")
        }
        .accessibilityIdentifier("wm.library")
    }

    private func scopeLabel(_ title: Text, selected: Bool) -> some View {
        HStack {
            title
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private var title: Text {
        switch model.sidebarSelection {
        case .all:
            return Text("library.all")
        case .favorites:
            return Text("library.favorites")
        case .collection(let name):
            return Text(verbatim: name)
        case .playlist:
            return Text("playlist.title")
        }
    }
}
