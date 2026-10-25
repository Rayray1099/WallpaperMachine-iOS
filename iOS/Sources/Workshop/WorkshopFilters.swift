import Foundation

/// The boxes of the Workshop filter panel, tag for tag as Wallpaper Engine's own Workshop
/// sidebar lists them.
///
/// "Show only" boxes start unticked, and ticking one sends its tag to Steam as a required
/// tag. Chips start out filtering nothing: a selected chip is required too, and a hidden
/// chip is excluded. Every other box starts ticked, and unticking it sends its tag as an
/// excluded one, so a group with everything ticked filters nothing. Tags travel to Steam in
/// English; only their labels are translated. The two tags that are never offered and the
/// boxes Wallpaper Engine leaves unticked by default make up the default excluded list,
/// which must equal `WorkshopStore.defaultExcludedTags`.
enum WorkshopFilterCatalog {
    struct Entry: Identifiable, Equatable, Sendable {
        /// The tag Steam knows the box by.
        let tag: String
        /// The label a person reads.
        let label: String
        /// Wallpaper Engine leaves this box unticked until the person ticks it.
        let isOffByDefault: Bool

        var id: String { tag }

        init(_ tag: String, _ label: String, off: Bool = false) {
            self.tag = tag
            self.label = label
            self.isOffByDefault = off
        }

        init(_ tag: String, verbatim label: String) {
            self.tag = tag
            self.label = label
            self.isOffByDefault = false
        }
    }

    struct Section: Identifiable, Equatable, Sendable {
        enum Style: Equatable, Sendable {
            /// One checkbox to a line.
            case checkboxes
            /// Tags as chips, for a long list.
            case chips
        }

        let id: String
        let title: String?
        let entries: [Entry]
        /// The section offers **All** and **None**.
        let hasQuickLinks: Bool
        let style: Style

        var tags: [String] { entries.map(\.tag) }
    }

    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let sections: [Section]

