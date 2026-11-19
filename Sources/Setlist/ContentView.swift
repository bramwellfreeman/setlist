import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Formatting helpers

func fmtTime(_ s: Double) -> String {
    let v = max(0, Int(s.rounded()))
    return String(format: "%d:%02d", v / 60, v % 60)
}
func fmtGain(_ db: Double) -> String {
    String(format: "%+.1f dB", db)
}

/// Shared drop handler: resolve dropped file URLs, then add them.
func loadDroppedURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    let group = DispatchGroup(); var urls: [URL] = []; let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { u, _ in
            if let u { lock.lock(); urls.append(u); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { if !urls.isEmpty { done(urls) } }
}

// MARK: - Root

/// Minimal, browser-like layout: playlists as soft pills down the left, faint
/// utility icons top-right, a quiet centered track column, and a
/// floating transport card.
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var shortcuts: ShortcutStore
    @State private var advancedTrackID: UUID?
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            PlaylistSidebar()
                .frame(width: 210)
            VStack(spacing: 0) {
                TopBar()
                    .zIndex(1)          // hover hints draw over the content below
                ZStack(alignment: .bottom) {
                    MainPane(advancedTrackID: $advancedTrackID)
                    TransportCard()
                        .padding(.horizontal, 24)
                        .padding(.bottom, 22)
                }
            }
        }
        .background(Theme.paper)
        .ignoresSafeArea(.container, edges: .top)   // tabs share the traffic-light row
        .background(WindowConfigurator())
        .onAppear {
            guard keyMonitor == nil else { return }
            let st = state, sc = shortcuts
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                routePlaybackKey(event, state: st, shortcuts: sc)
            }
            SelfTest.runIfRequested(state: st, shortcuts: sc)
        }
        .sheet(item: Binding(
            get: { advancedTrackID.map { IDWrap(id: $0) } },
            set: { advancedTrackID = $0?.id })
        ) { wrap in
            if let plID = state.selectedPlaylistID {
                AdvancedTrackSheet(trackID: wrap.id, playlistID: plID)
                    .environmentObject(state)
            }
        }
    }
}

private struct IDWrap: Identifiable { let id: UUID }

/// Lets the empty white areas drag the window (there's no visible title bar).
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.isMovableByWindowBackground = true
            v.window?.titlebarSeparatorStyle = .none
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 12)
            if let pl = state.selected { UtilityIcons(playlist: pl) }
        }
        .padding(.trailing, 14)
        .frame(height: 30)
        .padding(.top, 12)          // level with the sidebar logo
    }
}

/// Playlists as a quiet vertical list of soft pills, below the traffic lights.
struct PlaylistSidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Logo on the traffic-light row, right-aligned above the playlists.
            HStack {
                Spacer()
                HStack(spacing: 12) {
                    SetlistMark(size: 20)
                    Rectangle().fill(Theme.line).frame(width: 1, height: 22)
                    Text("Setlist")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.ink)
                }
            }
            .frame(height: 30)
            .padding(.top, 12)
            .padding(.trailing, 4)
            .padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.sidebarRows) { row in
                        PlaylistTab(playlist: row.playlist, depth: row.depth, hasChildren: row.hasChildren)
                    }
                    TopLevelDropZone()
                }
            }
            Button { state.addPlaylist() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 12))
                    Text("New Playlist").font(.system(size: 13))
                }
                .foregroundStyle(Theme.faintIcon)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 18)
            .opacity(state.showLocked ? 0 : 1)
            .disabled(state.showLocked)
        }
        .padding(.top, 0)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Small soft label that fades in after resting the pointer on a control for
/// a moment — quicker and quieter than the system tooltip.
struct HoverHint: ViewModifier {
    let text: String
    var edge: VerticalEdge = .bottom
    var align: HorizontalAlignment = .center
    @State private var shown = false
    @State private var pending: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    let work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.12)) { shown = true } }
                    pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
                } else {
                    withAnimation(.easeOut(duration: 0.08)) { shown = false }
                }
            }
            .simultaneousGesture(TapGesture().onEnded { pending?.cancel(); shown = false })
            // A zero-height strip pinned to the control's top/bottom edge; the
            // label hangs off it outward, so it sits just above/below the control.
            .overlay(alignment: edge == .bottom ? .bottom : .top) {
                Color.clear.frame(height: 0)
                    .overlay(alignment: Alignment(horizontal: align, vertical: edge == .bottom ? .top : .bottom)) {
                        if shown && !text.isEmpty {
                            label
                                .padding(edge == .bottom ? .top : .bottom, 6)
                                .transition(.opacity)
                        }
                    }
                    .allowsHitTesting(false)
            }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .fixedSize()
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.paper)
                    .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1)
            )
    }
}

