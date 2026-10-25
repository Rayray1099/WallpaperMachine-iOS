import SwiftUI
import UIKit

// MARK: - JSONValue helpers used by the editors
//
// These are deliberately prefixed `wm...`: the shared JSONValue type belongs to the
// Lead-owned model, so the UI adds read helpers instead of another model.

extension JSONValue {
    var wmStringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var wmNumberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var wmBoolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var wmDisplayText: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.formatted(.number.precision(.fractionLength(0...3)))
        case .bool(let value):
            return value ? WMLocalized.string("common.on") : WMLocalized.string("common.off")
        case .array(let values):
            return WMLocalized.format("property.arrayCount", values.count)
        case .object(let values):
            return WMLocalized.format("property.objectCount", values.count)
        case .null:
            return "—"
        }
    }
}

// MARK: - Color values

private struct WMColorValue {
    let color: Color
    let scale: Double
}

private enum WMColorCodec {
    static func decode(_ value: JSONValue) -> WMColorValue? {
        guard let string = value.wmStringValue else { return nil }
        let components = string
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }
        guard components.count >= 3 else { return nil }
        let scale: Double = components.prefix(3).contains { $0 > 1.0 } ? 255 : 1
        let red = min(max(components[0] / scale, 0), 1)
        let green = min(max(components[1] / scale, 0), 1)
        let blue = min(max(components[2] / scale, 0), 1)
        return WMColorValue(
            color: Color(red: red, green: green, blue: blue),
            scale: scale
        )
    }

    static func encode(_ color: Color, scale: Double) -> JSONValue? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        if scale >= 100 {
            let components = [red, green, blue].map { Int(($0 * scale).rounded()) }
            return .string("\(components[0]) \(components[1]) \(components[2])")
        }
        return .string(String(format: "%.6f %.6f %.6f", red, green, blue))
    }
}

// MARK: - Property editors

struct WMPropertiesSection: View {
    @ObservedObject var model: WMAppModel
    let item: WallpaperItem