        var tags: [String] { sections.flatMap(\.tags) }
    }

    /// A "Show only" box: a tag the item must carry.
    struct RequiredEntry: Identifiable, Equatable, Sendable {
        let tag: String
        let label: String
        let systemImage: String

        var id: String { tag }
    }

    // MARK: The catalog

    /// "Show only": ticking one requires its tag.
    static let showOnly: [RequiredEntry] = [
        RequiredEntry(tag: "Approved", label: WS("Approved", "已核准"), systemImage: "trophy.fill"),
        RequiredEntry(
            tag: "Audio responsive", label: WS("Audio responsive", "音訊回應"),
            systemImage: "waveform"),
        RequiredEntry(
            tag: "Customizable", label: WS("Customizable", "可自訂"),
            systemImage: "slider.horizontal.3"),
    ]

    static let hiddenExcludedTags = ["Application", "Asset"]

    private static func resolution(
        _ id: String, _ title: String, standard: String, prefix: String, sizes: [String]
    ) -> Section {
        Section(
            id: id, title: title,
            entries: [Entry("\(prefix)Standard Definition", verbatim: standard)]
                + sizes.map { Entry("\(prefix)\($0)", verbatim: $0) },
            hasQuickLinks: true, style: .checkboxes)
    }

    static let groups: [Group] = [
        Group(
            id: "type", title: WS("Type", "類型"),
            sections: [
                Section(
                    id: "type", title: nil,
                    entries: [
                        Entry("Scene", WS("Scene", "場景")),
                        Entry("Video", WS("Video", "影片")),
                        Entry("Web", WS("Web", "網頁")),
                    ],
                    hasQuickLinks: false, style: .checkboxes),
                Section(
                    id: "category", title: nil,
                    entries: [
                        Entry("Wallpaper", WS("Wallpaper", "桌布")),
                        Entry("Preset", WS("Preset", "預設集")),
                    ],
                    hasQuickLinks: false, style: .checkboxes),
            ]),
        Group(
            id: "rating", title: WS("Age rating", "年齡分級"),
            sections: [
                Section(
                    id: "rating", title: nil,
                    entries: [
                        Entry("Everyone", WS("Everyone (G)", "全年齡 (G)")),
                        Entry("Questionable", WS("Questionable (PG-13)", "輔導級 (PG-13)"), off: true),
                        Entry("Mature", WS("Mature (R-18)", "限制級 (R-18)"), off: true),
                    ],
                    hasQuickLinks: false, style: .checkboxes)
            ]),
        Group(
            id: "resolution", title: WS("Resolution", "解析度"),
            sections: [
                resolution(
                    "widescreen", WS("Widescreen", "寬螢幕"), standard: WS("Standard definition", "標準畫質"),
                    prefix: "", sizes: ["1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440", "3840 x 2160"]),
                resolution(
                    "ultrawide", WS("Ultrawide", "超寬螢幕"),
                    standard: WS("Ultrawide (standard)", "超寬螢幕 (標準)"), prefix: "Ultrawide ",
                    sizes: ["2560 x 1080", "3440 x 1440"]),
                resolution(
                    "dual", WS("Dual monitor", "雙螢幕"),
                    standard: WS("Dual monitor (standard)", "雙螢幕 (標準)"), prefix: "Dual ",
                    sizes: ["3840 x 1080", "5120 x 1440", "7680 x 2160"]),
                resolution(
                    "triple", WS("Triple monitor", "三螢幕"),
                    standard: WS("Triple monitor (standard)", "三螢幕 (標準)"), prefix: "Triple ",
                    sizes: ["4096 x 768", "5760 x 1080", "7680 x 1440", "11520 x 2160"]),
                resolution(
                    "portrait", WS("Portrait monitor / phone", "直式螢幕 / 手機"),
                    standard: WS("Portrait monitor / phone (standard)", "直式螢幕 / 手機 (標準)"),
                    prefix: "Portrait ", sizes: ["720 x 1280", "1080 x 1920", "1440 x 2560", "2160 x 3840"]),
                Section(
                    id: "other-resolution", title: nil,
                    entries: [
                        Entry("Other resolution", WS("Other resolution", "其他解析度")),
                        Entry("Dynamic resolution", WS("Dynamic resolution", "動態解析度")),
                    ],
                    hasQuickLinks: false, style: .checkboxes),
            ]),
        Group(
            id: "genre", title: WS("Tags", "標籤"),
            sections: [
                Section(
                    id: "genre", title: nil,
                    entries: [
                        Entry("Abstract", WS("Abstract", "抽象")),
                        Entry("Animal", WS("Animal", "動物")),
                        Entry("Anime", WS("Anime", "動漫")),
                        Entry("Cartoon", WS("Cartoon", "卡通")),
                        Entry("CGI", WS("CGI", "CGI")),
                        Entry("Cyberpunk", WS("Cyberpunk", "賽博龐克")),
                        Entry("Fantasy", WS("Fantasy", "奇幻")),
                        Entry("Game", WS("Game", "遊戲")),
                        Entry("Girls", WS("Girls", "女性")),
                        Entry("Guys", WS("Guys", "男性")),
                        Entry("Landscape", WS("Landscape", "風景")),
                        Entry("Medieval", WS("Medieval", "中世紀")),
                        Entry("Memes", WS("Memes", "迷因")),
                        Entry("MMD", WS("MMD (Miku Miku Dance)", "MMD (Miku Miku Dance)")),
                        Entry("Music", WS("Music", "音樂")),
                        Entry("Nature", WS("Nature", "自然")),
                        Entry("Pixel art", WS("Pixel art", "像素藝術")),
                        Entry("Relaxing", WS("Relaxing", "放鬆")),
                        Entry("Retro", WS("Retro", "復古")),
                        Entry("Sci-Fi", WS("Sci-Fi", "科幻")),
                        Entry("Sports", WS("Sports", "運動")),
                        Entry("Technology", WS("Technology", "科技")),
                        Entry("Television", WS("Television", "電視")),
                        Entry("Vehicle", WS("Vehicle", "載具")),
                        Entry("Unspecified", WS("Unspecified genre", "未指定類型"), off: true),
                    ],
                    hasQuickLinks: true, style: .chips)
            ]),
    ]

    static var sections: [Section] { groups.flatMap(\.sections) }
    static let chipTags: Set<String> = Set(
        groups.flatMap(\.sections).filter { $0.style == .chips }.flatMap(\.tags))
    static var entries: [Entry] { sections.flatMap(\.entries) }

    /// What Wallpaper Engine excludes until the person says otherwise: the tags that are
    /// never offered, then every box that starts unticked, in the catalog's order.
    static let defaultExcludedTags: [String] =
        hiddenExcludedTags + entries.filter(\.isOffByDefault).map(\.tag)
}