extension View {
    func hoverHint(_ text: String, edge: VerticalEdge = .bottom,
                   align: HorizontalAlignment = .center) -> some View {
        modifier(HoverHint(text: text, edge: edge, align: align))
    }
}

/// Faint icon button, like the browser's back/forward/reload glyphs.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var hintEdge: VerticalEdge = .bottom
    var hintAlign: HorizontalAlignment = .center
    var active: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 28)
                .foregroundStyle(active ? Theme.ink : (hovering ? Theme.ink : Theme.faintIcon))
                .background(hovering ? Theme.hover : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverHint(help, edge: hintEdge, align: hintAlign)
    }
}

/// Drag payload for a track row (plain text so it survives NSItemProvider).
let trackDragPrefix = "setlist-track:"
/// Playlists drag as a URL so the drop target can tell them apart from tracks
/// (plain text) while hovering, before the payload is loaded.
func playlistDragURL(_ id: UUID) -> URL { URL(string: "setlist-playlist://\(id.uuidString)")! }
func playlistID(fromDrag url: URL) -> UUID? {
    url.scheme == "setlist-playlist" ? url.host.flatMap(UUID.init(uuidString:)) : nil
}

/// Drop handling for a sidebar pill: tracks always move *into* it; playlists go
/// before / into / after depending on where over the pill they're released.
struct PlaylistDropDelegate: DropDelegate {
    let state: AppState
    let target: UUID
    let height: CGFloat
    @Binding var zone: AppState.DropPlacement?

    private func placement(_ info: DropInfo) -> AppState.DropPlacement {
        guard info.hasItemsConforming(to: [.url]) else { return .into }   // a track
        let y = info.location.y
        if y < height * 0.28 { return .before }
        if y > height * 0.72 { return .after }
        return .into
    }

    func validateDrop(info: DropInfo) -> Bool {
        !state.showLocked && info.hasItemsConforming(to: [.url, .plainText])
    }
    func dropEntered(info: DropInfo) { zone = placement(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = placement(info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let where_ = placement(info)
        zone = nil
        if let p = info.itemProviders(for: [.url]).first {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let id = playlistID(fromDrag: url) else { return }
                DispatchQueue.main.async { state.movePlaylist(id, relativeTo: target, where_) }
            }
            return true
        }
        if let p = info.itemProviders(for: [.plainText]).first {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let str = obj as? String, str.hasPrefix(trackDragPrefix),
                      let id = UUID(uuidString: String(str.dropFirst(trackDragPrefix.count))) else { return }
                DispatchQueue.main.async { state.moveTrack(id, to: target) }
            }
            return true
        }
        return false
    }
}

struct PlaylistTab: View {
    @EnvironmentObject var state: AppState
    let playlist: Playlist
    var depth: Int = 0
    var hasChildren: Bool = false
    @State private var hovering = false
    @State private var dropZone: AppState.DropPlacement?
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isSelected: Bool { state.selectedPlaylistID == playlist.id }
    private var isPlaying: Bool { state.playingPlaylistID == playlist.id && state.audio.isPlaying }

