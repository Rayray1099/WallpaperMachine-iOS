import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Wallpaper kind presentation

extension WallpaperKind {
    var wmSystemImage: String {
        switch self {
        case .scene:
            return "cube.transparent"
        case .video:
            return "video"
        case .web:
            return "globe"
        case .image:
            return "photo"
        }
    }

    var wmLocalizedKey: LocalizedStringKey {
        switch self {
        case .scene:
            return "kind.scene"
        case .video:
            return "kind.video"
        case .web:
            return "kind.web"
        case .image:
            return "kind.image"
        }
    }
}

/// The three scaling modes shared with `PlaybackSettings.scaling`.
enum WMWallpaperScaling: String {
    case fit
    case fill
    case stretch

    init(setting: String) {
        self = WMWallpaperScaling(rawValue: setting) ?? .fit
    }
}

enum WMImportContentTypes {
    /// Folders carry Wallpaper Engine project packages; `.data` admits video, image,
    /// HTML and package files the library store knows how to import. The store decides
    /// what is supported and reports anything it cannot import.
    static let allowed: [UTType] = [.folder, .data]
}

// MARK: - Inspector chrome

struct WMInspectorCard<Content: View>: View {
    let titleKey: LocalizedStringKey
    let content: Content

    init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.titleKey = titleKey
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(titleKey)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

// MARK: - Errors

private struct WMErrorAlertModifier: ViewModifier {
    @ObservedObject var model: WMAppModel

    func body(content: Content) -> some View {
        content.alert(
            "alert.error.title",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("common.ok", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(verbatim: model.errorMessage ?? "")
        }
    }
}

extension View {
    /// Presents the model's current error with an OK button. Applied to every sheet
    /// root as well as the main window so a failure always has a visible surface.
    func wmErrorAlert(model: WMAppModel) -> some View {
        modifier(WMErrorAlertModifier(model: model))
    }
}

// MARK: - Import progress

struct WMImportingOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("library.importing")
                .font(.callout)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wm.import.progress")
    }
}
