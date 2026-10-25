import SwiftUI
import UIKit

/// The Workshop tab. It is the iOS counterpart of Discover: real Steam browse, search,
/// filters, collections, authors, subscriptions, cached previews and update checks. The
/// receives the app-owned content download store separately from web sign-in.
///
/// Public browsing and native account-authorized content transfer are separate.
/// The experimental downloader enforces Steam ownership and server access; author
/// previews remain distinct from a real imported wallpaper's native playback.
struct WorkshopBrowserView: View {
    @ObservedObject private var library: LibraryStore
    let contentDownloads: WorkshopContentDownloadStore
    @State private var showNativeSignIn = false
    @State private var store: WorkshopStore
    @State private var activeSheet: WorkshopSheet?
    @State private var showingImporter = false
    @State private var showingImportOutcome = false
    @State private var showingSignOut = false
    @State private var pageText = "1"

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL

    @MainActor
    init(library: LibraryStore, contentDownloads: WorkshopContentDownloadStore) {
        _library = ObservedObject(wrappedValue: library)
        _store = State(initialValue: WorkshopStore(library: library))
        self.contentDownloads = contentDownloads
    }

    var body: some View {
        HStack(spacing: 0) {
            if sizeClass == .regular {
                WorkshopFilterPanel(store: store, mode: .sidebar)
                    .frame(width: 286)
                Divider()
            }
            VStack(spacing: 0) {
                header
                Divider()
                content
                if !store.items.isEmpty { footer }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(WS("Workshop", "工作坊"))
        .toolbar { toolbar }
        .task { await store.start() }
        .onChange(of: store.page) { _, newValue in
            pageText = String(newValue)
        }
        .sheet(isPresented: $showNativeSignIn) { WorkshopContentSignInView(store: contentDownloads) }
        .sheet(item: $activeSheet, onDismiss: {
            store.cancelSteamSignIn()
        }) { sheet in
            switch sheet {
            case .filters:
                NavigationStack {
                    WorkshopFilterPanel(store: store, mode: .sheet)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(WS("Done", "完成")) { activeSheet = nil }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            case .signIn:
                WorkshopSteamSignInView { session in
                    store.completeSteamSignIn(session)
                }
            case .updates:
                WorkshopUpdatesView(store: store, library: library)
            case .detail(let item):
                WorkshopDetailView(item: item, store: store, library: library, contentDownloads: contentDownloads)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task { @MainActor in
                await store.importFolder(url, for: nil)
                showingImportOutcome = true
            }
        }
        .alert(WS("Import", "匯入"), isPresented: $showingImportOutcome) {
            Button(WS("OK", "確定"), role: .cancel) {}
        } message: {
            Text(store.lastImportOutcome?.message ?? "")
        }
        .confirmationDialog(
            WS("Sign out of Steam?", "登出 Steam？"),
            isPresented: $showingSignOut, titleVisibility: .visible
        ) {
            Button(WS("Sign out", "登出"), role: .destructive) {
                store.signOutOfSteam()
            }
            Button(WS("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(WS(
                "Your subscriptions list will need a new sign-in. Browsing and imports keep working.",
                "你的訂閱清單將需要重新登入。瀏覽與匯入仍可繼續使用。"))
        }
        .accessibilityIdentifier("wm.workshop")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if store.canGoBack {
                    Button {
                        store.goBack()
                    } label: {
                        Label(WS("Back", "返回"), systemImage: "chevron.backward")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(WS("Back", "返回"))
                }
                Text(verbatim: store.heading)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if store.updates.available.count > 0 {
                    Button {
                        activeSheet = .updates
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                            Text("\(store.updates.available.count)")
                                .font(.caption.weight(.bold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(String(
                        format: WS("%d Workshop updates", "%d 個工作坊更新"),
                        store.updates.available.count))
                    .accessibilityIdentifier("wm.workshop.updates")
                }
                if store.source.isSearchable { sortMenu }
                if sizeClass != .regular {
                    Button {
                        activeSheet = .filters
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(WS("Filters", "篩選"))
                    .accessibilityIdentifier("wm.workshop.filters")
                    .overlay(alignment: .topTrailing) {
                        if store.filterCount > 0 {
                            Text("\(store.filterCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.tint, in: Circle())
                                .offset(x: 5, y: -5)
                        }
                    }
                }
            }

            listTabs
            if store.source.isSearchable { searchBar }
            summaryLine
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var listTabs: some View {
        HStack(spacing: 6) {
            ForEach(WorkshopList.allCases) { list in
                let active = store.source.list == list
                Button {
                    store.open(list)
                } label: {
                    Label(list.title, systemImage: list.systemImage)
                        .font(.subheadline.weight(active ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(active ? Color.accentColor : .secondary)
                        .background(
                            Capsule().fill(
                                active ? Color.accentColor.opacity(0.14) : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityIdentifier("wm.workshop.list.\(list.rawValue)")
            }
            Spacer(minLength: 0)
            Button {
                if contentDownloads.signedIn { contentDownloads.signOut() }
                else { showNativeSignIn = true }
            } label: {
                Label(contentDownloads.signedIn ? WS("Native download session", "原生下載工作階段") : WS("Sign in for downloads", "登入以下載"), systemImage: "arrow.down.circle").font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("wm.workshop.content-signin")
            if store.subscriptionAccountLabel != nil {
                Button {
                    showingSignOut = true
                } label: {
                    Label(
                        store.subscriptionAccountLabel ?? "",
                        systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(WS("Signed in to Steam. Sign out.", "已登入 Steam。登出。"))
            } else {
                Button {
                    store.beginSteamSignIn()
                    activeSheet = .signIn
                } label: {
                    Label(WS("Sign in to Steam", "登入 Steam"), systemImage: "person.crop.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("wm.workshop.signin")
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                WS("Search Steam’s Workshop", "搜尋 Steam 工作坊"),
                text: Binding(
                    get: { store.searchText },
                    set: { store.editSearch($0) })
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit { store.commitSearch() }
            .accessibilityIdentifier("wm.workshop.search")
            if !store.searchText.isEmpty {
                Button {
                    store.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(WS("Clear search", "清除搜尋"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground)))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(WorkshopSort.allCases) { option in
                Button {
                    store.setSort(option)
                } label: {
                    if option == store.sort {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Label(store.sort.title, systemImage: "arrow.up.arrow.down")
                .font(.subheadline)
                .labelStyle(.titleAndIcon)
        }
        .accessibilityIdentifier("wm.workshop.sort")
    }

    private var summaryLine: some View {
        HStack(spacing: 6) {
            if store.isLoading && store.hasLoaded {
                ProgressView().controlSize(.mini)
            }
            Text(verbatim: summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if store.isDegraded {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            if store.isSignedInToSteam, store.source.list == .subscriptions,
               store.itemsMissingFromLibrary.isEmpty == false {
                Button {
                    UIPasteboard.general.string = WorkshopDesktopHandoff.links(
                        for: store.itemsMissingFromLibrary)
                } label: {
                    Label(
                        WS("Copy missing links", "複製缺少的連結"),
                        systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryText: String {
        if store.isLoading && store.hasLoaded { return WS("Updating…", "更新中…") }
        if store.isLookup { return WS("Workshop item", "工作坊項目") }
        if store.isDegraded {
            return WS(
                "Steam changed its page; showing the item links it still carries",
                "Steam 變更了頁面；顯示頁面仍帶有的項目連結")
        }
        if store.source.list == .subscriptions, store.isSignedInToSteam {
            return WorkshopFormat.subscribedCount(store.totalCount)
        }
        guard store.hasLoaded else { return WS("Workshop", "工作坊") }
        if store.reachableCount > 0, store.reachableCount < store.totalCount {
            return String(
                format: WS("%@ results · first %@ browsable", "%@ 個結果 · 可瀏覽前 %@ 個"),
                WorkshopFormat.number(store.totalCount),
                WorkshopFormat.number(store.reachableCount))
        }
        return WorkshopFormat.resultCount(store.totalCount)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.isLoading && !store.hasLoaded {
            loadingState
        } else if let error = store.errorMessage, store.items.isEmpty {
            errorState(error)
        } else if store.items.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(WS("Searching Steam’s Workshop…", "正在搜尋 Steam 工作坊…"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label(WS("Couldn’t load the Workshop", "無法載入工作坊"), systemImage: "wifi.exclamationmark")
        } description: {
            Text(verbatim: message)
        } actions: {
            Button(WS("Try again", "再試一次")) { store.retry() }
                .buttonStyle(.borderedProminent)
            Button(WS("Open on Steam", "在 Steam 開啟")) {
                openURL(store.browseURL)
            }
            .buttonStyle(.bordered)
            if store.source.list == .subscriptions, !store.isSignedInToSteam {
                Button(WS("Sign in to Steam", "登入 Steam")) {
                    store.beginSteamSignIn()
                    activeSheet = .signIn
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.source.list == .subscriptions, !store.isSignedInToSteam {
            ContentUnavailableView {
                Label(WS("Sign in to see your subscriptions", "登入以查看你的訂閱"),
                      systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text(WS(
                    "Steam shows an account’s subscriptions only to that account. Sign in on Steam’s own page; this app keeps only the session cookies.",
                    "Steam 只向帳號本人顯示訂閱。請在 Steam 自己的頁面登入；本 App 只保留工作階段 Cookie。"))
            } actions: {
                Button(WS("Sign in to Steam", "登入 Steam")) {
                    store.beginSteamSignIn()
                    activeSheet = .signIn
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wm.workshop.signin")
                Button(WS("Browse the Workshop", "瀏覽工作坊")) {
                    store.open(.browse)
                }
            }
        } else {
            ContentUnavailableView {
                Label(WS("No wallpapers to show", "沒有可顯示的桌布"),
                      systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(emptyDescription)
            } actions: {
                if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(WS("Clear search", "清除搜尋")) { store.clearSearch() }
                        .buttonStyle(.bordered)
                }
                if store.filterCount > 0 {
                    Button(WS("Clear filters", "清除篩選")) { store.clearFilters() }
                        .buttonStyle(.bordered)
                }
                if store.source.list == .collections, store.page < store.totalPages {
                    Button(WS("Try the next page", "試下一頁")) {
                        store.loadPage(store.page + 1)
                    }
                    .buttonStyle(.bordered)
                }
                Button(WS("Refresh", "重新整理")) { store.refresh() }
                    .buttonStyle(.borderedProminent)
                if store.source.list == .subscriptions, store.isSignedInToSteam {
                    Button(WS("Browse the Workshop", "瀏覽工作坊")) { store.open(.browse) }
                }
            }
        }
    }

    private var emptyDescription: String {
        if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return WS(
                "No items matched this search and these filters. Steam’s index may also be catching up.",
                "沒有項目符合此搜尋與篩選。Steam 的索引也可能仍在更新。")
        }
        if store.filterCount > 0 {
            return WS(
                "Every item on this page was hidden by the filters. Clear one, or try another page.",
                "此頁的項目都被篩選條件隱藏。請清除一項條件，或試其他頁面。")
        }
        if store.source.list == .subscriptions {
            return WS(
                "This Steam account has no Wallpaper Engine Workshop subscriptions.",
                "此 Steam 帳號沒有 Wallpaper Engine 工作坊訂閱。")
        }
        return WS(
            "Steam returned no items for this page. Refresh, or open the same list on Steam.",
            "Steam 沒有為此頁傳回項目。請重新整理，或在 Steam 開啟相同清單。")
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230, maximum: 330), spacing: 16)],
                spacing: 16
            ) {
                ForEach(store.items) { item in
                    WorkshopTile(
                        item: item,
                        store: store,
                        library: library,
                        onSelect: { activeSheet = .detail(item) },
                        onOpenCollection: {
                            store.openCollection(item)
                        },
                        onOpenAuthor: {
                            store.openAuthor(of: item)
                        })
                }
            }
            .padding(16)
        }
        .overlay(alignment: .top) {
            if let error = store.errorMessage, !store.items.isEmpty {
                Text(verbatim: error)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(verbatim: pageSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if store.totalPages > 1 {
                Button {
                    store.loadPage(store.page - 1)
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .buttonStyle(.bordered)
                .disabled(store.page <= 1 || store.isLoading)
                .accessibilityLabel(WS("Previous page", "上一頁"))

                TextField(WS("Page", "頁"), text: $pageText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 54)
                    .onSubmit { goToTypedPage() }
                    .accessibilityLabel(WS("Page number", "頁碼"))

                Button(WS("Go", "前往")) { goToTypedPage() }
                    .buttonStyle(.bordered)
                    .disabled(store.isLoading)

                Text(verbatim: String(
                    format: WS("of %@", "/ %@"),
                    WorkshopFormat.number(store.totalPages)))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    store.loadPage(store.page + 1)
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .buttonStyle(.bordered)
                .disabled(store.page >= store.totalPages || store.isLoading)
                .accessibilityLabel(WS("Next page", "下一頁"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var pageSummary: String {
        if store.totalPages > 1 {
            return String(
                format: WS("Page %@ of %@", "第 %@ 頁，共 %@ 頁"),
                WorkshopFormat.number(store.page), WorkshopFormat.number(store.totalPages))
        }
        return WorkshopFormat.resultCount(store.totalCount)
    }

    private func goToTypedPage() {
        let target = store.clampedPage(typed: pageText)
        pageText = String(target)
        guard target != store.page else { return }
        store.loadPage(target)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(WS("Refresh", "重新整理"))
            .accessibilityIdentifier("wm.workshop.refresh")

            Menu {
                Button {
                    showingImporter = true
                } label: {
                    Label(WS("Import downloaded folder", "匯入已下載資料夾"),
                          systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("wm.workshop.import")
                Button {
                    openURL(store.browseURL)
                } label: {
                    Label(WS("Open on Steam", "在 Steam 開啟"), systemImage: "safari")
                }
                Button {
                    store.checkForUpdates()
                } label: {
                    Label(WS("Check for updates", "檢查更新"),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                if !store.updates.available.isEmpty {
                    Button {
                        activeSheet = .updates
                    } label: {
                        Label(
                            String(
                                format: WS("%d updates available", "%d 個可用更新"),
                                store.updates.available.count),
                            systemImage: "arrow.down.circle")
                    }
                }
                Divider()
                if store.isSignedInToSteam {
                    Button(role: .destructive) {
                        showingSignOut = true
                    } label: {
                        Label(WS("Sign out of Steam", "登出 Steam"),
                              systemImage: "person.crop.circle.badge.xmark")
                    }
                } else {
                    Button {
                        store.beginSteamSignIn()
                        activeSheet = .signIn
                    } label: {
                        Label(WS("Sign in to Steam", "登入 Steam"),
                              systemImage: "person.crop.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(WS("More Workshop actions", "更多工作坊動作"))
        }
    }
}

/// The one sheet the Workshop tab presents. Using a single item keeps the filters, sign-in,
/// updates, and detail presentations from competing with one another.
enum WorkshopSheet: Identifiable {
    case filters
    case signIn
    case updates
    case detail(WorkshopItem)

    var id: String {
        switch self {
        case .filters: "filters"
        case .signIn: "sign-in"
        case .updates: "updates"
        case .detail(let item): "detail-\(item.id)"
        }
    }
}

/// One tile. It shows only what Steam returned and the library's state; the tap opens the
/// detail sheet, which is where the honest install guidance lives.
struct WorkshopTile: View {
    let item: WorkshopItem
    let store: WorkshopStore
    @ObservedObject private var library: LibraryStore
    let onSelect: () -> Void
    let onOpenCollection: () -> Void
    let onOpenAuthor: () -> Void

    @Environment(\.openURL) private var openURL

    @MainActor
    init(
        item: WorkshopItem, store: WorkshopStore, library: LibraryStore,
        onSelect: @escaping () -> Void, onOpenCollection: @escaping () -> Void,
        onOpenAuthor: @escaping () -> Void
    ) {
        self.item = item
        self.store = store
        _library = ObservedObject(wrappedValue: library)
        self.onSelect = onSelect
        self.onOpenCollection = onOpenCollection
        self.onOpenAuthor = onOpenAuthor
    }

    private var installed: Bool {
        library.items.contains { $0.workshopID == item.id }
    }

    private var update: WorkshopItem? { store.updates.available[item.id] }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        WorkshopThumbnailImage(url: item.previewURL, cache: store.thumbnails)
                    }
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        Text(item.kind.title)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 5) {
                            if item.isCollection {
                                Label(
                                    item.collectionSize.flatMap { $0 > 0 ? "\($0)" : nil }
                                        ?? WS("Collection", "合集"),
                                    systemImage: "square.stack")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            if update != nil {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .padding(5)
                                    .background(.ultraThinMaterial, in: Circle())
                            } else if installed {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .padding(5)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                        }
                        .padding(8)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text(verbatim: item.creator)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if item.size > 0 {
                            Label(WorkshopFormat.bytes(item.size), systemImage: "internaldrive")
                                .labelStyle(.titleAndIcon)
                        }
                        Label(
                            WorkshopFormat.number(item.subscriptions),
                            systemImage: "heart")
                            .labelStyle(.titleAndIcon)
                        Spacer(minLength: 0)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    if let firstTag = item.tags.first(where: {
                        !WorkshopKind.allCases.map(\.rawValue).contains($0)
                    }) {
                        Text(verbatim: firstTag)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wm.workshop.tile.\(item.id)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(WS("Shows details", "顯示詳細資料"))
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label(WS("Details", "詳細資料"), systemImage: "info.circle")
            }
            Button {
                openURL(item.pageURL)
            } label: {
                Label(WS("Open on Steam", "在 Steam 開啟"), systemImage: "safari")
            }
            Button {
                UIPasteboard.general.string = item.pageURL.absoluteString
            } label: {
                Label(WS("Copy link", "複製連結"), systemImage: "doc.on.doc")
            }
            if item.isCollection {
                Button {
                    onOpenCollection()
                } label: {
                    Label(WS("Open collection", "開啟合集"), systemImage: "square.stack")
                }
            } else if item.creatorID != nil {
                Button {
                    onOpenAuthor()
                } label: {
                    Label(WS("More by this author", "此作者的其他作品"),
                          systemImage: "person.crop.circle")
                }
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.title, item.creator, item.kind.title]
        if installed { parts.append(WS("In your library", "已在媒體庫")) }
        if update != nil { parts.append(WS("Update available", "有更新")) }
        if item.isCollection { parts.append(WS("Collection", "合集")) }
        return parts.joined(separator: ", ")
    }
}