    var body: some View {
        HStack(spacing: 6) {
            if hasChildren {
                Button { state.toggleCollapsed(playlist.id) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(playlist.collapsed ? 0 : 90))
                        .frame(width: 12, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.faintIcon)
            } else if depth > 0 || state.playlists.contains(where: { $0.parentID != nil }) {
                Color.clear.frame(width: 12)
            }
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .onAppear { focused = true }
                    .frame(minWidth: 80)
            } else {
                // A real button selects on the first click (no double-click
                // wait); double-click renames.
                Button { state.selectPlaylist(playlist.id) } label: {
                    HStack(spacing: 6) {
                        if isPlaying {
                            Circle().fill(Theme.blue).frame(width: 5, height: 5)
                        }
                        Text(playlist.name.isEmpty ? "Untitled" : playlist.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if !state.showLocked { draft = playlist.name; editing = true }
                })
            }
        }
        .font(.system(size: depth > 0 ? 12.5 : 13))
        .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
        .padding(.leading, hasChildren || depth > 0 || state.playlists.contains(where: { $0.parentID != nil }) ? 6 : 12)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 30)
        .background(isSelected ? Theme.tab : (hovering ? Theme.hover : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.blue, lineWidth: dropZone == .into ? 1.5 : 0)
        )
        // insertion line for before/after
        .overlay(alignment: dropZone == .after ? .bottom : .top) {
            if dropZone == .before || dropZone == .after {
                Capsule().fill(Theme.blue).frame(height: 2)
                    .offset(y: dropZone == .after ? 2 : -2)
            }
        }
        .background(GeometryReader { g in
            Color.clear.onAppear { SelfTest.pillFrames[playlist.name] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in SelfTest.pillFrames[playlist.name] = f }
        })
        .padding(.leading, CGFloat(depth) * 16)
        .onDrop(of: [.url, .plainText],
                delegate: PlaylistDropDelegate(state: state, target: playlist.id, height: 30, zone: $dropZone))
        .modifier(PlaylistDragSource(id: playlist.id, enabled: !state.showLocked && !editing))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if !state.showLocked {
                Button("Rename") { state.selectPlaylist(playlist.id); draft = playlist.name; editing = true }
                Button("New Sub-playlist") { state.addPlaylist(parent: playlist.id) }
                let family = state.descendants(of: playlist.id)
                Menu("Move Into") {
                    if playlist.parentID != nil {
                        Button("Top Level") { state.reparent(playlist.id, to: nil) }
                        Divider()
                    }
                    ForEach(state.playlists.filter { !family.contains($0.id) && $0.id != playlist.parentID }) { p in
                        Button(state.path(of: p.id)) { state.reparent(playlist.id, to: p.id) }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { state.deletePlaylist(playlist.id) }
            }
        }
        .help("Double-click to rename")
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let n = draft.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { state.renamePlaylist(playlist.id, to: n) }
    }
}

/// Makes a sidebar pill draggable (off while locked or renaming).
private struct PlaylistDragSource: ViewModifier {
    let id: UUID
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { NSItemProvider(object: playlistDragURL(id) as NSURL) }
        } else {
            content
        }
    }
}

/// Empty space under the playlists: dropping a playlist here moves it to the
/// end of the top level (out of any sub-list).
private struct TopLevelDropZone: View {
    @EnvironmentObject var state: AppState
    @State private var targeted = false
    var body: some View {
        Rectangle().fill(Color.clear)
            .frame(maxWidth: .infinity, minHeight: 60)
            .overlay(alignment: .top) {
                if targeted { Capsule().fill(Theme.blue).frame(height: 2).padding(.horizontal, 4) }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.url], isTargeted: $targeted) { providers in
                guard !state.showLocked, let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let id = playlistID(fromDrag: url) else { return }
                    DispatchQueue.main.async { state.movePlaylist(id, relativeTo: nil, .after) }
                }
                return true
            }
    }
}

struct UtilityIcons: View {
    @EnvironmentObject var state: AppState
    let playlist: Playlist

    private let targets: [(String, Double)] = [
        ("EBU R128  −23 LUFS", -23), ("Broadcast  −18 LUFS", -18),
        ("Streaming  −16 LUFS", -16), ("Loud  −14 LUFS", -14)
    ]

