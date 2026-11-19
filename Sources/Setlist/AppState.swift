import SwiftUI
import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers
import IOKit.pwr_mgt

/// Owns the playlist library, playback coordination, loudness analysis, and I/O.
/// The playlist order *is* the queue, so reordering/deleting on the fly updates
/// what plays next automatically.
final class AppState: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var selectedPlaylistID: UUID?
    @Published var selectedTrackID: UUID?          // highlighted row in the current playlist
    @Published var playingPlaylistID: UUID?
    @Published var analyzingTracks: Set<UUID> = []
    @Published var analyzingAll = false
    @Published var extractingTracks: Set<UUID> = []   // video tracks whose audio is being pulled out
    @Published var status: String = ""
    /// Show lock: only the transport and track selection respond — no edits,
    /// reordering, deleting, or double-click starts.
    @Published var showLocked: Bool = UserDefaults.standard.bool(forKey: "showLocked") {
        didSet { UserDefaults.standard.set(showLocked, forKey: "showLocked"); updateKeepAwake() }
    }

    let audio = AudioController()
    private var cancellables = Set<AnyCancellable>()
    private var handoffFrom: UUID?           // track we've already started the next one from
    private var sleepAssertion: IOPMAssertionID = 0

    init() {
        load()
        if playlists.isEmpty { playlists = [Playlist(name: "New Playlist")] }
        selectedPlaylistID = playlists.first?.id
        // When a track finishes, cue the next one (ready to play) rather than
        // auto-starting it — a recital-friendly hand-off.
        rebuildMissingExtractions()
        audio.onFinished = { [weak self] in self?.trackFinished() }
        audio.onTick = { [weak self] remaining in self?.handleTick(remaining) }
        audio.$hasSegment
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateKeepAwake() } }
            .store(in: &cancellables)
        // The audio engine is a nested ObservableObject; forward its changes so
        // views observing AppState (transport button, scrubber, row highlight)
        // refresh when playback state changes.
        audio.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Selection / lookups

    var selectedIndex: Int? { playlists.firstIndex { $0.id == selectedPlaylistID } }
    var selected: Playlist? { selectedIndex.map { playlists[$0] } }
    var playingIndex: Int? { playlists.firstIndex { $0.id == playingPlaylistID } }

    var currentTrack: Track? {
        guard let id = audio.currentTrackID, let i = playingIndex else { return nil }
        return playlists[i].tracks.first { $0.id == id }
    }

    /// The track that Play will start when nothing is loaded — the selection
    /// (e.g. the track cued after the previous one finished).
    var cuedTrack: Track? {
        guard audio.currentTrackID == nil, let sid = selectedTrackID,
              let (pi, ti) = locate(sid) else { return nil }
        return playlists[pi].tracks[ti]
    }

    var upNextTrack: Track? {
        guard let id = audio.currentTrackID, let i = playingIndex,
              let idx = playlists[i].tracks.firstIndex(where: { $0.id == id }) else { return nil }
        return nextPlayable(in: playlists[i], after: idx)
    }

    /// (playlist index, track index) for a track id, preferring the viewed playlist.
    private func locate(_ trackID: UUID) -> (Int, Int)? {
        let order = [selectedIndex, playingIndex].compactMap { $0 } + Array(playlists.indices)
        for pi in order {
            if let ti = playlists[pi].tracks.firstIndex(where: { $0.id == trackID }) { return (pi, ti) }
        }
        return nil
    }

    private func isPlayable(_ t: Track) -> Bool { !t.skip && !t.fileMissing }

    private func nextPlayable(in pl: Playlist, after i: Int) -> Track? {
        pl.tracks.dropFirst(i + 1).first(where: isPlayable)
    }

    private func previousPlayable(in pl: Playlist, before i: Int) -> Track? {
        pl.tracks.prefix(max(0, i)).last(where: isPlayable)
    }

    func gain(for t: Track, in pl: Playlist) -> Double {
        t.gainDB + (pl.matchEnabled ? t.normalizationGainDB : 0)
    }

    // MARK: - Playback

    /// Start a track and move the row selection to it, so the highlight follows
    /// playback and Space keeps controlling the live track.
    func playTrack(_ id: UUID, inPlaylist plID: UUID) {
        guard let pi = playlists.firstIndex(where: { $0.id == plID }),
              let t = playlists[pi].tracks.first(where: { $0.id == id }) else { return }
        playingPlaylistID = plID
        selectedTrackID = id
        if t.fileMissing {
            status = "File not found: \(t.displayTitle)"
            return
        }
        audio.setOutputDevice(uid: resolvedDeviceUID(playlists[pi]))
        handoffFrom = nil
        if audio.play(track: t, gainDB: gain(for: t, in: playlists[pi])) {
            if status.hasPrefix("Can't") || status.hasPrefix("File not found") { status = "" }
        } else {
            status = "Can't play “\(t.displayTitle)” — the file couldn't be opened"
        }
    }

    /// Single toggle used by the transport button and the Play/Pause shortcut:
    /// pause if playing; start the selected track if it differs from the loaded
    /// one; resume if paused mid-track; otherwise start the first playable track.
    func togglePlayPause() {
        if audio.isFading {                     // second press during a fade: stop now
            audio.fadeOutAndStop(seconds: 0) {}
            return
        }
        if audio.isPlaying {
            if let pi = playingIndex, playlists[pi].spaceStopsAndCues {
                fadeOutThenCue(seconds: playlists[pi].fadeOutSeconds)
            } else {
                audio.pause()
            }
            return
        }
        if let sid = selectedTrackID, sid != audio.currentTrackID, let (pi, _) = locate(sid) {
            playTrack(sid, inPlaylist: playlists[pi].id)
            return
        }
        if audio.hasSegment { audio.resume() }
        else { playSelectedOrFirst() }
    }

    func playSelectedOrFirst() {
        if let sid = selectedTrackID, let (pi, _) = locate(sid) {
            playTrack(sid, inPlaylist: playlists[pi].id)
        } else if let pl = selected, let first = pl.tracks.first(where: isPlayable) {
            playTrack(first.id, inPlaylist: pl.id)
        } else if let pl = selected, !pl.tracks.isEmpty {
            status = "No playable tracks — files are missing or skipped"
        }
    }

    func playFromStart() { playSelectedOrFirst() }

    /// Fade the live track out (per the playlist's fade length), then stop and
    /// cue the next track.
    func fadeOutThenCue(seconds: Double) {
        guard audio.isPlaying else { cueNextTrack(); return }
        let id = audio.currentTrackID
        audio.fadeOutAndStop(seconds: seconds) { [weak self] in
            guard let self, self.audio.currentTrackID == id else { return }
            self.cueNextTrack()
        }
    }

    /// The playlist's continue mode drives what happens near/at a track's end.
    private func handleTick(_ remaining: Double) {
        guard audio.isPlaying, !audio.isFading, let pi = playingIndex,
              let id = audio.currentTrackID, handoffFrom != id,
              let idx = playlists[pi].tracks.firstIndex(where: { $0.id == id }),
              let next = nextPlayable(in: playlists[pi], after: idx) else { return }
        let pl = playlists[pi]
        switch pl.continueMode {
        case .cue:
            return
        case .crossfade:
            let x = min(pl.crossfadeSeconds, max(0.5, playlists[pi].tracks[idx].playableDuration / 2))
            guard remaining <= x else { return }
            handoffFrom = id
            if audio.crossfade(to: next, gainDB: gain(for: next, in: pl), seconds: x) {
                selectedTrackID = next.id
            }
        case .gapless:
            guard remaining <= 0.4 else { return }
            handoffFrom = id
            if audio.queueGapless(next, gainDB: gain(for: next, in: pl)) {
                selectedTrackID = next.id
            }
        }
    }

    private func trackFinished() {
        guard let pi = playingIndex else { cueNextTrack(); return }
        if playlists[pi].continueMode == .cue { cueNextTrack(); return }
        // Auto-continue modes normally hand off before the end; if that didn't
        // happen (very short track, seek past the window), start the next now.
        guard let id = audio.currentTrackID,
              let idx = playlists[pi].tracks.firstIndex(where: { $0.id == id }),
              let next = nextPlayable(in: playlists[pi], after: idx) else { cueNextTrack(); return }
        playTrack(next.id, inPlaylist: playlists[pi].id)
    }

    /// Called when a track finishes: stop and cue (select) the next playable
    /// track so it's ready, without auto-starting it.
    func cueNextTrack() {
        guard let pi = playingIndex, let id = audio.currentTrackID,
              let idx = playlists[pi].tracks.firstIndex(where: { $0.id == id }) else { audio.stop(); return }
        let next = nextPlayable(in: playlists[pi], after: idx)
        audio.stop()
        selectedTrackID = next?.id ?? id
        if next == nil { status = "End of playlist" }
    }

    /// Next: while a track is loaded, play the following one immediately;
    /// when idle, start the cued/selected track.
    func next() {
        guard let pi = playingIndex, let id = audio.currentTrackID,
              let idx = playlists[pi].tracks.firstIndex(where: { $0.id == id }) else {
            playSelectedOrFirst(); return
        }
        if let n = nextPlayable(in: playlists[pi], after: idx) {
            playTrack(n.id, inPlaylist: playlists[pi].id)
        } else {
            audio.stop()
            selectedTrackID = id
            status = "End of playlist"
        }
    }

    func previous() {
        if let pi = playingIndex, let id = audio.currentTrackID,
           let idx = playlists[pi].tracks.firstIndex(where: { $0.id == id }) {
            // More than 3s in → restart the current track.
            if audio.currentTime - audio.segmentStart > 3 || previousPlayable(in: playlists[pi], before: idx) == nil {
                playTrack(id, inPlaylist: playlists[pi].id)
            } else if let p = previousPlayable(in: playlists[pi], before: idx) {
                playTrack(p.id, inPlaylist: playlists[pi].id)
            }
            return
        }
        // Idle: move the cue back one track without starting playback.
        if let sid = selectedTrackID, let (pi, ti) = locate(sid),
           let p = previousPlayable(in: playlists[pi], before: ti) {
            selectedTrackID = p.id
        }
    }

    func seek(to absolute: Double) {
        guard let pi = playingIndex, let id = audio.currentTrackID,
              let t = playlists[pi].tracks.first(where: { $0.id == id }) else { return }
        audio.seek(toAbsolute: absolute, track: t, gainDB: gain(for: t, in: playlists[pi]))
    }

    /// Move a track to immediately after the currently playing one.
    func moveToPlayNext(_ id: UUID) {
        let pi = playingIndex ?? selectedIndex
        guard let i = pi, let from = playlists[i].tracks.firstIndex(where: { $0.id == id }) else { return }
        let t = playlists[i].tracks.remove(at: from)
        var insert = 0
        if let cur = audio.currentTrackID, let ci = playlists[i].tracks.firstIndex(where: { $0.id == cur }) {
            insert = ci + 1
        }
        playlists[i].tracks.insert(t, at: min(insert, playlists[i].tracks.count))
        save()
    }

    // MARK: - Track editing

    func addTracks(_ urls: [URL], toPlaylist plID: UUID? = nil) {
        guard let i = playlists.firstIndex(where: { $0.id == (plID ?? selectedPlaylistID) }) else { return }
        var added = 0
        var lastError = ""
        for url in urls {
            // Harmless for a non-sandboxed app; helps when access is scoped.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // macOS (AVFoundation) can't read these containers at all.
            if ["mkv", "webm", "avi", "flv", "wmv"].contains(url.pathExtension.lowercased()) {
                lastError = "\(url.lastPathComponent) — \(url.pathExtension.uppercased()) isn't supported by macOS; convert it to MP4 or MOV first"
                continue
            }
            if AudioExtractor.isVideo(url) {
                // Video: add now, pull the soundtrack out in the background.
                var t = Track(path: extractedURL(for: UUID()).path,
                              title: url.deletingPathExtension().lastPathComponent)
                t.videoPath = url.path
                playlists[i].tracks.append(t)
                startExtraction(t.id)
                added += 1
                continue
            }
            var dur = 0.0
            do {
                let f = try AVAudioFile(forReading: url)
                dur = Double(f.length) / f.processingFormat.sampleRate
            } catch {
                // Fall back to asset duration; still add the track so it appears.
                let asset = AVURLAsset(url: url)
                let d = CMTimeGetSeconds(asset.duration)
                if d.isFinite && d > 0 { dur = d }
                lastError = error.localizedDescription
                NSLog("Setlist: could not open \(url.path) — \(error)")
            }
            var t = Track(path: url.path, title: url.deletingPathExtension().lastPathComponent, duration: dur)
            t.trimEnd = dur
            playlists[i].tracks.append(t)
            added += 1
        }
        if added > 0 {
            status = lastError.isEmpty ? "Added \(added) track\(added == 1 ? "" : "s")"
                                       : "Added \(added) — skipped \(lastError)"
            save()
        } else if !lastError.isEmpty {
            status = "Couldn't add track: \(lastError)"
        }
    }

    func removeTrack(_ id: UUID, from plID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == plID }) else { return }
        // Drop a video track's extracted audio unless another track still uses it.
        if let t = playlists[i].tracks.first(where: { $0.id == id }), t.isVideo,
           t.path.hasPrefix(extractedFolder.path),
           !playlists.flatMap(\.tracks).contains(where: { $0.id != id && $0.path == t.path }) {
            try? FileManager.default.removeItem(atPath: t.path)
        }
        if audio.currentTrackID == id {
            // Removing the live track stops it and cues the next — never auto-plays.
            cueNextTrack()
        }
        if selectedTrackID == id,
           let ti = playlists[i].tracks.firstIndex(where: { $0.id == id }) {
            selectedTrackID = nextPlayable(in: playlists[i], after: ti)?.id
        }
        playlists[i].tracks.removeAll { $0.id == id }
        save()
    }

    /// Switch the viewed playlist and reset the row selection to it.
    func selectPlaylist(_ id: UUID) {
        selectedPlaylistID = id
        selectedTrackID = nil
    }

    func moveTracks(in plID: UUID, from: IndexSet, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == plID }) else { return }
        playlists[i].tracks.move(fromOffsets: from, toOffset: to)
        save()
    }

    func updateTrack(_ id: UUID, in plID: UUID, _ mutate: (inout Track) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == plID }),
              let t = playlists[i].tracks.firstIndex(where: { $0.id == id }) else { return }
        let before = playlists[i].tracks[t]
        mutate(&playlists[i].tracks[t])
        let after = playlists[i].tracks[t]
        if audio.currentTrackID == id {
            if before.trimStart != after.trimStart || before.trimEnd != after.trimEnd {
                // Trim edits on the live track apply immediately.
                audio.seek(toAbsolute: max(audio.currentTime, after.trimStart), track: after,
                           gainDB: gain(for: after, in: playlists[i]))
            } else {
                audio.setGain(db: gain(for: after, in: playlists[i]))
            }
        }
        save()
    }

    // MARK: - Playlist CRUD

    func addPlaylist(parent: UUID? = nil) {
        var p = Playlist(name: parent == nil ? "Untitled Playlist" : "Untitled Sub-playlist")
        p.parentID = parent
        if let parent, let i = playlists.firstIndex(where: { $0.id == parent }) {
            playlists[i].collapsed = false
            // Insert after the parent's last descendant so the array order matches the sidebar.
            let family = descendants(of: parent)
            let last = playlists.lastIndex { family.contains($0.id) } ?? i
            playlists.insert(p, at: last + 1)
        } else {
            playlists.append(p)
        }
        selectedPlaylistID = p.id
        save()
    }

    func deletePlaylist(_ id: UUID) {
        if playingPlaylistID == id { audio.stop(); playingPlaylistID = nil }
        // Sub-playlists move up a level rather than being deleted with it.
        let parent = playlists.first { $0.id == id }?.parentID
        for i in playlists.indices where playlists[i].parentID == id { playlists[i].parentID = parent }
        playlists.removeAll { $0.id == id }
        if playlists.isEmpty { playlists = [Playlist(name: "New Playlist")] }
        if selectedPlaylistID == id || selected == nil { selectedPlaylistID = playlists.first?.id }
        save()
    }

    // MARK: - Sub-playlists

    struct SidebarRow: Identifiable {
        let playlist: Playlist
        let depth: Int
        let hasChildren: Bool
        var id: UUID { playlist.id }
    }

    /// Playlists in sidebar order: each parent followed by its (expanded) children.
    var sidebarRows: [SidebarRow] {
        let ids = Set(playlists.map(\.id))
        var rows: [SidebarRow] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            // Orphans (parent deleted elsewhere) show at the top level.
            for p in playlists where p.parentID == parent || (depth == 0 && p.parentID.map { !ids.contains($0) } == true) {
                let kids = playlists.contains { $0.parentID == p.id }
                rows.append(SidebarRow(playlist: p, depth: depth, hasChildren: kids))
                if kids && !p.collapsed { walk(p.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return rows
    }

    /// Every playlist in tree order, ignoring collapse (for menus).
    var sidebarOrderAll: [Playlist] {
        var out: [Playlist] = []
        func walk(_ parent: UUID?) {
            for p in playlists where p.parentID == parent { out.append(p); walk(p.id) }
        }
        walk(nil)
        let seen = Set(out.map(\.id))
        return out + playlists.filter { !seen.contains($0.id) }
    }

    /// The playlist and everything nested under it.
    func descendants(of id: UUID) -> Set<UUID> {
        var out: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for p in playlists where p.parentID.map(out.contains) == true && !out.contains(p.id) {
                out.insert(p.id); changed = true
            }
        }
        return out
    }

    /// "Parent › Child" label for menus.
    func path(of id: UUID) -> String {
        var names: [String] = []
        var cur = playlists.first { $0.id == id }
        var guardCount = 0
        while let c = cur, guardCount < 20 {
            names.insert(c.name.isEmpty ? "Untitled" : c.name, at: 0)
            cur = c.parentID.flatMap { pid in playlists.first { $0.id == pid } }
            guardCount += 1
        }
        return names.joined(separator: " › ")
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].collapsed.toggle()
        if playlists[i].collapsed, let sel = selectedPlaylistID, sel != id,
           descendants(of: id).contains(sel) {
            selectPlaylist(id)
        }
        save()
    }

    /// Nest a playlist under another (nil = top level). Refuses cycles.
    func reparent(_ id: UUID, to parent: UUID?) {
        guard playlists.contains(where: { $0.id == id }) else { return }
        if let parent, descendants(of: id).contains(parent) { return }
        let moving = descendants(of: id)
        let block = playlists.filter { moving.contains($0.id) }
        playlists.removeAll { moving.contains($0.id) }
        var b = block
        if let k = b.firstIndex(where: { $0.id == id }) { b[k].parentID = parent }
        if let parent, let pi = playlists.firstIndex(where: { $0.id == parent }) {
            playlists[pi].collapsed = false
            let family = descendants(of: parent)
            let last = playlists.lastIndex { family.contains($0.id) } ?? pi
            playlists.insert(contentsOf: b, at: last + 1)
        } else {
            playlists.append(contentsOf: b)
        }
        save()
    }

    enum DropPlacement { case before, into, after }

    /// Drag-and-drop rearrange: put `id` (with its sub-playlists) before/after
    /// `target` at the target's level, or inside `target` as its last child.
    /// `target == nil` moves it to the end of the top level.
    func movePlaylist(_ id: UUID, relativeTo target: UUID?, _ placement: DropPlacement) {
        guard !showLocked, id != target, playlists.contains(where: { $0.id == id }) else { return }
        let moving = descendants(of: id)
        if let target, moving.contains(target) { return }        // can't drop into itself
        var block = playlists.filter { moving.contains($0.id) }
        playlists.removeAll { moving.contains($0.id) }

        let newParent: UUID?
        var insertAt = playlists.count
        if let target, let ti = playlists.firstIndex(where: { $0.id == target }) {
            let afterFamily: Int = {
                let fam = descendants(of: target)
                return (playlists.lastIndex { fam.contains($0.id) } ?? ti) + 1
            }()
            switch placement {
            case .before: newParent = playlists[ti].parentID; insertAt = ti
            case .after:  newParent = playlists[ti].parentID; insertAt = afterFamily
            case .into:   newParent = target; insertAt = afterFamily; playlists[ti].collapsed = false
            }
        } else {
            newParent = nil
        }
        if let k = block.firstIndex(where: { $0.id == id }) { block[k].parentID = newParent }
        playlists.insert(contentsOf: block, at: insertAt)
        save()
    }

    /// Move a track (from whichever playlist holds it) to the end of `destID`.
    func moveTrack(_ trackID: UUID, to destID: UUID) {
        guard !showLocked,
              let src = playlists.firstIndex(where: { $0.tracks.contains { $0.id == trackID } }),
              let dst = playlists.firstIndex(where: { $0.id == destID }), src != dst,
              let ti = playlists[src].tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var t = playlists[src].tracks.remove(at: ti)
        // Loudness match gain is relative to the destination's target.
        if let lu = t.integratedLUFS {
            t.normalizationGainDB = max(-24, min(24, playlists[dst].targetLUFS - lu))
        }
        playlists[dst].tracks.append(t)
        if audio.currentTrackID == trackID {
            playingPlaylistID = destID          // keep playing; it now belongs to dest
            audio.setGain(db: gain(for: t, in: playlists[dst]))
        }
        if selectedTrackID == trackID, selectedPlaylistID == playlists[src].id {
            selectedTrackID = nil
        }
        status = "Moved “\(t.displayTitle)” to \(path(of: destID))"
        save()
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = name
        save()
    }

    func setTarget(_ lufs: Double) {
        guard let i = selectedIndex else { return }
        playlists[i].targetLUFS = lufs
        // Recompute normalization gains from existing measurements.
        for t in playlists[i].tracks.indices {
            if let lu = playlists[i].tracks[t].integratedLUFS {
                playlists[i].tracks[t].normalizationGainDB = max(-24, min(24, lufs - lu))
            }
        }
        reapplyCurrentGain()
        save()
    }

    func setSpaceStops(_ on: Bool) {
        guard let i = selectedIndex else { return }
        playlists[i].spaceStopsAndCues = on
        save()
    }

    /// Mutate the viewed playlist's settings and save.
    func updateSelected(_ mutate: (inout Playlist) -> Void) {
        guard let i = selectedIndex else { return }
        mutate(&playlists[i])
        save()
    }

    func setOutputDevice(_ dev: OutputDevice?) {
        updateSelected { $0.outputDeviceUID = dev?.uid; $0.outputDeviceName = dev?.name }
        if playingPlaylistID == selectedPlaylistID, let pl = selected {
            audio.setOutputDevice(uid: resolvedDeviceUID(pl))
        }
    }

    /// The playlist's device if it's connected, else the system default.
    private func resolvedDeviceUID(_ pl: Playlist) -> String? {
        guard let uid = pl.outputDeviceUID else { return nil }
        if AudioController.outputDevices().contains(where: { $0.uid == uid }) { return uid }
        status = "\(pl.outputDeviceName ?? "Chosen output") isn't connected — using system output"
        return nil
    }

    // MARK: - Keep awake

    /// Hold the display awake while a track is loaded or the show is locked.
    private func updateKeepAwake() {
        let want = audio.hasSegment || showLocked
        if want, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Setlist show in progress" as CFString, &sleepAssertion)
        } else if !want, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: - Video (extracted audio)

    var extractedFolder: URL { AudioExtractor.cacheFolder(libraryURL: libraryURL) }

    private func extractedURL(for id: UUID) -> URL {
        extractedFolder.appendingPathComponent("\(id.uuidString).m4a")
    }

    /// Extract (or re-extract) a video track's soundtrack in the background.
    func startExtraction(_ trackID: UUID) {
        guard !extractingTracks.contains(trackID),
              let t = playlists.flatMap(\.tracks).first(where: { $0.id == trackID }),
              let video = t.videoPath else { return }
        extractingTracks.insert(trackID)
        let dest = URL(fileURLWithPath: t.path)
        let name = t.displayTitle
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Double, Error>
            do { result = .success(try await AudioExtractor.extract(video: URL(fileURLWithPath: video), to: dest)) }
            catch { result = .failure(error) }
            await MainActor.run {
                guard let self else { return }
                self.extractingTracks.remove(trackID)
                switch result {
                case .success(let dur):
                    for pi in self.playlists.indices {
                        for ti in self.playlists[pi].tracks.indices where self.playlists[pi].tracks[ti].id == trackID {
                            let old = self.playlists[pi].tracks[ti].duration
                            self.playlists[pi].tracks[ti].duration = dur
                            // Keep a user-set end point; otherwise play to the end.
                            if self.playlists[pi].tracks[ti].trimEnd <= 0 || abs(self.playlists[pi].tracks[ti].trimEnd - old) < 0.01 {
                                self.playlists[pi].tracks[ti].trimEnd = dur
                            }
                        }
                    }
                    // Don't overwrite a more important message (e.g. a failure).
                    if self.extractingTracks.isEmpty, !self.status.contains("no audio"), !self.status.hasPrefix("Couldn't") {
                        self.status = "Audio ready: “\(name)”"
                    }
                    self.save()
                case .failure(let err):
                    if case AudioExtractor.Failure.noAudio = err {
                        // Nothing to play — take it back out of the playlist.
                        for pi in self.playlists.indices { self.playlists[pi].tracks.removeAll { $0.id == trackID } }
                        if self.selectedTrackID == trackID { self.selectedTrackID = nil }
                        self.save()
                        self.status = "“\(name)” has no audio — not added"
                    } else {
                        self.status = "Couldn't get audio from “\(name)”: \(err.localizedDescription)"
                    }
                }
            }
        }
    }

    /// On launch: rebuild extracted audio that was deleted but whose video is still there.
    private func rebuildMissingExtractions() {
        for t in playlists.flatMap(\.tracks) where t.isVideo && t.fileMissing && !t.sourceMissing {
            startExtraction(t.id)
        }
    }

    // MARK: - Missing files

    /// Point a missing track at its file; other missing tracks whose file name
    /// is in the same folder are relinked too.
    func locateTrack(_ id: UUID, in plID: UUID) {
        guard let pi = playlists.firstIndex(where: { $0.id == plID }),
              let t = playlists[pi].tracks.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.message = "Locate “\(t.sourceURL.lastPathComponent)”"
        panel.allowedContentTypes = [.audio] + AudioExtractor.videoTypes
        panel.directoryURL = nearestExistingFolder(of: t.sourceURL)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if t.isVideo {
            updateTrack(id, in: plID) { $0.videoPath = url.path }
            startExtraction(id)
        } else {
            updateTrack(id, in: plID) { $0.path = url.path }
        }
        let n = relinkMissing(searching: [url.deletingLastPathComponent()], recursive: false)
        status = n > 0 ? "Relinked “\(t.displayTitle)” and \(n) more" : "Relinked “\(t.displayTitle)”"
    }

    /// Choose a folder and search it (recursively) for every missing file by name.
    func findMissingFiles() {
        let panel = NSOpenPanel()
        panel.message = "Choose a folder to search for missing audio files"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let missing = playlists.flatMap(\.tracks).filter(\.sourceMissing).count
        let n = relinkMissing(searching: [dir], recursive: true)
        status = missing == 0 ? "No missing files" : "Found \(n) of \(missing) missing file\(missing == 1 ? "" : "s")"
    }

    var missingCount: Int { selected?.tracks.filter(\.sourceMissing).count ?? 0 }

    @discardableResult
    private func relinkMissing(searching dirs: [URL], recursive: Bool) -> Int {
        let wanted = Set(playlists.flatMap(\.tracks).filter(\.sourceMissing).map { $0.sourceURL.lastPathComponent })
        guard !wanted.isEmpty else { return 0 }
        var found: [String: String] = [:]
        let fm = FileManager.default
        for dir in dirs {
            if recursive, let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                var seen = 0
                for case let u as URL in e {
                    seen += 1
                    if seen > 300_000 { break }
                    let name = u.lastPathComponent
                    if wanted.contains(name), found[name] == nil { found[name] = u.path }
                    if found.count == wanted.count { break }
                }
            } else {
                for name in wanted where found[name] == nil {
                    let cand = dir.appendingPathComponent(name).path
                    if fm.fileExists(atPath: cand) { found[name] = cand }
                }
            }
        }
        var n = 0
        for pi in playlists.indices {
            for ti in playlists[pi].tracks.indices where playlists[pi].tracks[ti].sourceMissing {
                guard let p = found[playlists[pi].tracks[ti].sourceURL.lastPathComponent] else { continue }
                if playlists[pi].tracks[ti].isVideo {
                    playlists[pi].tracks[ti].videoPath = p
                    startExtraction(playlists[pi].tracks[ti].id)
                } else {
                    playlists[pi].tracks[ti].path = p
                }
                n += 1
            }
        }
        if n > 0 { save() }
        return n
    }

    private func nearestExistingFolder(of url: URL) -> URL? {
        var u = url.deletingLastPathComponent()
        while u.path != "/" {
            if FileManager.default.fileExists(atPath: u.path) { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
    }

    func setMatchEnabled(_ on: Bool) {
        guard let i = selectedIndex else { return }
        playlists[i].matchEnabled = on
        reapplyCurrentGain()
        save()
    }

    private func reapplyCurrentGain() {
        guard let pi = playingIndex, let id = audio.currentTrackID,
              let t = playlists[pi].tracks.first(where: { $0.id == id }) else { return }
        audio.setGain(db: gain(for: t, in: playlists[pi]))
    }

    // MARK: - Loudness analysis

    func analyzeTrack(_ id: UUID, in plID: UUID, completion: (() -> Void)? = nil) {
        guard let i = playlists.firstIndex(where: { $0.id == plID }),
              let t = playlists[i].tracks.first(where: { $0.id == id }) else { completion?(); return }
        analyzingTracks.insert(id)
        let url = t.url, start = t.trimStart, end = t.effectiveEnd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lufs = Loudness.integratedLUFS(file: url, start: start, end: end)
            DispatchQueue.main.async {
                guard let self else { return }
                self.analyzingTracks.remove(id)
                if let lufs,
                   let i2 = self.playlists.firstIndex(where: { $0.id == plID }),
                   let t2 = self.playlists[i2].tracks.firstIndex(where: { $0.id == id }) {
                    self.playlists[i2].tracks[t2].integratedLUFS = lufs
                    let target = self.playlists[i2].targetLUFS
                    self.playlists[i2].tracks[t2].normalizationGainDB = max(-24, min(24, target - lufs))
                    if self.audio.currentTrackID == id {
                        self.audio.setGain(db: self.gain(for: self.playlists[i2].tracks[t2], in: self.playlists[i2]))
                    }
                    self.save()
                }
                completion?()
            }
        }
    }

    func analyzeAllAndMatch() {
        guard let i = selectedIndex, !playlists[i].tracks.isEmpty else { return }
        let plID = playlists[i].id
        let ids = playlists[i].tracks.map(\.id)
        analyzingAll = true
        status = "Analyzing \(ids.count) tracks…"
        let group = DispatchGroup()
        for id in ids { group.enter(); analyzeTrack(id, in: plID) { group.leave() } }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.analyzingAll = false
            if let i2 = self.playlists.firstIndex(where: { $0.id == plID }) {
                self.playlists[i2].matchEnabled = true
                self.status = "Matched to \(Int(self.playlists[i2].targetLUFS)) LUFS"
            }
            self.reapplyCurrentGain()
            self.save()
        }
    }

    // MARK: - Persistence

    var libraryURL: URL {
        if let override = ProcessInfo.processInfo.environment["SETLIST_LIBRARY"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Setlist", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: libraryURL),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(playlists) { try? data.write(to: libraryURL) }
    }

    // MARK: - Import / export (custom .setlist JSON)

    static let setlistType = UTType(filenameExtension: "setlist") ?? .json

    func exportSelected() {
        guard let pl = selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.setlistType]
        panel.nameFieldStringValue = "\(pl.name).setlist"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(pl) {
            try? data.write(to: url)
            status = "Exported “\(pl.name)”"
        }
    }

    func importPlaylists() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [Self.setlistType, .json]
        guard panel.runModal() == .OK else { return }
        var last: UUID?
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url),
                  var pl = try? JSONDecoder().decode(Playlist.self, from: data) else { continue }
            pl.id = UUID()
            pl.tracks = pl.tracks.map { var t = $0; t.id = UUID(); return t }
            playlists.append(pl)
            last = pl.id
        }
        if let last { selectedPlaylistID = last; status = "Imported playlist"; save() }
    }

    func pickAndAddTracks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff, .mpeg4Audio] + AudioExtractor.videoTypes
        guard panel.runModal() == .OK else { return }
        addTracks(panel.urls)
    }
}
