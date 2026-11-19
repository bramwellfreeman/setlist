import SwiftUI
import AppKit

// MARK: - Actions

enum ShortcutAction: String, CaseIterable, Identifiable {
    case playPause, next, previous, newPlaylist, addTracks, importPlaylist, exportPlaylist
    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause:      return "Play / Pause"
        case .next:           return "Next Track"
        case .previous:       return "Previous Track"
        case .newPlaylist:    return "New Playlist"
        case .addTracks:      return "Add Tracks"
        case .importPlaylist: return "Import Playlist"
        case .exportPlaylist: return "Export Playlist"
        }
    }

    var defaultChord: KeyChord {
        switch self {
        case .playPause:      return KeyChord(key: "space", modifiers: 0)
        case .next:           return KeyChord(key: "right", modifiers: EventModifiers.command.rawValue)
        case .previous:       return KeyChord(key: "left",  modifiers: EventModifiers.command.rawValue)
        case .newPlaylist:    return KeyChord(key: "n", modifiers: EventModifiers.command.rawValue)
        case .addTracks:      return KeyChord(key: "o", modifiers: EventModifiers.command.rawValue)
        case .importPlaylist: return KeyChord(key: "i", modifiers: ([.command, .shift] as EventModifiers).rawValue)
        case .exportPlaylist: return KeyChord(key: "e", modifiers: EventModifiers.command.rawValue)
        }
    }
}

// MARK: - Key chord

struct KeyChord: Codable, Equatable {
    var key: String        // single character, or a token: space/left/right/up/down/return/delete/tab
    var modifiers: Int     // EventModifiers rawValue

    var eventModifiers: EventModifiers { EventModifiers(rawValue: modifiers) }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "space":  return .space
        case "left":   return .leftArrow
        case "right":  return .rightArrow
        case "up":     return .upArrow
        case "down":   return .downArrow
        case "return": return .return
        case "delete": return .delete
        case "tab":    return .tab
        default:       return key.first.map { KeyEquivalent($0) }
        }
    }

    var keyLabel: String {
        switch key {
        case "space":  return "Space"
        case "left":   return "←"
        case "right":  return "→"
        case "up":     return "↑"
        case "down":   return "↓"
        case "return": return "⏎"
        case "delete": return "⌫"
        case "tab":    return "⇥"
        default:       return key.uppercased()
        }
    }

    var display: String {
        var s = ""
        let m = eventModifiers
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    init(key: String, modifiers: Int) { self.key = key; self.modifiers = modifiers }

    /// Build from a captured key event; returns nil for modifier-only presses.
    init?(event: NSEvent) {
        var k: String
        switch event.keyCode {
        case 49:     k = "space"
        case 123:    k = "left"
        case 124:    k = "right"
        case 125:    k = "down"
        case 126:    k = "up"
        case 36, 76: k = "return"
        case 51:     k = "delete"
        case 48:     k = "tab"
        default:
            guard let ch = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
            if String(ch).rangeOfCharacter(from: .alphanumerics) != nil || "`-=[]\\;',./".contains(ch) {
                k = String(ch)
            } else { return nil }
        }
        var m: EventModifiers = []
        let f = event.modifierFlags
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.option)  { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.shift)   { m.insert(.shift) }
        self.key = k
        self.modifiers = m.rawValue
    }
}

// MARK: - Store

final class ShortcutStore: ObservableObject {
    @Published private(set) var overrides: [String: KeyChord] = [:]
    private let defaultsKey = "shortcutOverrides"

    init() { load() }

    func chord(for a: ShortcutAction) -> KeyChord { overrides[a.rawValue] ?? a.defaultChord }
    func display(_ a: ShortcutAction) -> String { chord(for: a).display }
    func isCustom(_ a: ShortcutAction) -> Bool { overrides[a.rawValue] != nil }

    func set(_ c: KeyChord, for a: ShortcutAction) { overrides[a.rawValue] = c; save() }
    func reset(_ a: ShortcutAction) { overrides[a.rawValue] = nil; save() }
    func resetAll() { overrides = [:]; save() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: KeyChord].self, from: data) else { return }
        overrides = decoded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Apply a chord as a SwiftUI keyboard shortcut

struct ApplyShortcut: ViewModifier {
    let chord: KeyChord?
    init(_ chord: KeyChord?) { self.chord = chord }
    func body(content: Content) -> some View {
        if let c = chord, let ke = c.keyEquivalent {
            content.keyboardShortcut(ke, modifiers: c.eventModifiers)
        } else {
            content
        }
    }
}

// MARK: - Playback key routing

/// Handles the playback shortcuts (play/pause, next, previous) via a local event
/// monitor, which is far more reliable than no-modifier menu accelerators.
/// Returns nil to consume the event, or the event to pass it on.
func routePlaybackKey(_ event: NSEvent, state: AppState, shortcuts: ShortcutStore) -> NSEvent? {
    guard let chord = KeyChord(event: event) else { return event }

    // While typing in a text field, let plain (modifier-less) keys through.
    let fr = NSApplication.shared.keyWindow?.firstResponder
    let editing = (fr is NSText)
        || (fr?.className.contains("NSTextView") ?? false)
        || (fr?.className.contains("TextField") ?? false)

    for action in [ShortcutAction.playPause, .next, .previous] {
        let bound = shortcuts.chord(for: action)
        guard chord.key == bound.key, chord.modifiers == bound.modifiers else { continue }
        if editing && bound.modifiers == 0 { return event }
        switch action {
        case .playPause: state.togglePlayPause()
        case .next:      state.next()
        case .previous:  state.previous()
        default:         break
        }
        return nil
    }
    return event
}

// MARK: - Recorder (AppKit)

final class RecorderNSView: NSView {
    var onStart: (() -> Void)?
    var onCapture: ((KeyChord?) -> Void)?   // nil == cancelled (Esc)
    var recording = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !recording { onStart?(); window?.makeFirstResponder(self) }
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { onCapture?(nil); return }   // Esc
        if let c = KeyChord(event: event) { onCapture?(c) }
    }
    override func resignFirstResponder() -> Bool {
        if recording { onCapture?(nil) }
        return true
    }
}

struct KeyCapture: NSViewRepresentable {
    @Binding var recording: Bool
    var onCapture: (KeyChord?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> RecorderNSView {
        let v = RecorderNSView()
        v.onStart = { context.coordinator.parent.recording = true }
        v.onCapture = { chord in context.coordinator.parent.onCapture(chord) }
        return v
    }
    func updateNSView(_ v: RecorderNSView, context: Context) {
        context.coordinator.parent = self
        v.recording = recording
        if recording, v.window != nil, v.window?.firstResponder !== v {
            DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        }
    }
    final class Coordinator { var parent: KeyCapture; init(_ p: KeyCapture) { parent = p } }
}