    var body: some View {
        HStack(spacing: 2) {
            if state.showLocked {
                Text("SHOW LOCKED").font(.system(size: 10, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Theme.blue).padding(.trailing, 6)
            } else {
                editingIcons
            }
            IconButton(symbol: state.showLocked ? "lock.fill" : "lock.open",
                       help: state.showLocked ? "Unlock show (allow editing)" : "Lock show (transport only)",
                       hintAlign: .trailing, active: state.showLocked) { state.showLocked.toggle() }
        }
    }

    @ViewBuilder private var editingIcons: some View {
            IconButton(symbol: "plus.square", help: "Add tracks", hintAlign: .trailing) { state.pickAndAddTracks() }
            IconButton(symbol: state.analyzingAll ? "hourglass" : "waveform.path.ecg",
                       help: state.analyzingAll ? "Analyzing…" : "Analyze & match loudness",
                       hintAlign: .trailing) { state.analyzeAllAndMatch() }
                .disabled(state.analyzingAll || playlist.tracks.isEmpty)
            Menu {
                Section("Loudness") {
                    Toggle("Match loudness", isOn: Binding(
                        get: { playlist.matchEnabled }, set: { state.setMatchEnabled($0) }))
                    Picker("Target", selection: Binding(
                        get: { playlist.targetLUFS }, set: { state.setTarget($0) })) {
                        ForEach(targets, id: \.1) { Text($0.0).tag($0.1) }
                    }
                }
                Section("Space while playing") {
                    Picker("Space", selection: Binding(
                        get: { playlist.spaceStopsAndCues }, set: { state.setSpaceStops($0) })) {
                        Text("Pause / resume").tag(false)
                        Text("Stop & cue next track").tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Picker("Fade out on stop", selection: Binding(
                        get: { playlist.fadeOutSeconds }, set: { v in state.updateSelected { $0.fadeOutSeconds = v } })) {
                        Text("No fade").tag(0.0)
                        ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                }
                Section("When a track ends") {
                    Picker("When a track ends", selection: Binding(
                        get: { playlist.continueMode == .crossfade ? "x\(Int(playlist.crossfadeSeconds))" : playlist.continueMode.rawValue },
                        set: { v in state.updateSelected { pl in
                            if v.hasPrefix("x") { pl.continueMode = .crossfade; pl.crossfadeSeconds = Double(v.dropFirst()) ?? 4 }
                            else { pl.continueMode = ContinueMode(rawValue: v) ?? .cue }
                        } })) {
                        Text("Stop & cue next").tag("cue")
                        Text("Play next — gapless").tag("gapless")
                        ForEach([2, 4, 6, 8], id: \.self) { Text("Play next — crossfade \($0) s").tag("x\($0)") }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Output") {
                    let devices = AudioController.outputDevices()
                    Picker("Output", selection: Binding(
                        get: { playlist.outputDeviceUID ?? "" },
                        set: { uid in state.setOutputDevice(devices.first { $0.uid == uid }) })) {
                        Text("System default").tag("")
                        ForEach(devices) { Text($0.name).tag($0.uid) }
                        if let uid = playlist.outputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
                            Text("\(playlist.outputDeviceName ?? "Device") (not connected)").tag(uid)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Divider()
                Button("Find Missing Files…") { state.findMissingFiles() }
                Button("Import Playlist…") { state.importPlaylists() }
                Button("Export Playlist…") { state.exportSelected() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faintIcon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 28, height: 28)
            .hoverHint("Playlist options", align: .trailing)
    }
}

// MARK: - Main pane

struct MainPane: View {
    @EnvironmentObject var state: AppState
    @Binding var advancedTrackID: UUID?

    var body: some View {
        if let pl = state.selected {
            if pl.tracks.isEmpty {
                EmptyDrop(playlistID: pl.id)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Header(playlist: pl)
                    TrackListView(playlist: pl, advancedTrackID: $advancedTrackID)
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            Color.clear
        }
    }
}

struct Header: View {
    @EnvironmentObject var state: AppState
    let playlist: Playlist
    @State private var editingNotes = false
    @State private var draftNotes = ""
    @FocusState private var notesFocused: Bool

    /// Playlist notes: plain text until clicked (an always-live field would grab
    /// focus at launch and eat Space).
    @ViewBuilder private var notes: some View {
        if editingNotes {
            TextField("Notes for this playlist", text: $draftNotes, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...8)
                .focused($notesFocused)
                .onExitCommand { commitNotes() }
                .onChange(of: notesFocused) { _, f in if !f { commitNotes() } }
                .onAppear { notesFocused = true }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover))
        } else if !playlist.notes.isEmpty {
            Text(playlist.notes)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.faint))
                .contentShape(Rectangle())
                .onTapGesture { startNotes() }
        } else if !state.showLocked {
            Text("Add notes…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.placeholder)
                .contentShape(Rectangle())
                .onTapGesture { startNotes() }
        }
    }

    private func startNotes() {
        guard !state.showLocked else { return }
        draftNotes = playlist.notes
        editingNotes = true
    }

    private func commitNotes() {
        guard editingNotes else { return }
        editingNotes = false
        let text = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = state.playlists.firstIndex(where: { $0.id == playlist.id }) {
            state.playlists[i].notes = text
            state.save()
        }
    }

    private var meta: String {
        var parts = ["\(playlist.tracks.count) track\(playlist.tracks.count == 1 ? "" : "s")",
                     fmtTime(playlist.totalDuration)]
        if playlist.matchEnabled { parts.append("matched to \(Int(playlist.targetLUFS)) LUFS") }
        if playlist.spaceStopsAndCues { parts.append("space stops & cues") }
        switch playlist.continueMode {
        case .cue: break
        case .gapless: parts.append("gapless")
        case .crossfade: parts.append("crossfade \(Int(playlist.crossfadeSeconds)) s")
        }
        if let dev = playlist.outputDeviceName, playlist.outputDeviceUID != nil { parts.append("→ \(dev)") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(playlist.name.isEmpty ? "Untitled" : playlist.name)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 10) {
                Text(meta).font(.system(size: 12)).foregroundStyle(Theme.muted)
                if !state.status.isEmpty {
                    Text(state.status).font(.system(size: 12)).foregroundStyle(Theme.blue).lineLimit(1)
                }
            }
            notes.padding(.top, 6)
        }
        .padding(.horizontal, 28)
        .padding(.top, 44)
        .padding(.bottom, 16)
    }
}

// MARK: - Track list

struct TrackListView: View {
    @EnvironmentObject var state: AppState
    let playlist: Playlist
    @Binding var advancedTrackID: UUID?

    /// Native List selection drives `selectedTrackID` — reliable click/arrow-key
    /// selection (custom tap gestures inside a List mis-hit rows).
    private var selection: Binding<UUID?> {
        Binding(get: { state.selectedTrackID }, set: { state.selectedTrackID = $0 })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(playlist.tracks) { track in
                TrackRow(track: track, playlist: playlist, advancedTrackID: $advancedTrackID)
                    .tag(track.id)
                    // Drag a row onto a sidebar playlist to move it there.
                    .itemProvider(state.showLocked ? nil : {
                        NSItemProvider(object: (trackDragPrefix + track.id.uuidString) as NSString)
                    })
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 16, bottom: 1, trailing: 16))
            }
            .onMove(perform: state.showLocked ? nil : { from, to in
                state.moveTracks(in: playlist.id, from: from, to: to)
            })
            // Room so the last rows can scroll clear of the floating transport.
            Color.clear.frame(height: 110).listRowSeparator(.hidden).selectionDisabled()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.paper)
        .background(QuietSelection())
        // Double-click / Return plays; right-click shows the track menu.
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !state.showLocked, let id = ids.first, let track = playlist.tracks.first(where: { $0.id == id }) {
                trackMenu(track)
            }
        } primaryAction: { ids in
            // Locked: double-click only cues (selects); Space/Play starts it.
            if !state.showLocked, let id = ids.first { state.playTrack(id, inPlaylist: playlist.id) }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard !state.showLocked else { return false }
            loadDroppedURLs(providers) { state.addTracks($0, toPlaylist: playlist.id) }
            return true
        }
    }

