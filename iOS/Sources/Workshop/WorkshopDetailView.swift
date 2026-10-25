import SwiftUI
import UIKit

/// Real Workshop metadata, experimental authenticated native downloads, and a
/// desktop-download/import fallback. Community browser sign-in alone cannot
/// authorize native content access.
struct WorkshopDetailView: View {
    let item: WorkshopItem
    let store: WorkshopStore
    @ObservedObject private var library: LibraryStore
    let contentDownloads: WorkshopContentDownloadStore
    @State private var nativeSignIn = false
    @State private var guardCode = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showImporter = false
    @State private var showSteps = false
    @State private var showUpdateSteps = false
    @State private var showImportOutcome = false
    @State private var copied = false
    @State private var canOpenSteamApp = false

    @MainActor
    init(item: WorkshopItem, store: WorkshopStore, library: LibraryStore, contentDownloads: WorkshopContentDownloadStore) {
        self.item = item
        self.store = store
        self.contentDownloads = contentDownloads
        _library = ObservedObject(wrappedValue: library)
    }

    private var availability: WorkshopDownloadAvailability {
        // Reading library projects makes this recompute when the shared library changes.
        _ = library.items
        return store.availability(for: item)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkshopLargePreview(item: item, cache: store.thumbnails)

                    header
                    compatibility
                    nativeDownloadCard
                    statusCard
                    if !item.summary.isEmpty {
                        Text(verbatim: item.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !item.tags.isEmpty { tagSection }
                    detailsSection
                }
                .padding()
            }
            .navigationTitle(WS("Workshop item", "工作坊項目"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(WS("Done", "完成")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            openURL(WorkshopDesktopHandoff.steamPageURL(for: item))
                        } label: {
                            Label(WS("Open on Steam", "在 Steam 開啟"), systemImage: "safari")
                        }
                        if let steamURL = WorkshopDesktopHandoff.steamAppURL(for: item),
                           canOpenSteamApp {
                            Button {
                                UIApplication.shared.open(steamURL)
                            } label: {
                                Label(WS("Open in Steam app", "在 Steam App 開啟"),
                                      systemImage: "arrow.up.forward.app")
                            }
                        }
                        Button {
                            copyLink()
                        } label: {
                            Label(
                                copied ? WS("Link copied", "已複製連結")
                                    : WS("Copy link", "複製連結"),
                                systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Divider()
                        Button {
                            showImporter = true
                        } label: {
                            Label(WS("Import downloaded folder", "匯入已下載資料夾"),
                                  systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(WS("More actions", "更多動作"))
                }
            }
            .sheet(isPresented: $nativeSignIn) { WorkshopContentSignInView(store: contentDownloads) }
            .fileImporter(
                isPresented: $showImporter, allowedContentTypes: [.folder]
            ) { result in
                switch result {
                case .success(let url):
                    Task { @MainActor in
                        await store.importFolder(url, for: item)
                        showImportOutcome = true
                    }
                case .failure:
                    break
                }
            }
            .alert(
                WS("Import", "匯入"), isPresented: $showImportOutcome
            ) {
                Button(WS("OK", "確定"), role: .cancel) {}
            } message: {
                Text(store.lastImportOutcome?.message ?? "")
            }
            .onAppear {
                canOpenSteamApp = WorkshopDesktopHandoff.steamAppURL(for: item)
                    .map(UIApplication.shared.canOpenURL) ?? false
            }
            .accessibilityIdentifier("wm.workshop.detail")
        }
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: item.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let creatorID = item.creatorID, SteamWebSession.isSteamID(creatorID) {
                    Button {
                        store.openAuthor(of: item)
                        dismiss()
                    } label: {
                        Text(verbatim: item.creator)
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                } else {
                    Text(verbatim: item.creator)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("·").foregroundStyle(.tertiary)
                Text(item.kind.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(item.kind.compatibility, systemImage: kindSymbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if item.kind == .scene {
                Text(WS(
                    "Scene wallpapers need the scene engine and Wallpaper Engine’s own shared assets. This app does not redistribute those assets.",
                    "場景桌布需要場景引擎與 Wallpaper Engine 自己的共用素材。本 App 不會重新散布這些素材。"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var nativeDownloadCard: some View {
        card {
            Text(WS("Experimental native Steam download", "實驗性原生 Steam 下載")).font(.headline)
            Text(WS("Native Steam content sign-in is separate from Community browser sign-in. Wallpaper Engine ownership and Steam Guard are required; collections are not recursively downloaded.", "原生 Steam 內容登入與社群瀏覽器登入分開。需要擁有 Wallpaper Engine 並完成 Steam Guard 驗證；不會遞迴下載合集。"))
                .font(.callout).foregroundStyle(.secondary)
            if contentDownloads.isBusy {
                if contentDownloads.isImporting {
                    Text(WS("Verifying the project and importing into your library…", "正在驗證專案並匯入媒體庫…"))
                } else if let status = contentDownloads.status {
                    Text(WorkshopContentSignInView.phaseLabel(status.phase))
                    if status.phase == "guard" {
                        Text(WS("Steam is awaiting your Guard code or device confirmation.", "Steam 正等待 Guard 驗證碼或裝置確認。"))
                        TextField(WS("Guard code", "Guard 驗證碼"), text: $guardCode)
                        Button(WS("Submit Guard code", "提交 Guard 驗證碼")) {
                            _ = contentDownloads.submitGuard(guardCode); guardCode = ""
                        }
                    }
                    if status.total > 0 {
                        ProgressView(value: Double(status.received), total: Double(status.total))
                        Text("\(WorkshopFormat.bytes(Int64(status.received))) / \(WorkshopFormat.bytes(Int64(status.total)))")
                    } else { ProgressView() }
                } else { ProgressView() }
                if contentDownloads.canCancel {
                    Button(WS("Cancel download", "取消下載"), role: .cancel) { contentDownloads.cancel() }
                }
            } else if let error = contentDownloads.errorText {
                Text(error).foregroundStyle(.red)
                if contentDownloads.signedIn {
                    Button(WS("Try download again", "再次嘗試下載")) { Task { await contentDownloads.download(item) } }
                } else {
                    Button(WS("Sign in for downloads", "登入以下載")) { nativeSignIn = true }
                }
            } else if contentDownloads.signedIn {
                Button(store.isInstalled(item) ? WS("Download update", "下載更新") : WS("Download with Steam", "使用 Steam 下載")) {
                    Task { await contentDownloads.download(item) }
                }.buttonStyle(.borderedProminent).disabled(item.isCollection || item.isApplication)
            } else {
                Button(WS("Sign in for downloads", "登入以下載")) { nativeSignIn = true }
                    .buttonStyle(.borderedProminent).disabled(item.isCollection || item.isApplication)
            }
            if contentDownloads.signedIn {
                Button(WS("Sign out of native Steam", "登出原生 Steam"), role: .destructive) { contentDownloads.signOut() }
            }
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .scene: "cube.transparent"
        case .video: "play.rectangle"
        case .web: "globe"
        case .application: "pc"
        case .all: "questionmark.square"
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        switch availability {
        case .collection:
            card {
                Label(
                    WS("This is a collection.", "這是一個合集。"),
                    systemImage: "square.stack")
                    .font(.headline)
                Text(WS(
                    "A collection is a list of wallpapers, not a wallpaper itself. Open it to see what it holds.",
                    "合集是桌布的清單，不是桌布本身。開啟它以查看內容。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    store.openCollection(item)
                    dismiss()
                } label: {
                    Label(WS("Open collection", "開啟合集"),
                          systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .unsupportedApplication:
            card {
                Label(
                    WS("Unsupported on iPad", "iPad 不支援"),
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(WS(
                    "Application wallpapers run Windows programs. iPadOS cannot run them, and this app will not claim otherwise.",
                    "應用程式桌布會執行 Windows 程式。iPadOS 無法執行，本 App 也不會聲稱可以。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                openOnSteamButton()
            }
        case .installed(let update):
            card {
                Label(
                    WS("In your library", "已在媒體庫"),
                    systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if let update {
                    Label(
                        String(
                            format: WS("A newer version was published %@.", "作者已於 %@ 發佈較新版本。"),
                            update.timeUpdated.map(WorkshopFormat.date) ?? ""),
                        systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text("workshop.fallback.update")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    disclosureSteps(
                        title: WMLocalized.string("workshop.fallback.updateSteps"),
                        steps: WorkshopDesktopHandoff.updateSteps(for: item),
                        isExpanded: $showUpdateSteps)
                    Button {
                        showImporter = true
                    } label: {
                        Label(WS("Import updated folder", "匯入更新資料夾"),
                              systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Text("workshop.fallback.installed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                openOnSteamButton()
            }
        case .desktopDownloadRequired:
            card {
                Label(
                    WMLocalized.string("workshop.fallback.title"),
                    systemImage: "desktopcomputer")
                    .font(.headline)
                Text("workshop.fallback.message")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        showImporter = true
                    } label: {
                        Label(WS("Import downloaded folder", "匯入已下載資料夾"),
                              systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    openOnSteamButton()
                }
                disclosureSteps(
                    title: WMLocalized.string("workshop.fallback.importSteps"),
                    steps: WorkshopDesktopHandoff.steps(for: item),
                    isExpanded: $showSteps)
                Button {
                    copyLink()
                } label: {
                    Label(
                        copied ? WS("Link copied", "已複製連結") : WS("Copy link", "複製連結"),
                        systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground)))
    }

    private func openOnSteamButton() -> some View {
        Button {
            openURL(WorkshopDesktopHandoff.steamPageURL(for: item))
        } label: {
            Label(WS("Open on Steam", "在 Steam 開啟"), systemImage: "safari")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("wm.workshop.openSteam")
    }

    private func disclosureSteps(
        title: String, steps: [String], isExpanded: Binding<Bool>
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(step)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label(title, systemImage: "questionmark.circle")
                .font(.callout.weight(.medium))
        }
        .accessibilityIdentifier("wm.workshop.importSteps")
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(WS("Tags", "標籤"))
                .font(.headline)
            WorkshopTagFlow {
                ForEach(item.tags, id: \.self) { tag in
                    Text(verbatim: tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                }
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(WS("Details", "詳細資料"))
                .font(.headline)
            detailRow(WS("Workshop id", "工作坊 ID"), item.id)
            if item.isCollection, let count = item.collectionSize, count > 0 {
                detailRow(WS("Wallpapers", "桌布"), WorkshopFormat.number(count))
            }
            if item.size > 0 {
                detailRow(WS("Size", "大小"), WorkshopFormat.bytes(item.size))
            }
            detailRow(
                WS("Subscribers", "訂閱數"),
                WorkshopFormat.number(item.subscriptions))
            if let updated = item.timeUpdated {
                detailRow(WS("Updated", "更新"), WorkshopFormat.date(updated))
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }

    private func copyLink() {
        UIPasteboard.general.string = item.pageURL.absoluteString
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}
