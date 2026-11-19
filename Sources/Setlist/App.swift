import SwiftUI

@main
struct SetlistApp: App {
    @StateObject private var state = AppState()
    @StateObject private var shortcuts = ShortcutStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(shortcuts)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(.light)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Playlist") { state.addPlaylist() }
                    .modifier(ApplyShortcut(shortcuts.chord(for: .newPlaylist)))
                Button("Add Tracks…") { state.pickAndAddTracks() }
                    .modifier(ApplyShortcut(shortcuts.chord(for: .addTracks)))
                Divider()
                Button("Import Playlist…") { state.importPlaylists() }
                    .modifier(ApplyShortcut(shortcuts.chord(for: .importPlaylist)))
                Button("Export Playlist…") { state.exportSelected() }
                    .modifier(ApplyShortcut(shortcuts.chord(for: .exportPlaylist)))
            }
            // Playback keys are handled by a local event monitor (see ContentView),
            // which is reliable for no-modifier keys like Space. Menu items stay
            // clickable; their shortcut hints are shown in Settings → Shortcuts.
            CommandMenu("Playback") {
                Button("Play / Pause  (\(shortcuts.display(.playPause)))") { state.togglePlayPause() }
                Button("Next  (\(shortcuts.display(.next)))") { state.next() }
                Button("Previous  (\(shortcuts.display(.previous)))") { state.previous() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(shortcuts)
        }
    }
}