    @ViewBuilder private func trackMenu(_ track: Track) -> some View {
        if track.sourceMissing {
            Button(track.isVideo ? "Locate Video…" : "Locate File…") { state.locateTrack(track.id, in: playlist.id) }
            Divider()
        }
        Button("Play") { state.playTrack(track.id, inPlaylist: playlist.id) }
        Button("Play Next") { state.moveToPlayNext(track.id) }
        Menu("Move to") {
            ForEach(state.sidebarOrderAll.filter { $0.id != playlist.id }) { p in
                Button(state.path(of: p.id)) { state.moveTrack(track.id, to: p.id) }
            }
        }
        Divider()
        Button("Analyze Loudness") { state.analyzeTrack(track.id, in: playlist.id) }
        Button(track.skip ? "Include in Queue" : "Skip in Queue") {
            state.updateTrack(track.id, in: playlist.id) { $0.skip.toggle() }
        }
        Button(track.notes.isEmpty ? "Add Note…" : "Edit Note…") { advancedTrackID = track.id }
        Button("Advanced…") { advancedTrackID = track.id }
        Divider()
        Button("Remove", role: .destructive) { state.removeTrack(track.id, from: playlist.id) }
    }
}

/// Turns off the table's accent-blue selection fill; rows draw their own soft
/// grey selection instead, to match the quiet look.
private struct QuietSelection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        func apply(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let root = v.window?.contentView else { if tries > 0 { apply(tries - 1) }; return }
                for tv in tables(in: root) { tv.selectionHighlightStyle = .none }
            }
        }
        apply(20)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let root = nsView.window?.contentView else { return }
            for tv in tables(in: root) where tv.selectionHighlightStyle != .none { tv.selectionHighlightStyle = .none }
        }
    }
    private func tables(in v: NSView) -> [NSTableView] {
        (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables)
    }
}

