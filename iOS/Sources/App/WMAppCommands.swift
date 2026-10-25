import SwiftUI

/// Menu-bar and hardware-keyboard commands shared by both layouts.
///
/// Only actions with real implementations are offered; playback and navigation
/// commands disable themselves when no wallpaper or playlist is available.
struct WMAppCommands: Commands {
    @ObservedObject var model: WMAppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button {
                model.presentImporter()
            } label: {
                Text("command.import")
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("command.menu.wallpaper") {
            Button {
                model.requestSearchFocus()
            } label: {
                Text("command.search")
            }
            .keyboardShortcut("f", modifiers: .command)

            Button {
                model.toggleFavoriteOnSelection()
            } label: {
                Text("command.favorite")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.selectedItem == nil)

            Button {
                model.toggleFullscreen()
            } label: {
                Text("command.fullscreen")
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .disabled(model.selectedItem == nil)

            Divider()

            Button {
                model.togglePlaylistPlayback()
            } label: {
                Text(LocalizedStringKey(model.isPlaylistPlaying ? "command.pause" : "command.play"))
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!model.canPlayPlaylist)

            Button {
                model.advancePlaylist(by: -1)
            } label: {
                Text("command.previous")
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!model.canPlayPlaylist)

            Button {
                model.advancePlaylist(by: 1)
            } label: {
                Text("command.next")
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!model.canPlayPlaylist)

            Divider()

            Button {
                model.isSettingsPresented = true
            } label: {
                Text("settings.title")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
