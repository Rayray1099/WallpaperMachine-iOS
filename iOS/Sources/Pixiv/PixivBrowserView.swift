// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

@MainActor
struct PixivBrowserView: View {
    @Bindable var store: PixivStore
    let onShowInLibrary: (WallpaperItem) -> Void

    @State private var draft: PixivQuery
    @State private var hasEditedQuery = false
    @State private var searchTask: Task<Void, Never>?
    @State private var filtersExpanded = false
    @State private var signInPresented = false
    @State private var selectedWork: PixivWork?

    init(store: PixivStore, onShowInLibrary: @escaping (WallpaperItem) -> Void) {
        self.store = store
        self.onShowInLibrary = onShowInLibrary
        _draft = State(initialValue: store.query)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                searchControls
                filterControls
                accountRow
                notices
                resultsSummary
                resultContent
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .navigationTitle(Text("pixiv.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        searchTask?.cancel()
                        store.apply(draft, refresh: true)
                    } label: {
                        Label("pixiv.refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
            .refreshable {
                searchTask?.cancel()
                store.apply(draft, refresh: true)
            }
        }
        .task {
            await store.start()
            if !hasEditedQuery { draft = store.query }
        }
        .onChange(of: draft.text) { _, _ in debounceSearch() }
        .onChange(of: store.account?.id) { _, _ in accountChanged() }
        .onChange(of: store.canShowMature) { _, _ in accountChanged() }
        .onDisappear { searchTask?.cancel() }
        .sheet(isPresented: $signInPresented) {
            PixivSignInView { session in
                store.signIn(session: session)
                signInPresented = false
            }
        }
        .sheet(item: $selectedWork) { work in
            PixivWorkDetailSheet(store: store, work: work, onShowInLibrary: onShowInLibrary)
        }
    }

    private var searchControls: some View {
        HStack(spacing: 10) {
            TextField("pixiv.search.prompt", text: searchText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { submitSearch() }
                .accessibilityIdentifier("pixiv.search")

            Button(action: submitSearch) {
                Label("pixiv.search.action", systemImage: "magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(Text("pixiv.search.action"))
            .disabled(store.isLoading)
        }
    }

    private var searchText: Binding<String> {
        Binding(
            get: { draft.text },
            set: {
                draft.text = String($0.prefix(256))
                hasEditedQuery = true
            })
    }

    private var filterControls: some View {
        DisclosureGroup(isExpanded: $filtersExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Picker("pixiv.ranking", selection: queryBinding(\.ranking)) {
                        ForEach(availableRankings, id: \.self) { ranking in
                            Text(rankingTitle(ranking)).tag(ranking)
                        }
                    }
                } else {
                    Picker("pixiv.search.order", selection: queryBinding(\.order)) {
                        Text("pixiv.search.newest").tag(PixivSearchOrder.newest)
                        Text("pixiv.search.oldest").tag(PixivSearchOrder.oldest)
                    }
                }

                Picker("pixiv.orientation", selection: queryBinding(\.orientation)) {
                    Text("pixiv.orientation.any").tag(PixivOrientation.any)
                    Text("pixiv.orientation.landscape").tag(PixivOrientation.landscape)
                    Text("pixiv.orientation.portrait").tag(PixivOrientation.portrait)
                }

                Picker("pixiv.minimumSize", selection: queryBinding(\.minimumSize)) {
                    Text("pixiv.minimumSize.any").tag(PixivMinimumSize.any)
                    Text("pixiv.minimumSize.fullHD").tag(PixivMinimumSize.fullHD)
                    Text("pixiv.minimumSize.quadHD").tag(PixivMinimumSize.quadHD)
                    Text("pixiv.minimumSize.ultraHD").tag(PixivMinimumSize.ultraHD)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("pixiv.rating")
                        .font(.subheadline.weight(.semibold))
                    ratingToggle(.everyone, key: "pixiv.rating.everyone")
                    ratingToggle(.questionable, key: "pixiv.rating.questionable")
                    ratingToggle(.mature, key: "pixiv.rating.mature")
                        .disabled(!store.canShowMature)
                    if !store.canShowMature {
                        if store.account?.showsR18 == false {
                            Text("pixiv.rating.accountRestrictionHint")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("pixiv.rating.signInHint") { signInPresented = true }
                                .font(.footnote)
                        }
                    }
                }

                Toggle("pixiv.hideAI", isOn: queryBinding(\.hidesAIGenerated))
                Text("pixiv.hideAI.note")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("pixiv.clearFilters", action: clearFilters)
                    Spacer()
                    Text(verbatim: String(
                        format: NSLocalizedString("pixiv.filterCount", comment: ""),
                        activeFilterCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("pixiv.filters", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityIdentifier("pixiv.filters")
    }

    private var accountRow: some View {
        HStack(spacing: 8) {
            if store.isCheckingAccount {
                ProgressView()
                    .controlSize(.small)
                Text("pixiv.account.checking")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let account = store.account {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.secondary)
                Text(verbatim: String(
                    format: NSLocalizedString("pixiv.account.signedInAs", comment: ""),
                    account.name))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button("pixiv.account.signOut", action: store.signOut)
                    .buttonStyle(.borderless)
            } else {
                Text("pixiv.account.signedOut")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("pixiv.account.signIn") { signInPresented = true }
                    .buttonStyle(.bordered)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var notices: some View {
        if let warning = store.sessionWarning, !warning.isEmpty {
            PixivNotice(message: warning, symbol: "person.crop.circle.badge.exclamationmark")
        }
        if let error = store.errorMessage, !error.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                PixivNotice(message: error, symbol: "exclamationmark.triangle.fill")
                Button("pixiv.dismiss") { store.errorMessage = nil }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("pixiv.dismiss"))
            }
        }
    }

    private var resultsSummary: some View {
        HStack(spacing: 8) {
            Text(verbatim: String(
                format: NSLocalizedString("pixiv.results.count", comment: ""),
                store.totalCount))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if store.totalPages > 1 {
                Button {
                    store.loadPage(store.page - 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(store.isLoading || store.page <= 1)
                .accessibilityLabel(Text("pixiv.previousPage"))

                Text(verbatim: String(
                    format: NSLocalizedString("pixiv.pageStatus", comment: ""),
                    store.page, store.totalPages))
                    .font(.footnote.monospacedDigit())

                Button {
                    store.loadPage(store.page + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(store.isLoading || store.page >= store.totalPages)
                .accessibilityLabel(Text("pixiv.nextPage"))
            }
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if store.works.isEmpty {
            ContentUnavailableView {
                if store.isLoading {
                    Label("pixiv.loading", systemImage: "magnifyingglass")
                } else if store.hiddenCount > 0 {
                    Label("pixiv.empty.filtered.title", systemImage: "line.3.horizontal.decrease")
                } else {
                    Label("pixiv.empty.title", systemImage: "photo.on.rectangle.angled")
                }
            } description: {
                if store.isLoading {
                    Text("pixiv.loading.description")
                } else if store.hiddenCount > 0 {
                    Text(verbatim: String(
                        format: NSLocalizedString("pixiv.empty.filtered.message", comment: ""),
                        store.hiddenCount))
                } else {
                    Text("pixiv.empty.message")
                }
            } actions: {
                if store.isLoading {
                    ProgressView()
                } else if store.errorMessage != nil {
                    Button("pixiv.retry") { retryListing() }
                        .buttonStyle(.borderedProminent)
                } else if store.hiddenCount > 0 {
                    Button("pixiv.clearFilters", action: clearFilters)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 148, maximum: 260), spacing: 12)],
                    alignment: .center,
                    spacing: 14
                ) {
                    ForEach(store.works) { work in
                        PixivWorkTile(work: work) { selectedWork = work }
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay(alignment: .top) {
                if store.isLoading {
                    ProgressView()
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                }
            }
        }
    }

    private var availableRankings: [PixivRanking] {
        if store.canShowMature && draft.ratings.contains(.mature) {
            return PixivRanking.allCases
        }
        return PixivRanking.allCases.filter { !$0.isR18 }
    }

    private var activeFilterCount: Int {
        (draft.orientation == .any ? 0 : 1)
            + (draft.minimumSize == .any ? 0 : 1)
            + (draft.hidesAIGenerated ? 1 : 0)
            + (draft.ratings.contains(.everyone) ? 0 : 1)
            + (draft.ratings.contains(.questionable) ? 1 : 0)
            + (draft.ratings.contains(.mature) ? 1 : 0)
    }

    private func queryBinding<Value>(_ keyPath: WritableKeyPath<PixivQuery, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                draft[keyPath: keyPath] = value
                hasEditedQuery = true
                searchTask?.cancel()
                store.apply(draft)
            })
    }

    private func ratingToggle(_ rating: PixivRating, key: String) -> some View {
        Toggle(
            isOn: Binding(
                get: { draft.ratings.contains(rating) },
                set: { isOn in
                    if isOn { draft.ratings.insert(rating) }
                    else { draft.ratings.remove(rating) }
                    hasEditedQuery = true
                    store.apply(draft)
                })
        ) {
            Text(LocalizedStringKey(key))
        }
    }

    private func rankingTitle(_ ranking: PixivRanking) -> LocalizedStringKey {
        switch ranking {
        case .daily: "pixiv.ranking.daily"
        case .weekly: "pixiv.ranking.weekly"
        case .monthly: "pixiv.ranking.monthly"
        case .rookie: "pixiv.ranking.rookie"
        case .dailyR18: "pixiv.ranking.dailyR18"
        case .weeklyR18: "pixiv.ranking.weeklyR18"
        }
    }

    private func debounceSearch() {
        hasEditedQuery = true
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) }
            catch { return }
            guard !Task.isCancelled else { return }
            store.apply(draft)
        }
    }

    private func submitSearch() {
        searchTask?.cancel()
        hasEditedQuery = true
        store.apply(draft, refresh: true)
    }

    private func clearFilters() {
        draft.orientation = .any
        draft.minimumSize = .any
        draft.hidesAIGenerated = false
        draft.ratings = [.everyone]
        draft.ranking = draft.ranking.allAges
        hasEditedQuery = true
        searchTask?.cancel()
        store.apply(draft)
    }

    private func retryListing() {
        searchTask?.cancel()
        if store.page > 1 { store.loadPage(store.page) }
        else { store.apply(draft, refresh: true) }
    }

    private func accountChanged() {
        selectedWork = nil
        draft = draft.sanitized(signedIn: store.canShowMature)
        searchTask?.cancel()
    }
}

private struct PixivNotice: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            Text(verbatim: message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.footnote)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PixivWorkTile: View {
    let work: PixivWork
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        PixivThumbnailView(url: work.thumbnailURL)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(0.78, contentMode: .fit)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        if let rank = work.rank {
                            Text(verbatim: "#\(rank)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(7)
                        }
                    }

                    Text(verbatim: work.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        if work.rating == .mature {
                            Text("pixiv.rating.matureBadge")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        if work.pageCount > 1 {
                            Text(verbatim: String(
                                format: NSLocalizedString("pixiv.pageCount", comment: ""),
                                work.pageCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pixiv.work.\(work.id)")

            HStack(spacing: 8) {
                if let artistURL = PixivExternalLinks.artist(work.authorID) {
                    Link(destination: artistURL) {
                        Text(verbatim: work.authorName)
                            .lineLimit(1)
                    }
                    .accessibilityLabel(Text("pixiv.artist"))
                } else {
                    Text(verbatim: work.authorName)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let artworkURL = PixivExternalLinks.artwork(work.id) {
                    Link("pixiv.openArtwork", destination: artworkURL)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(Text("pixiv.openArtwork"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PixivWorkDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: PixivStore
    let work: PixivWork
    let onShowInLibrary: (WallpaperItem) -> Void

    @State private var pages: [PixivPage]?
    @State private var pageError: String?
    @State private var selectedPageIndex = 0

    private var orderedPages: [PixivPage] { (pages ?? []).sorted { $0.index < $1.index } }
    private var selectedPage: PixivPage? {
        orderedPages.first { $0.index == selectedPageIndex } ?? orderedPages.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PixivThumbnailView(
                        url: selectedPage?.previewURL ?? work.thumbnailURL,
                        contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 380)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    Text(verbatim: work.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)

                    detailLinks
                    workFacts
                    pageControls
                    downloadControls
                    tagList
                }
                .padding(18)
            }
            .navigationTitle(Text("pixiv.workDetails"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("pixiv.done", action: dismiss.callAsFunction)
                }
            }
        }
        .task(id: work.id) { await loadPages() }
        .onChange(of: store.account?.id) { _, _ in dismiss() }
        .onChange(of: store.canShowMature) { _, allowed in
            if work.rating == .mature && !allowed { dismiss() }
        }
        .presentationDragIndicator(.visible)
    }

    private var detailLinks: some View {
        HStack(spacing: 16) {
            if let artistURL = PixivExternalLinks.artist(work.authorID) {
                Link(destination: artistURL) {
                    Label {
                        Text(verbatim: work.authorName)
                    } icon: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            if let artworkURL = PixivExternalLinks.artwork(work.id) {
                Link("pixiv.openArtwork", destination: artworkURL)
            }
        }
        .font(.subheadline)
    }

    private var workFacts: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(work.width.formatted()) × \(work.height.formatted())")
            Text("pixiv.pixels")
            if work.rating == .questionable {
                Text("pixiv.rating.questionable")
            } else if work.rating == .mature {
                Text("pixiv.rating.mature")
            }
            if work.aiGenerated == true {
                Text("pixiv.aiGenerated")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    @ViewBuilder
    private var pageControls: some View {
        if let pageError {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: pageError)
                    .foregroundStyle(.red)
                Button("pixiv.pages.retry") { Task { await loadPages() } }
                    .buttonStyle(.bordered)
            }
        } else if pages == nil {
            ProgressView("pixiv.pages.loading")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if orderedPages.count > 1 {
            Picker("pixiv.page", selection: $selectedPageIndex) {
                ForEach(orderedPages, id: \.index) { page in
                    Text(verbatim: String(
                        format: NSLocalizedString("pixiv.page.number", comment: ""),
                        page.index + 1))
                        .tag(page.index)
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var downloadControls: some View {
        if let page = selectedPage {
            let state = store.download(for: work, page: page.index)
            let installed = store.installedItem(for: work, page: page.index)
            VStack(alignment: .leading, spacing: 10) {
                if let installed {
                    Button {
                        onShowInLibrary(installed)
                        dismiss()
                    } label: {
                        Label("pixiv.showInLibrary", systemImage: "rectangle.stack")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else if let state {
                    switch state.status {
                    case .queued:
                        HStack {
                            ProgressView()
                            Text("pixiv.download.queued")
                            Spacer()
                            Button("pixiv.download.cancel") { store.cancelDownload(state.id) }
                                .buttonStyle(.borderless)
                        }
                    case .downloading:
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ProgressView(value: state.progress)
                                Text("pixiv.download.downloading")
                            }
                            if state.expected != nil {
                                Text(verbatim: Self.byteProgress(state.received, state.expected))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Button("pixiv.download.cancel") { store.cancelDownload(state.id) }
                                .buttonStyle(.borderless)
                        }
                    case .importing:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("pixiv.download.importing")
                        }
                    case .completed:
                        if installed == nil {
                            downloadButton(page)
                        }
                    case .cancelled:
                        downloadButton(page)
                    case .failed:
                        if let message = state.errorMessage, !message.isEmpty {
                            Text(verbatim: message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Button {
                            store.requestDownload(work, page: page, pageCount: orderedPages.count)
                        } label: {
                            Label("pixiv.download.retry", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    downloadButton(page)
                }
            }
        } else if pages != nil {
            Text("pixiv.pages.empty")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var tagList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(work.tags.enumerated()), id: \.offset) { _, tag in
                    Text(verbatim: tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .accessibilityLabel(Text("pixiv.tags"))
    }

    private func downloadButton(_ page: PixivPage) -> some View {
        let titleKey = orderedPages.count > 1 ? "pixiv.download.page" : "pixiv.download"
        let title = orderedPages.count > 1
            ? String(format: NSLocalizedString(titleKey, comment: ""), page.index + 1)
            : NSLocalizedString(titleKey, comment: "")
        return Button {
            store.requestDownload(work, page: page, pageCount: orderedPages.count)
        } label: {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(orderedPages.isEmpty || store.canShowMature == false && work.rating == .mature)
    }

    private func loadPages() async {
        pageError = nil
        do {
            let result = try await store.pages(for: work)
            try Task.checkCancellation()
            pages = result.sorted { $0.index < $1.index }
            selectedPageIndex = pages?.first?.index ?? 0
        } catch is CancellationError {
            return
        } catch {
            pageError = error.localizedDescription
        }
    }

    private static func byteProgress(_ received: Int64, _ expected: Int64?) -> String {
        let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard let expected else { return receivedText }
        let expectedText = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        return String(
            format: NSLocalizedString("pixiv.download.bytes", comment: ""),
            receivedText, expectedText)
    }
}

private enum PixivExternalLinks {
    static func artist(_ id: String) -> URL? {
        guard PixivWork.isValidID(id) else { return nil }
        return URL(string: "https://www.pixiv.net/users/\(id)")
    }

    static func artwork(_ id: String) -> URL? {
        guard PixivWork.isValidID(id) else { return nil }
        return URL(string: "https://www.pixiv.net/artworks/\(id)")
    }
}