struct EmptyDrop: View {
    @EnvironmentObject var state: AppState
    let playlistID: UUID
    @State private var targeted = false

    var body: some View {
        // The floating "address bar" — click to add, or drop files anywhere.
        VStack(spacing: 34) {
        SetlistMark(size: 40)
        Button { state.pickAndAddTracks() } label: {
            HStack {
                Text(targeted ? "Release to add" : "Drop audio files, or click to add")
                    .font(.system(size: 17))
                    .foregroundStyle(targeted ? Theme.ink : Theme.placeholder)
                Spacer()
            }
            .padding(.horizontal, 26)
            .frame(height: 60)
            .frame(maxWidth: 700)
            .floatingCard(radius: 14)
        }
        .buttonStyle(.plain)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            guard !state.showLocked else { return false }
            loadDroppedURLs(providers) { state.addTracks($0, toPlaylist: playlistID) }
            return true
        }
    }
}

struct TrackRow: View {
    @EnvironmentObject var state: AppState
    let track: Track
    let playlist: Playlist
    @Binding var advancedTrackID: UUID?
    @State private var hovering = false

    private var isCurrent: Bool { state.audio.currentTrackID == track.id && state.playingPlaylistID == playlist.id }
    private var isPlaying: Bool { isCurrent && state.audio.isPlaying }
    private var isSelected: Bool { state.selectedTrackID == track.id }
    private var isCued: Bool { state.cuedTrack?.id == track.id }

