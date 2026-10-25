import SwiftUI

/// The Workshop's filter sidebar. Steam does the filtering; this panel edits exactly the
/// tags Wallpaper Engine's own sidebar offers, and every change asks Steam again with the
/// newest query winning. It is a permanent sidebar on a regular-width iPad and a sheet on a
/// compact one.
struct WorkshopFilterPanel: View {
    enum Mode: Equatable { case sidebar, sheet }

    let store: WorkshopStore
    var mode: Mode = .sidebar

    @Environment(\.dismiss) private var dismiss
    @State private var expandedGroups: Set<String> = ["type", "rating"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(WS("Filters", "篩選"))
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if store.filterCount > 0 {
                        Text("\(store.filterCount)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.tint, in: Capsule())
                    }
                    Button(WS("Clear", "清除")) {
                        store.clearFilters()
                    }
                    .font(.subheadline)
                    .disabled(store.filterCount == 0)
                    .accessibilityIdentifier("wm.workshop.filters.clear")
                }

                showOnlySection
                if !store.filters.otherRequiredTags.isEmpty { otherRequiredSection }
                ForEach(WorkshopFilterCatalog.groups) { group in
                    groupSection(group)
                }
                Text(WS(
                    "Filters are sent to Steam in English; their labels are translated. Steam decides which items match.",
                    "篩選條件以英文傳送給 Steam，標籤文字會翻譯。符合與否由 Steam 決定。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("wm.workshop.filters")
    }

    private var showOnlySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(WS("Show only", "只顯示"))
                .font(.headline)
            ForEach(WorkshopFilterCatalog.showOnly) { entry in
                checkRow(
                    label: entry.label,
                    systemImage: entry.systemImage,
                    isOn: store.filters.isRequired(entry.tag),
                    identifier: "wm.workshop.filter.\(entry.tag)"
                ) {
                    store.setRequired(entry.tag, !store.filters.isRequired(entry.tag))
                }
            }
        }
    }

    private var otherRequiredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(WS("Required tags", "必要標籤"))
                .font(.headline)
            ForEach(store.filters.otherRequiredTags, id: \.self) { tag in
                checkRow(
                    label: tag, systemImage: "tag",
                    isOn: true,
                    identifier: "wm.workshop.filter.required.\(tag)"
                ) {
                    store.setRequired(tag, false)
                }
            }
        }
    }

    private func groupSection(_ group: WorkshopFilterCatalog.Group) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedGroups.contains(group.id) },
                set: { expanded in
                    if expanded { expandedGroups.insert(group.id) }
                    else { expandedGroups.remove(group.id) }
                })
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(group.sections) { section in
                    sectionView(section)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text(group.title)
                    .font(.headline)
                let count = store.filters.count(in: group)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint, in: Capsule())
                }
                Spacer()
            }
        }
        .accessibilityIdentifier("wm.workshop.filter.group.\(group.id)")
    }

    @ViewBuilder
    private func sectionView(_ section: WorkshopFilterCatalog.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = section.title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            switch section.style {
            case .checkboxes:
                ForEach(section.entries) { entry in
                    checkRow(
                        label: entry.label,
                        systemImage: "square",
                        isOn: store.filters.isIncluded(entry.tag),
                        identifier: "wm.workshop.filter.\(entry.tag)"
                    ) {
                        store.setIncluded(entry.tag, !store.filters.isIncluded(entry.tag))
                    }
                }
                if section.hasQuickLinks {
                    HStack(spacing: 12) {
                        Button(WS("All", "全部")) {
                            store.includeAll(in: section)
                        }
                        .disabled(store.filters.includesAll(in: section))
                        Button(WS("None", "無")) {
                            store.excludeAll(in: section)
                        }
                        .disabled(store.filters.includesNone(in: section))
                        Spacer()
                    }
                    .font(.caption)
                }
            case .chips:
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6
                ) {
                    ForEach(section.entries) { entry in
                        chip(entry)
                    }
                }
                if section.hasQuickLinks {
                    HStack(spacing: 12) {
                        Button(WS("Reset", "重設")) {
                            store.resetChips(in: section)
                        }
                        .disabled(store.filters.chipsAreAtDefaults(in: section))
                        Spacer()
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func checkRow(
        label: String, systemImage: String, isOn: Bool, identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .imageScale(.medium)
                if !systemImage.isEmpty, systemImage != "square" {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? WS("Included", "包含") : WS("Excluded", "排除"))
        .accessibilityIdentifier(identifier)
    }

    private func chip(_ entry: WorkshopFilterCatalog.Entry) -> some View {
        let selection = store.filters.chipSelection(entry.tag)
        return Button {
            switch selection {
            case .plain: store.setChip(entry.tag, .required)
            case .required: store.setChip(entry.tag, .excluded)
            case .excluded: store.setChip(entry.tag, .plain)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chipSymbol(selection))
                    .font(.caption2)
                Text(entry.label)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(chipBackground(selection)))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(chipBorder(selection))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.label)
        .accessibilityValue(chipAccessibility(selection))
        .accessibilityHint(WS(
            "Cycles through required, excluded, and no filter.",
            "依序切換必要、排除、不篩選。"))
        .accessibilityIdentifier("wm.workshop.filter.\(entry.tag)")
    }

    private func chipSymbol(_ selection: WorkshopFilterSelection) -> String {
        switch selection {
        case .plain: "circle"
        case .required: "checkmark.circle.fill"
        case .excluded: "minus.circle.fill"
        }
    }

    private func chipBackground(_ selection: WorkshopFilterSelection) -> Color {
        switch selection {
        case .plain: Color(uiColor: .tertiarySystemFill)
        case .required: Color.accentColor.opacity(0.16)
        case .excluded: Color.red.opacity(0.12)
        }
    }

    private func chipBorder(_ selection: WorkshopFilterSelection) -> Color {
        switch selection {
        case .plain: .clear
        case .required: Color.accentColor.opacity(0.5)
        case .excluded: Color.red.opacity(0.4)
        }
    }

    private func chipAccessibility(_ selection: WorkshopFilterSelection) -> String {
        switch selection {
        case .plain: WS("No filter", "不篩選")
        case .required: WS("Required", "必要")
        case .excluded: WS("Excluded", "排除")
        }
    }
}
