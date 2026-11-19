import AVFoundation
import AppKit

/// Scripted UI check, run with SETLIST_SELFTEST=1 (and SETLIST_LIBRARY pointing
/// at a throwaway library). Posts real mouse/key events into the app's event
/// queue — the same path as a user — and logs playback state after each step.
enum SelfTest {
    /// Sidebar pill frames (global, top-left origin) so tests can click them.
    static var pillFrames: [String: CGRect] = [:]

    static func runIfRequested(state: AppState, shortcuts: ShortcutStore) {
        if let path = ProcessInfo.processInfo.environment["SETLIST_SNAPSHOT"] {
            snapshot(to: path, state: state)
            return
        }
        if ProcessInfo.processInfo.environment["SETLIST_SELFTEST"] == "4" {
            video(state: state); return
        }
        if ProcessInfo.processInfo.environment["SETLIST_SELFTEST"] == "3" {
            subPlaylists(state: state); return
        }
        if ProcessInfo.processInfo.environment["SETLIST_SELFTEST"] == "2" {
            features(state: state); return
        }
        guard ProcessInfo.processInfo.environment["SETLIST_SELFTEST"] == "1" else { return }

        func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil } }
        func table(in v: NSView?) -> NSTableView? {
            guard let v else { return nil }
            if let t = v as? NSTableView { return t }
            for s in v.subviews { if let t = table(in: s) { return t } }
            return nil
        }
        func post(_ e: NSEvent?) { if let e { NSApp.postEvent(e, atStart: false) } }
        func click(track i: Int, count: Int = 1) {
            guard let w = window(), let tv = table(in: w.contentView) else { log("no table"); return }
            let r = tv.rect(ofRow: i)
            let p = tv.convert(NSPoint(x: r.midX - 80, y: r.midY), to: nil)
            for n in 1...count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(n - 1) * 0.12) {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        post(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1))
                    }
                }
            }
            log("posted \(count == 2 ? "double-" : "")click on track \(i + 1)")
        }
        func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) {
            guard let w = window() else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                post(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, characters: chars,
                                      charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            }
        }
        func log(_ s: String) {
            let pl = state.selected
            let name: (UUID?) -> String = { id in pl?.tracks.first { $0.id == id }?.title ?? "-" }
            let fr = window()?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            print("SELFTEST \(s) | playing=\(state.audio.isPlaying) loaded=\(name(state.audio.currentTrackID)) "
                  + "selected=\(name(state.selectedTrackID)) cued=\(state.cuedTrack?.title ?? "-") "
                  + "fr=\(fr) status=\"\(state.status)\"")
            fflush(stdout)
        }
        let space: () -> Void = { key(49, " ") }
        let steps: [(Double, String, () -> Void)] = [
            (1.0, "start", { NSApp.activate(ignoringOtherApps: true); window()?.makeKeyAndOrderFront(nil) }),
            (0.3, "Space with nothing selected → plays first", space),
            (0.6, "", space),
            (0.3, "Space again → pauses", {}),
            (0.1, "", { click(track: 2) }),
            (0.4, "after click on Three (should be selected)", {}),
            (0.0, "", space),
            (0.5, "Space → should play Three", {}),
            (0.0, "", { click(track: 3, count: 2) }),
            (0.6, "double-click Four → should play Four", {}),
            (0.0, "", space),
            (0.4, "Space while playing (pause mode) → paused on Four", {}),
            (0.0, "", { click(track: 0) }),
            (0.3, "click One while paused", {}),
            (0.0, "", { state.updateSelected { $0.fadeOutSeconds = 0 }; state.setSpaceStops(true); space() }),
            (0.4, "stop mode on, Space → plays One", {}),
            (0.0, "", space),
            (0.4, "Space while playing (stop mode) → stopped, Three cued (Two missing)", {}),
            (0.0, "", space),
            (0.4, "Space → plays cued Three", {}),
            (0.0, "", { state.setSpaceStops(false) }),
            (0.3, "end", { NSApp.terminate(nil) }),
        ]
        var t = 0.0
        for (delay, label, f) in steps {
            t += delay
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { f(); if !label.isEmpty { log(label) } }
        }
    }

    /// Render the live window to a PNG (for visual checks without screen capture),
    /// e.g. SETLIST_SNAPSHOT=/tmp/shot (writes shot-1.png idle, shot-2.png playing).
    static func snapshot(to base: String, state: AppState) {
        func shoot(_ n: Int) {
            guard let w = NSApp.windows.first(where: { $0.isVisible }), let v = w.contentView?.superview ?? w.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(n).png"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSApp.windows.first { $0.isVisible }?.setContentSize(NSSize(width: 1100, height: 720))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { shoot(1)
            if let pl = state.selected, pl.tracks.count > 2 {
                state.playTrack(pl.tracks[0].id, inPlaylist: pl.id)
                state.selectedTrackID = pl.tracks[2].id
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { shoot(2); state.audio.stop(); state.selectPlaylist(state.playlists.last!.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { shoot(3); NSApp.terminate(nil) }
    }

    /// Feature checks: continue modes, fades, lock, keep-awake, waveform, devices.
    static func features(state: AppState) {
        func log(_ s: String) {
            let pl = state.selected
            let name: (UUID?) -> String = { id in pl?.tracks.first { $0.id == id }?.title ?? "-" }
            print("FEAT \(s) | playing=\(state.audio.isPlaying) loaded=\(name(state.audio.currentTrackID)) "
                  + "selected=\(name(state.selectedTrackID)) fading=\(state.audio.isFading) "
                  + "t=\(String(format: "%.2f", state.audio.currentTime)) status=\"\(state.status)\"")
            fflush(stdout)
        }
        guard let pl = state.selected else { return }
        let id: (String) -> UUID = { n in pl.tracks.first { $0.title == n }!.id }
        let steps: [(Double, () -> Void)] = [
            (0.8, { state.showLocked = false
                    state.updateSelected { $0.continueMode = .gapless; $0.spaceStopsAndCues = false }
                    state.playTrack(id("One"), inPlaylist: pl.id); log("gapless: play One (3s, 44.1k stereo)") }),
            (2.0, { log("gapless: mid One") }),
            (1.6, { log("gapless: expect Three (48k mono) already playing, no stop") }),
            (0.0, { state.updateSelected { $0.continueMode = .crossfade; $0.crossfadeSeconds = 2 }
                    state.playTrack(id("Three"), inPlaylist: pl.id); log("crossfade: play Three") }),
            (2.2, { log("crossfade: expect Four took over (overlap 1.5s)") }),
            (0.2, { print("FEAT waveform peaks One=\(WaveformStore.shared.peaks(for: pl.tracks[0].path)?.count ?? -1)") }),
            (0.0, { state.updateSelected { $0.continueMode = .cue; $0.spaceStopsAndCues = true; $0.fadeOutSeconds = 1 }
                    state.playTrack(id("One"), inPlaylist: pl.id) }),
            (0.5, { state.togglePlayPause(); log("fade: Space pressed") }),
            (0.4, { log("fade: mid-fade") }),
            (0.9, { log("fade: expect stopped, Three cued") }),
            (0.0, { state.showLocked = true; log("lock on") }),
            (0.5, { print("FEAT devices: \(AudioController.outputDevices().map(\.name))"); fflush(stdout)
                    state.playTrack(id("One"), inPlaylist: pl.id) }),
            (0.3, { if let d = AudioController.outputDevices().first { state.setOutputDevice(d) }
                    log("device: switched to first device while playing") }),
            (0.5, { log("device: still playing?") }),
            (0.0, { state.setOutputDevice(nil); log("device: back to default") }),
            (0.4, { log("device: still playing after reset?") }),
            (0.0, { state.audio.stop(); state.showLocked = false
                    state.updateSelected { $0.continueMode = .cue; $0.spaceStopsAndCues = false } }),
            (0.4, { NSApp.terminate(nil) }),
        ]
        var t = 0.0
        for (d, f) in steps { t += d; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
    }

    /// Sub-playlists, moving tracks between playlists, and a real drag attempt.
    static func subPlaylists(state: AppState) {
        func dump(_ label: String) {
            let rows = state.sidebarRows.map { String(repeating: "  ", count: $0.depth) + $0.playlist.name + "(\($0.playlist.tracks.count))" }
            print("SUB \(label): " + rows.joined(separator: " | ") + "  status=\"\(state.status)\""); fflush(stdout)
        }
        func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil } }
        func table(in v: NSView?) -> NSTableView? {
            guard let v else { return nil }
            if let t = v as? NSTableView { return t }
            for s in v.subviews { if let t = table(in: s) { return t } }
            return nil
        }
        guard let root = state.selected else { return }
        let steps: [(Double, () -> Void)] = [
            (0.8, { NSApp.activate(ignoringOtherApps: true); window()?.makeKeyAndOrderFront(nil)
                    state.showLocked = false; dump("start") }),
            (0.1, { state.addPlaylist(parent: root.id); state.renamePlaylist(state.selectedPlaylistID!, to: "Act 1")
                    state.addPlaylist(parent: root.id); state.renamePlaylist(state.selectedPlaylistID!, to: "Act 2")
                    dump("added Act 1 + Act 2 under root") }),
            (0.1, { let act1 = state.playlists.first { $0.name == "Act 1" }!.id
                    state.addPlaylist(parent: act1); state.renamePlaylist(state.selectedPlaylistID!, to: "Scene A")
                    dump("nested Scene A under Act 1") }),
            (0.1, { let a1 = state.playlists.first { $0.name == "Act 1" }!.id
                    let sa = state.playlists.first { $0.name == "Scene A" }!.id
                    state.reparent(a1, to: sa); dump("cycle attempt (Act 1 into Scene A) refused") }),
            (0.1, { let t = root.tracks[0].id; let a2 = state.playlists.first { $0.name == "Act 2" }!.id
                    state.moveTrack(t, to: a2); dump("moved One → Act 2 via menu action") }),
            (0.1, { state.toggleCollapsed(root.id); dump("collapsed root") }),
            (0.1, { state.toggleCollapsed(root.id); dump("expanded root") }),
            (0.1, { state.showLocked = true; let a2 = state.playlists.first { $0.name == "Act 2" }!
                    state.moveTrack(a2.tracks[0].id, to: root.id); dump("locked: move refused")
                    state.showLocked = false }),
            // Real drag: row 0 of the root playlist onto the "Act 1" sidebar pill.
            (0.1, { state.selectPlaylist(root.id) }),
            (0.6, {
                guard let w = window(), let tv = table(in: w.contentView) else { print("SUB no table"); return }
                let r = tv.rect(ofRow: 0)
                let from = tv.convert(NSPoint(x: r.midX - 100, y: r.midY), to: nil)
                // sidebar pill for Act 1: find by the sidebar row index (logo row + rows of 30pt + 2 spacing)
                let idx = state.sidebarRows.firstIndex { $0.playlist.name == "Act 1" } ?? 1
                let h = w.contentView!.bounds.height
                let to = NSPoint(x: 100, y: h - (12 + 30 + 20 + CGFloat(idx) * 32 + 15))
                func ev(_ t: NSEvent.EventType, _ p: NSPoint) {
                    NSApp.postEvent(NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
                }
                ev(.leftMouseDown, from)
                for i in 1...24 {
                    let f = CGFloat(i) / 24
                    ev(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f))
                }
                ev(.leftMouseUp, to)
                print("SUB posted drag from \(from) to \(to)"); fflush(stdout)
            }),
            (1.5, { dump("after drag attempt (Three → Act 1 expected)") }),
            (0.1, { let a1 = state.playlists.first { $0.name == "Act 1" }!.id
                    state.deletePlaylist(a1); dump("deleted Act 1 → Scene A moves up to root") }),
            (0.1, { let enc = state.playlists.first { $0.name != "Harness" && $0.parentID == nil && $0.name != "Scene A" }
                    print("SUB (no extra top-level playlist to test with: \(enc == nil))")
                    let a2 = state.playlists.first { $0.name == "Act 2" }!.id
                    let sa = state.playlists.first { $0.name == "Scene A" }!.id
                    state.movePlaylist(a2, relativeTo: sa, .before); dump("drop Act 2 BEFORE Scene A") }),
            (0.1, { let a2 = state.playlists.first { $0.name == "Act 2" }!.id
                    let sa = state.playlists.first { $0.name == "Scene A" }!.id
                    state.movePlaylist(a2, relativeTo: sa, .into); dump("drop Act 2 INTO Scene A") }),
            (0.1, { let a2 = state.playlists.first { $0.name == "Act 2" }!.id
                    state.movePlaylist(a2, relativeTo: nil, .after); dump("drop Act 2 on empty space → top level end") }),
            (0.1, { let a2 = state.playlists.first { $0.name == "Act 2" }!.id
                    let root = state.playlists.first { $0.name == "Harness" }!.id
                    state.movePlaylist(root, relativeTo: a2, .before); dump("drop Harness (with children) BEFORE Act 2") }),
            (0.1, { let root = state.playlists.first { $0.name == "Harness" }!.id
                    let sa = state.playlists.first { $0.name == "Scene A" }!.id
                    state.movePlaylist(root, relativeTo: sa, .into); dump("drop Harness INTO its own child → refused") }),
            (0.1, { let sa = state.playlists.first { $0.name == "Scene A" }!.id
                    let a2 = state.playlists.first { $0.name == "Act 2" }!.id
                    state.movePlaylist(sa, relativeTo: a2, .after); dump("drop Scene A AFTER Act 2 (out of sub-list)") }),
            // Clicking sidebar pills must still select (pills are now drag sources).
            (0.2, {
                guard let w = window() else { return }
                let h = w.contentView!.bounds.height
                guard let f = SelfTest.pillFrames["Act 2"] else { print("SUB no frame"); return }
                let pt = NSPoint(x: f.midX, y: h - f.midY)
                print("SUB clicking Act 2 at \(pt) frame \(f) active=\(NSApp.isActive) key=\(w.isKeyWindow)")
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    NSApp.postEvent(NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
                }
            }),
            (0.9, { guard let w = window(), let f = SelfTest.pillFrames["Encores"] ?? SelfTest.pillFrames["Scene A"] else { return }
                    let pt = NSPoint(x: f.midX, y: w.contentView!.bounds.height - f.midY)
                    print("SUB 2nd click (Scene A) at \(pt) active=\(NSApp.isActive)")
                    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        NSApp.postEvent(NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false) } }),
            (1.0, { print("SUB clicked sidebar Act 2 → selected=\(state.selected?.name ?? "-")"); fflush(stdout) }),

            (0.3, { NSApp.terminate(nil) }),
        ]
        var t = 0.0
        for (d, f) in steps { t += d; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
    }

    /// Video import: extraction, playback, analysis, rebuild, cleanup.
    static func video(state: AppState) {
        let dir = ProcessInfo.processInfo.environment["SETLIST_VIDEO_DIR"] ?? "/tmp"
        let files = ["clip-aac.mp4", "clip-pcm.mov", "clip-51.mp4", "silent.mp4", "clip.mkv"]
        func dump(_ label: String) {
            guard let pl = state.selected else { return }
            print("VID \(label) status=\"\(state.status)\"")
            for t in pl.tracks {
                let ch = (try? AVAudioFile(forReading: t.url)).map { "\($0.processingFormat.channelCount)ch \(Int($0.processingFormat.sampleRate))Hz" } ?? "-"
                print("    \(t.title): video=\(t.isVideo) extracting=\(state.extractingTracks.contains(t.id)) "
                      + "audioMissing=\(t.fileMissing) dur=\(String(format: "%.2f", t.duration)) audio=\(ch) lufs=\(t.integratedLUFS.map { String(format: "%.1f", $0) } ?? "-")")
            }
            fflush(stdout)
        }
        let steps: [(Double, () -> Void)] = [
            (0.8, { state.addPlaylist(); state.addTracks(files.map { URL(fileURLWithPath: dir + "/" + $0) }); dump("right after add") }),
            (Double(ProcessInfo.processInfo.environment["SETLIST_VIDEO_WAIT"] ?? "") ?? 2.5, { dump("after extraction") }),
            (0.0, { if let t = state.selected?.tracks.first(where: { $0.title == "clip-51" }) { state.playTrack(t.id, inPlaylist: state.selectedPlaylistID!) } }),
            (1.0, { print("VID playing 5.1 clip: playing=\(state.audio.isPlaying) t=\(String(format: "%.2f", state.audio.currentTime))"); fflush(stdout)
                    state.audio.stop(); state.analyzeAllAndMatch() }),
            (1.5, { dump("after analyze") }),
            (0.0, { if let t = state.selected?.tracks.first(where: { $0.title == "clip-aac" }) {
                        try? FileManager.default.removeItem(atPath: t.path)
                        print("VID deleted extracted audio for clip-aac; missing=\(t.fileMissing)")
                        state.startExtraction(t.id) } }),
            (1.5, { dump("after rebuild") }),
            (0.0, { if let pl = state.selected, let t = pl.tracks.first(where: { $0.title == "clip-pcm" }) {
                        let path = t.path
                        state.removeTrack(t.id, from: pl.id)
                        print("VID removed clip-pcm; extracted file still exists=\(FileManager.default.fileExists(atPath: path))"); fflush(stdout) } }),
            (0.3, { NSApp.terminate(nil) }),
        ]
        var t = 0.0
        for (d, f) in steps { t += d; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
    }
}