    private var rowBackground: Color {
        if isSelected { return Theme.tab }
        if hovering { return Theme.hover }
        return .clear
    }
    private var index: Int { (playlist.tracks.firstIndex { $0.id == track.id } ?? 0) + 1 }
    private var effGain: Double { state.gain(for: track, in: playlist) }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(Theme.blue)
                } else if isCurrent {
                    Image(systemName: "pause.fill").font(.system(size: 10)).foregroundStyle(Theme.blue)
                } else if isCued {
                    Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(Theme.blue)
                } else {
                    Text("\(index)").font(.system(size: 12)).foregroundStyle(Theme.placeholder)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(track.displayTitle)
                        .font(.system(size: 14))
                        .foregroundStyle(track.skip ? Theme.placeholder : (isCurrent ? Theme.blue : Theme.ink))
                        .strikethrough(track.skip)
                        .lineLimit(1)
                    if track.isVideo {
                        Image(systemName: "film")
                            .font(.system(size: 10)).foregroundStyle(Theme.faintIcon)
                            .help("Audio from video: \(track.sourceURL.lastPathComponent)")
                    }
                    if state.extractingTracks.contains(track.id) {
                        ProgressView().controlSize(.mini)
                        Text("Extracting audio…").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    } else if track.sourceMissing {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10)).foregroundStyle(.orange).help("File not found")
                    }
                }
                if !track.artist.isEmpty {
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                if !track.notes.isEmpty {
                    Label(track.notes, systemImage: "text.bubble")
                        .labelStyle(NoteLabelStyle())
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if state.analyzingTracks.contains(track.id) {
                ProgressView().controlSize(.mini)
            } else if let lu = track.integratedLUFS {
                Text(String(format: "%.1f LUFS", lu))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.placeholder)
            }
            if effGain != 0 {
                Text(fmtGain(effGain))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                    .frame(width: 58, alignment: .trailing)
            }
            Text(fmtTime(track.playableDuration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .frame(width: 40, alignment: .trailing)

            Button { advancedTrackID = track.id } label: {
                Image(systemName: "ellipsis").font(.system(size: 12))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.faintIcon)
            .opacity((hovering || isSelected) && !state.showLocked ? 1 : 0)
            .disabled(state.showLocked)
            .help("Track settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Transport

struct TransportCard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var shortcuts: ShortcutStore
    @State private var showLevels = false

    private var audio: AudioController { state.audio }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 2) {
                IconButton(symbol: "backward.fill", help: "Previous  \(shortcuts.display(.previous))", hintEdge: .top) { state.previous() }
                Button { state.togglePlayPause() } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Theme.ink)
                        .foregroundStyle(.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .hoverHint(audio.isPlaying ? "Pause  \(shortcuts.display(.playPause))"
                                           : "Play  \(shortcuts.display(.playPause))", edge: .top)
                IconButton(symbol: "forward.fill", help: "Next  \(shortcuts.display(.next))", hintEdge: .top) { state.next() }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let cur = state.currentTrack {
                        Text(cur.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if !cur.notes.isEmpty {
                            Label(cur.notes, systemImage: "text.bubble").labelStyle(NoteLabelStyle()).lineLimit(1)
                        }
                        if audio.isFading {
                            Text("fading out…").font(.system(size: 11)).foregroundStyle(Theme.blue)
                        }
                        if let up = state.upNextTrack {
                            Text("next  \(up.displayTitle)").font(.system(size: 11))
                                .foregroundStyle(Theme.placeholder).lineLimit(1)
                        }
                    } else if let cued = state.cuedTrack {
                        Text(cued.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if !cued.notes.isEmpty {
                            Label(cued.notes, systemImage: "text.bubble").labelStyle(NoteLabelStyle()).lineLimit(1)
                        }
                        Text("cued · \(shortcuts.display(.playPause)) to play").font(.system(size: 11))
                            .foregroundStyle(Theme.blue).lineLimit(1)
                    } else {
                        Text("Nothing playing").font(.system(size: 13)).foregroundStyle(Theme.placeholder)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Text(fmtTime(audio.currentTime - audio.segmentStart))
                        .frame(width: 34, alignment: .leading)
                    WaveformScrubber(track: state.currentTrack,
                                     position: audio.currentTime,
                                     start: audio.segmentStart,
                                     end: audio.segmentEnd) { state.seek(to: $0) }
                        .frame(height: 30)
                    Text("-" + fmtTime(max(0, audio.segmentEnd - audio.currentTime)))
                        .frame(width: 40, alignment: .trailing)
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.placeholder)
            }
            .frame(minWidth: 240)

            IconButton(symbol: audio.masterVolume == 0 ? "speaker.slash" : "speaker.wave.2",
                       help: "Volume", hintEdge: .top, hintAlign: .trailing, active: showLevels) { showLevels.toggle() }
                .popover(isPresented: $showLevels, arrowEdge: .top) { levels }
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 760)
        .floatingCard(radius: 16)
    }


    private var levels: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Track").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(fmtGain(state.currentTrack?.gainDB ?? 0)).font(.system(size: 11).monospacedDigit())
                }
                Slider(value: Binding(
                    get: { state.currentTrack?.gainDB ?? 0 },
                    set: { v in
                        guard let t = state.currentTrack, let pl = state.playingPlaylistID else { return }
                        state.updateTrack(t.id, in: pl) { $0.gainDB = v }
                    }), in: -12...12, step: 0.5)
                .controlSize(.small).tint(Theme.ink)
                .disabled(state.currentTrack == nil)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Master").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(Int(audio.masterVolume * 100))%").font(.system(size: 11).monospacedDigit())
                }
                Slider(value: Binding(get: { audio.masterVolume }, set: { audio.masterVolume = $0 }), in: 0...1)
                    .controlSize(.small).tint(Theme.ink)
            }
        }
        .padding(16)
        .frame(width: 220)
    }
}

// MARK: - Advanced track sheet

