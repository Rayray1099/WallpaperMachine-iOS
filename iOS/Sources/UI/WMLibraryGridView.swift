import SwiftUI
import UIKit

/// Context-menu actions shared by the regular grid and the compact stack.
struct WMItemContextMenu: View {
    @ObservedObject var model: WMAppModel
    let item: WallpaperItem

    var body: some View {
        Button {
            model.toggleFavorite(item)
        } label: {
            Label(favoriteKey, systemImage: item.isFavorite ? "heart.slash" : "heart")
        }

        Button {
            model.togglePlaylistMembership(item)
        } label: {
            Label(playlistKey, systemImage: model.isInPlaylist(item) ? "minus.circle" : "plus.circle")
        }

        Divider()

        Button {
            model.beginExport(item)
        } label: {
            Label("preview.export", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            model.requestRemoval(item)
        } label: {
            Label("library.remove", systemImage: "trash")
        }
    }

    private var favoriteKey: LocalizedStringKey {
        item.isFavorite ? "context.unfavorite" : "context.favorite"
    }

    private var playlistKey: LocalizedStringKey {
        model.isInPlaylist(item) ? "playlist.remove" : "playlist.add"
    }
}

/// Regular-width content column: a searchable, lazy wallpaper grid.
struct WMLibraryGridView: View {
    @ObservedObject var model: WMAppModel

    @FocusState private var searchFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16, alignment: .top)
    ]

    var body: some View {
        Group {
            if model.filteredItems.isEmpty {
                WMEmptyStateView(model: model)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.filteredItems) { item in
                            Button {
                                model.selectItem(item)
                            } label: {
                                WMItemCard(
                                    item: item,
                                    previewURL: model.library.previewURL(for: item),
                                    isSelected: model.selectedItemID == item.id
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("wm.item.\(item.id.uuidString)")
                            .contextMenu {
                                WMItemContextMenu(model: model, item: item)
                            }
                        }
                    }
                    .padding(16)
                }
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .overlay {
            if model.library.isImporting {
                WMImportingOverlay()
            }
        }
        .navigationTitle(title)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.presentImporter()
                } label: {
                    Label("library.import", systemImage: "plus")
                }
                .accessibilityIdentifier("wm.import")
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