    var body: some View {
        WMInspectorCard("inspector.properties") {
            if item.properties.isEmpty {
                Text("inspector.noProperties")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(propertyKeys, id: \.self) { key in
                        if let property = item.properties[key], !isGroup(property) {
                            WMPropertyRow(
                                model: model,
                                itemID: item.id,
                                propertyKey: key,
                                property: property
                            )
                        }
                    }
                }
            }
        }
    }

    private var propertyKeys: [String] {
        item.properties.keys.sorted { lhs, rhs in
            let left = item.properties[lhs]?.label ?? lhs
            let right = item.properties[rhs]?.label ?? rhs
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    private func isGroup(_ property: WallpaperProperty) -> Bool {
        property.type.lowercased() == "group"
    }
}

private struct WMPropertyRow: View {
    @ObservedObject var model: WMAppModel
    let itemID: UUID
    let propertyKey: String
    let property: WallpaperProperty

    @State private var numericDraft: Double
    @State private var numericText: String
    @State private var textDraft: String
    @State private var colorDraft: Color
    @State private var colorScale: Double
    @FocusState private var textFocused: Bool

    init(model: WMAppModel, itemID: UUID, propertyKey: String, property: WallpaperProperty) {
        self.model = model
        self.itemID = itemID
        self.propertyKey = propertyKey
        self.property = property

        let number = property.value.wmNumberValue ?? property.minimum ?? 0
        _numericDraft = State(initialValue: number)
        _numericText = State(initialValue: number.formatted(.number.precision(.fractionLength(0...4))))
        _textDraft = State(initialValue: property.value.wmStringValue ?? property.value.wmDisplayText)
        let decoded = WMColorCodec.decode(property.value)
        _colorDraft = State(initialValue: decoded?.color ?? .white)
        _colorScale = State(initialValue: decoded?.scale ?? 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: property.label.isEmpty ? propertyKey : property.label)
                .font(.callout)
            editor
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("wm.property.\(propertyKey)")
    }

    @ViewBuilder
    private var editor: some View {
        switch editorKind {
        case .boolean:
            Toggle("property.enabled", isOn: boolBinding)
                .labelsHidden()
                .accessibilityLabel(Text(verbatim: property.label))
                .accessibilityIdentifier("wm.property.\(propertyKey).toggle")
        case .combo:
            if property.options.isEmpty {
                unsupportedValue
            } else {
                Picker("property.value", selection: comboBinding) {
                    ForEach(comboOptions, id: \.self) { option in
                        Text(verbatim: option).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("wm.property.\(propertyKey).combo")
            }
        case .numeric:
            numericEditor
        case .color:
            if WMColorCodec.decode(property.value) == nil {
                unsupportedValue
            } else {
                HStack(spacing: 10) {
                    ColorPicker(
                        "property.color",
                        selection: colorBinding,
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .accessibilityIdentifier("wm.property.\(propertyKey).color")
                    Text(verbatim: property.value.wmDisplayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        case .text:
            TextField("property.value", text: $textDraft)
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .submitLabel(.done)
                .onSubmit { commitText() }
                .onChange(of: textFocused) { _, focused in
                    if !focused { commitText() }
                }
                .accessibilityIdentifier("wm.property.\(propertyKey).text")
        case .unsupported:
            unsupportedValue
        }
    }

    private var numericEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let range = sliderRange {
                HStack {
                    Text(verbatim: property.value.wmDisplayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: numericDraft.formatted(.number.precision(.fractionLength(0...2))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $numericDraft,
                    in: range,
                    onEditingChanged: { editing in
                        if !editing { commitNumber() }
                    }
                )
                .accessibilityLabel(Text(verbatim: property.label))
                .accessibilityIdentifier("wm.property.\(propertyKey).slider")
            } else {
                TextField("property.value", text: $numericText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .focused($textFocused)
                    .onSubmit { commitNumberText() }
                    .onChange(of: textFocused) { _, focused in
                        if !focused { commitNumberText() }
                    }
                    .accessibilityIdentifier("wm.property.\(propertyKey).number")
            }
        }
    }

    private var unsupportedValue: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: property.value.wmDisplayText)
                .font(.callout)
                .textSelection(.enabled)
            Text(verbatim: WMLocalized.format("property.unsupported.message", property.type))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Kinds

    private enum EditorKind {
        case boolean
        case combo
        case numeric
        case color
        case text
        case unsupported
    }

    private var editorKind: EditorKind {
        switch property.type.lowercased() {
        case "bool", "boolean":
            return .boolean
        case "combo":
            return .combo
        case "slider", "float", "number", "int", "integer":
            return .numeric
        case "color":
            return .color
        case "textinput", "text", "string":
            return .text
        default:
            return .unsupported
        }
    }

    private var sliderRange: ClosedRange<Double>? {
        guard let minimum = property.minimum, let maximum = property.maximum, maximum > minimum else {
            return nil
        }
        return minimum...maximum
    }

    private var comboOptions: [String] {
        let current = property.value.wmStringValue
        if let current, !property.options.contains(current) {
            return [current] + property.options
        }
        return property.options
    }

    // MARK: - Bindings

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { property.value.wmBoolValue ?? false },
            set: { value in
                model.setPropertyValue(for: itemID, key: propertyKey, value: .bool(value))
            }
        )
    }

    private var comboBinding: Binding<String> {
        Binding(
            get: { property.value.wmStringValue ?? property.options.first ?? "" },
            set: { value in
                model.setPropertyValue(for: itemID, key: propertyKey, value: .string(value))
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { colorDraft },
            set: { value in
                colorDraft = value
                if let encoded = WMColorCodec.encode(value, scale: colorScale) {
                    model.setPropertyValue(for: itemID, key: propertyKey, value: encoded)
                }
            }
        )
    }

    // MARK: - Commits

    private func commitNumber() {
        model.setPropertyValue(for: itemID, key: propertyKey, value: .number(numericDraft))
    }

    private func commitNumberText() {
        let normalized = numericText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return }
        numericDraft = value
        numericText = value.formatted(.number.precision(.fractionLength(0...4)))
        model.setPropertyValue(for: itemID, key: propertyKey, value: .number(value))
    }

    private func commitText() {
        model.setPropertyValue(for: itemID, key: propertyKey, value: .string(textDraft))
    }
}