struct AdvancedTrackSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID
    let playlistID: UUID

    private var track: Track? {
        state.playlists.first { $0.id == playlistID }?.tracks.first { $0.id == trackID }
    }
    private var playlist: Playlist? { state.playlists.first { $0.id == playlistID } }
    private var isCurrent: Bool { state.audio.currentTrackID == trackID }

    var body: some View {
        if let t = track, let pl = playlist {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Track Settings").caps(10)
                        Text(t.displayTitle).font(.system(size: 18, weight: .bold)).lineLimit(1)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 20)

                field("Title") {
                    TextField("Title", text: bind(\.title)).textFieldStyle(.roundedBorder)
                }
                field("Artist") {
                    TextField("Artist", text: bind(\.artist)).textFieldStyle(.roundedBorder)
                }
                field("Note") {
                    TextField("e.g. wait for the bow · page turn at 1:20", text: bind(\.notes), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                }
                if let video = t.videoPath {
                    HStack(spacing: 8) {
                        Image(systemName: "film").foregroundStyle(Theme.muted)
                        Text("Audio from \(URL(fileURLWithPath: video).lastPathComponent)")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Show Video") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: video)])
                        }
                        .buttonStyle(PillButtonStyle())
                        .disabled(!FileManager.default.fileExists(atPath: video))
                    }
                }

                Divider().overlay(Theme.line).padding(.vertical, 16)

                // Gain
                labeledRow("Track Gain", value: fmtGain(t.gainDB)) {
                    Slider(value: bindD(\.gainDB), in: -12...12, step: 0.5).tint(Theme.blue)
                }

                // Trim — drag the handles on the waveform
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Play Range").caps(10)
                        Spacer()
                        Text("\(fmtTime(t.trimStart)) – \(fmtTime(t.effectiveEnd))  ·  \(fmtTime(t.playableDuration))")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.ink)
                    }
                    WaveformTrimmer(track: t, position: isCurrent ? state.audio.currentTime : nil,
                                    onStart: { v in update { $0.trimStart = max(0, v) } },
                                    onEnd: { v in update { $0.trimEnd = min(t.duration, v) } })
                        .frame(height: 64)
                        .disabled(state.showLocked)
                    HStack(spacing: 8) {
                        Button("Start = now") { setStartToNow() }.buttonStyle(PillButtonStyle()).disabled(!isCurrent)
                        Button("End = now") { setEndToNow() }.buttonStyle(PillButtonStyle()).disabled(!isCurrent)
                        Spacer()
                        Button("Reset") { update { $0.trimStart = 0; $0.trimEnd = $0.duration } }
                            .buttonStyle(PillButtonStyle())
                    }
                }

                Divider().overlay(Theme.line).padding(.vertical, 16)

                // Loudness + skip
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Integrated Loudness").caps(10)
                        Text(t.integratedLUFS.map { String(format: "%.1f LUFS", $0) } ?? "Not analyzed")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        if pl.matchEnabled, t.integratedLUFS != nil {
                            Text("Match gain \(fmtGain(t.normalizationGainDB))").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                    Button {
                        state.analyzeTrack(trackID, in: playlistID)
                    } label: {
                        if state.analyzingTracks.contains(trackID) { Label("Analyzing…", systemImage: "waveform") }
                        else { Label("Analyze", systemImage: "waveform.path.ecg") }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(state.analyzingTracks.contains(trackID))
                }

                Toggle(isOn: Binding(get: { t.skip }, set: { v in update { $0.skip = v } })) {
                    Text("Skip this track in the queue").font(.system(size: 13))
                }
                .toggleStyle(.switch)
                .tint(Theme.blue)
                .padding(.top, 14)

                Spacer()

                HStack {
                    Button { state.playTrack(trackID, inPlaylist: playlistID) } label: {
                        Label("Play From Start", systemImage: "play.fill")
                    }.buttonStyle(PillButtonStyle(accent: true))
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(PillButtonStyle(active: true))
                }
                .padding(.top, 16)
            }
            .padding(26)
            .frame(width: 520, height: 680)
            .background(Theme.paper)
        } else {
            Color.clear.frame(width: 460, height: 200).onAppear { dismiss() }
        }
    }

    // helpers
    private func update(_ mutate: (inout Track) -> Void) { state.updateTrack(trackID, in: playlistID, mutate) }
    private func bind(_ kp: WritableKeyPath<Track, String>) -> Binding<String> {
        Binding(get: { track?[keyPath: kp] ?? "" }, set: { v in update { $0[keyPath: kp] = v } })
    }
    private func bindD(_ kp: WritableKeyPath<Track, Double>) -> Binding<Double> {
        Binding(get: { track?[keyPath: kp] ?? 0 }, set: { v in update { $0[keyPath: kp] = v } })
    }
    private func setStartToNow() { update { $0.trimStart = min(state.audio.currentTime, $0.effectiveEnd - 0.1) } }
    private func setEndToNow() { update { $0.trimEnd = max(state.audio.currentTime, $0.trimStart + 0.1) } }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).caps(10); content() }.padding(.bottom, 12)
    }
    private func labeledRow<C: View>(_ label: String, value: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(label).caps(10); Spacer(); Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink) }
            content()
        }.padding(.bottom, 14)
    }
}

/// Small blue cue-note label: bubble icon + text.
struct NoteLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon.font(.system(size: 9))
            configuration.title.font(.system(size: 11.5))
        }
        .foregroundStyle(Theme.blue)
    }
}
