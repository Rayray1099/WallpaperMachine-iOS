import SwiftUI

/// Three-column layout's first column: every library scope plus modal tools.
struct WMSidebarView: View {
    @ObservedObject var model: WMAppModel

    private var selection: Binding<WMSidebarSelection?> {
        Binding(
            get: { model.sidebarSelection },
            set: { newValue in
                if let newValue {
                    model.selectScope(newValue)
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                row("library.all", systemImage: "rectangle.stack", value: .all, identifier: "wm.library")
                row("library.favorites", systemImage: "heart", value: .favorites, identifier: "wm.favorites")
            } header: {
                Text("library.section.library")
            }

            Section {
                if model.sortedCollections.isEmpty {
                    Text("collections.empty")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sortedCollections, id: \.self) { name in
                        Label {
                            Text(verbatim: name)
                        } icon: {
                            Image(systemName: "folder")
                        }
                        .tag(WMSidebarSelection.collection(name))
                        .accessibilityIdentifier("wm.collection.\(name)")
                        .contextMenu {
                            Button(role: .destructive) {
                                model.requestDeleteCollection(name)
                            } label: {
                                Label("collection.delete", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("collections.title")
                        .accessibilityIdentifier("wm.collections")
                    Spacer(minLength: 0)
                    Button {
                        model.beginCreatingCollection()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("collection.new"))
                    .accessibilityIdentifier("wm.collections.add")
                }
            }

            Section {
                row("playlist.open", systemImage: "play.square.stack", value: .playlist, identifier: "wm.playlists")
            } header: {
                Text("playlist.title")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(Text("app.title"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomTools
        }
    }

    private var bottomTools: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                model.isWorkshopPresented = true
            } label: {
                Label("workshop.title", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("wm.workshop")

            Button {
                model.isPixivPresented = true
            } label: {
                Label("pixiv.title", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("wm.pixiv")

            Button {
                model.isSettingsPresented = true
            } label: {
                Label("settings.title", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("wm.settings")

            Text(verbatim: WMLocalized.format("library.itemCount", model.library.items.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
        .background(.bar)
    }

    private func row(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        value: WMSidebarSelection,
        identifier: String
    ) -> some View {
        Label(titleKey, systemImage: systemImage)
            .tag(value)
            .accessibilityIdentifier(identifier)
    }
}
