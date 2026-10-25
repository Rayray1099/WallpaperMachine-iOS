import SwiftUI

/// Entry point for the iPad-first WallpaperMachine host.
///
/// The app keeps playback inside the foreground host: iPadOS has no public API for
/// third-party Home Screen or Lock Screen wallpapers, so the UI never offers one.
@main
@MainActor
struct WallpaperMachineIOSApp: App {
    @StateObject private var model: WMAppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _model = StateObject(wrappedValue: WMAppModel(library: LibraryStore()))
    }

    var body: some Scene {
        WindowGroup {
            WMRootView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    model.microphoneResponse.setApplicationActive(phase == .active)
                    if phase != .active {
                        model.pausePlaylist()
                    }
                }
        }
        .commands {
            WMAppCommands(model: model)
        }
    }
}
