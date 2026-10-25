import SwiftUI

/// Explains an empty grid. The app never draws a fake tile or a dead import button:
/// only states with a real next action offer one.
struct WMEmptyStateView: View {
    @ObservedObject var model: WMAppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            title
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            message
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if showsImportButton {
                Button {
                    model.presentImporter()
                } label: {
                    Label("library.empty.import", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wm.import.empty")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var libraryEmpty: Bool {
        model.library.items.isEmpty
    }

    private var showsImportButton: Bool {
        guard !model.isSearching else { return false }
        if libraryEmpty { return true }
        if case .all = model.sidebarSelection { return true }
        return false
    }

    private var iconName: String {
        if model.isSearching { return "magnifyingglass" }
        if libraryEmpty { return "rectangle.stack.badge.plus" }
        switch model.sidebarSelection {
        case .favorites:
            return "heart"
        case .playlist:
            return "play.square.stack"
        case .collection:
            return "folder"
        case .all:
            return "rectangle.stack"
        }
    }

    private var title: Text {
        if model.isSearching {
            return Text("library.noResults.title")
        }
        if libraryEmpty {
            return Text("library.empty.title")
        }
        return Text("library.empty.scope.title")
    }

    private var message: Text {
        if model.isSearching {
            return Text(verbatim: WMLocalized.format("library.noResults.message", model.searchText))
        }
        if libraryEmpty {
            return Text("library.empty.message")
        }
        switch model.sidebarSelection {
        case .favorites:
            return Text("library.empty.favorites.message")
        case .playlist:
            return Text("library.empty.playlist.message")
        case .collection:
            return Text("library.empty.collection.message")
        case .all:
            return Text("library.empty.scope.message")
        }
    }
}

/// Detail-column placeholder for regular width.
struct WMNoSelectionView: View {
    @ObservedObject var model: WMAppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("preview.noSelection.title")
                .font(.title3.weight(.semibold))
            Text("preview.noSelection.message")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if model.library.items.isEmpty {
                Button {
                    model.presentImporter()
                } label: {
                    Label("library.empty.import", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