/// How a chip or checkbox stands.
enum WorkshopFilterSelection: Equatable, Sendable {
    case plain
    case required
    case excluded
}

/// The Workshop filters as the page edits them before and after asking Steam: the tags an
/// item must carry and the tags that hide it.
///
/// A tag is never both required and excluded: requiring one stops excluding it and the
/// other way round. The count the Filter button shows is every required tag plus every box
/// or chip whose state differs from its default, so it reads zero right after **Clear**.
struct WorkshopFilterDraft: Equatable, Sendable {
    var tags: [String]
    var excludedTags: [String]

    static let defaultExcludedTags = WorkshopFilterCatalog.defaultExcludedTags

    static var cleared: WorkshopFilterDraft {
        WorkshopFilterDraft(tags: [], excludedTags: defaultExcludedTags)
    }

    /// How many filters are in effect.
    var count: Int {
        let defaults = Self.defaultExcludedTags
        return tags.count
            + defaults.filter { !excludedTags.contains($0) && !tags.contains($0) }.count
            + excludedTags.filter { !defaults.contains($0) }.count
    }

    func count(in group: WorkshopFilterCatalog.Group) -> Int {
        group.tags.filter { chipSelection($0) != Self.defaultSelection($0) }.count
    }

    /// "Show only" boxes that are ticked, plus tags required without a box or chip.
    var requiredCount: Int {
        tags.filter { !WorkshopFilterCatalog.chipTags.contains($0) }.count
    }

    func isIncluded(_ tag: String) -> Bool { !excludedTags.contains(tag) }

    func isRequired(_ tag: String) -> Bool { tags.contains(tag) }

    func chipSelection(_ tag: String) -> WorkshopFilterSelection {
        if isRequired(tag) { return .required }
        return excludedTags.contains(tag) ? .excluded : .plain
    }

    private static func defaultSelection(_ tag: String) -> WorkshopFilterSelection {
        defaultExcludedTags.contains(tag) ? .excluded : .plain
    }

    mutating func setChip(_ tag: String, _ selection: WorkshopFilterSelection) {
        setRequired(tag, selection == .required)
        setExcluded([tag], selection == .excluded)
    }

    mutating func resetChips(in section: WorkshopFilterCatalog.Section) {
        for tag in section.tags { setChip(tag, Self.defaultSelection(tag)) }
    }

    func chipsAreAtDefaults(in section: WorkshopFilterCatalog.Section) -> Bool {
        section.tags.allSatisfy { chipSelection($0) == Self.defaultSelection($0) }
    }

    /// Required tags the "Show only" boxes and the chips do not offer, listed as ticked
    /// boxes of their own so they can be unticked.
    var otherRequiredTags: [String] {
        let offered = Set(WorkshopFilterCatalog.showOnly.map(\.tag))
            .union(WorkshopFilterCatalog.chipTags)
        return tags.filter { !offered.contains($0) }
    }

    mutating func setRequired(_ tag: String, _ required: Bool) {
        if required {
            if !tags.contains(tag) { tags.append(tag) }
            excludedTags.removeAll { $0 == tag }
        } else {
            tags.removeAll { $0 == tag }
        }
    }

    mutating func setIncluded(_ tag: String, _ included: Bool) {
        setExcluded([tag], !included)
    }

    mutating func setExcluded(_ tagsToSet: [String], _ excluded: Bool) {
        var set = excludedTags
        for tag in tagsToSet {
            if excluded {
                if !set.contains(tag) { set.append(tag) }
                tags.removeAll { $0 == tag }
            } else {
                set.removeAll { $0 == tag }
            }
        }
        excludedTags = set
    }

    mutating func includeAll(in section: WorkshopFilterCatalog.Section) {
        setExcluded(section.tags, false)
    }

    mutating func excludeAll(in section: WorkshopFilterCatalog.Section) {
        setExcluded(section.tags, true)
    }

    func includesAll(in section: WorkshopFilterCatalog.Section) -> Bool {
        section.tags.allSatisfy(isIncluded)
    }

    func includesNone(in section: WorkshopFilterCatalog.Section) -> Bool {
        !section.tags.contains(where: isIncluded)
    }

    mutating func clear() { self = .cleared }
}
