import SwiftUI
import UIKit

/// The installed Workshop wallpapers Steam says have a newer version. iOS cannot install an
/// update itself; each row opens Steam's page and explains the import path. This is real
/// update detection, not a fake update button.
struct WorkshopUpdatesView: View {
    let store: WorkshopStore
    @ObservedObject private var library: LibraryStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var expanded: Set<String> = []
    @State private var copiedID: String?

    @MainActor
    init(store: WorkshopStore, library: LibraryStore) {
        self.store = store
        _library = ObservedObject(wrappedValue: library)
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.updates.available.isEmpty {
                    ContentUnavailableView {
                        Label(WS("No updates found", "沒有找到更新"),
                              systemImage: "checkmark.circle")
                    } description: {
                        Text(WS(
                            "Steam’s public details endpoint reports no newer version for the Workshop wallpapers in your library.",
                            "Steam 的公開詳細資料端點表示，媒體庫中的工作坊桌布沒有較新版本。"))
                    } actions: {
                        Button(WS("Check again", "再次檢查")) {
                            store.checkForUpdates()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(updates) { item in
                            Section {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(verbatim: item.title)
                                        .font(.headline)
                                    if let updated = item.timeUpdated {
                                        Text(String(
                                            format: WS("Published %@", "發佈於 %@"),
                                            WorkshopFormat.date(updated)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(WS(
                                        "Download the item again in Steam on a computer, then import the new folder. The app does not fetch Workshop content by itself.",
                                        "請在電腦的 Steam 重新下載此項目，然後匯入新資料夾。本 App 不會自行取得工作坊內容。"))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    HStack(spacing: 10) {
                                        Button {
                                            openURL(item.pageURL)
                                        } label: {
                                            Label(WS("Open on Steam", "在 Steam 開啟"),
                                                  systemImage: "safari")
                                        }
                                        .buttonStyle(.bordered)
                                        Button {
                                            UIPasteboard.general.string =
                                                WorkshopDesktopHandoff.links(for: [item])
                                            copiedID = item.id
                                            Task { @MainActor in
                                                try? await Task.sleep(
                                                    nanoseconds: 2_000_000_000)
                                                if copiedID == item.id { copiedID = nil }
                                            }
                                        } label: {
                                            Label(
                                                copiedID == item.id
                                                    ? WS("Copied", "已複製")
                                                    : WS("Copy link", "複製連結"),
                                                systemImage: copiedID == item.id
                                                    ? "checkmark" : "doc.on.doc")
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    DisclosureGroup(
                                        isExpanded: Binding(
                                            get: { expanded.contains(item.id) },
                                            set: { isOpen in
                                                if isOpen { expanded.insert(item.id) }
                                                else { expanded.remove(item.id) }
                                            })
                                    ) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(
                                                Array(
                                                    WorkshopDesktopHandoff
                                                        .updateSteps(for: item).enumerated()
                                                ),
                                                id: \.offset
                                            ) { index, step in
                                                HStack(alignment: .top, spacing: 8) {
                                                    Text("\(index + 1).")
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(.secondary)
                                                        .frame(width: 18, alignment: .trailing)
                                                    Text(step)
                                                        .font(.callout)
                                                        .fixedSize(
                                                            horizontal: false, vertical: true)
                                                }
                                            }
                                        }
                                        .padding(.top, 6)
                                    } label: {
                                        Label(WS("How to update it", "如何更新"),
                                              systemImage: "questionmark.circle")
                                            .font(.callout)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(WS("Workshop updates", "工作坊更新"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(WS("Done", "完成")) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if store.updates.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(WS("Check now", "立即檢查")) {
                            store.checkForUpdates()
                        }
                        .disabled(store.installedWorkshopIDs.isEmpty)
                    }
                }
            }
            .accessibilityIdentifier("wm.workshop.updates")
        }
        .presentationDetents([.medium, .large])
    }

    private var updates: [WorkshopItem] {
        _ = library.items
        return store.updates.available.values.sorted {
            ($0.timeUpdated ?? .distantPast) > ($1.timeUpdated ?? .distantPast)
        }
    }
}
