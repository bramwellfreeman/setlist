import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ShortcutsSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 400)
        .preferredColorScheme(.light)
    }
}

struct ShortcutsSettings: View {
    @EnvironmentObject var shortcuts: ShortcutStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard Shortcuts").font(.system(size: 15, weight: .bold))
                    Text("Click a shortcut, then press the keys you want.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Restore Defaults") { shortcuts.resetAll() }
                    .buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().overlay(Theme.line)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ShortcutAction.allCases) { action in
                        ShortcutRow(action: action)
                        if action != ShortcutAction.allCases.last {
                            Divider().overlay(Theme.line).padding(.leading, 20)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.paper)
    }
}

struct ShortcutRow: View {
    @EnvironmentObject var shortcuts: ShortcutStore
    let action: ShortcutAction
    @State private var recording = false

    var body: some View {
        HStack(spacing: 12) {
            Text(action.title).font(.system(size: 13))
            Spacer()
            if shortcuts.isCustom(action) {
                Button {
                    shortcuts.reset(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Reset to default")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(recording ? Theme.blue.opacity(0.12) : Theme.pill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(recording ? Theme.blue : .clear, lineWidth: 1.5))
                Text(recording ? "Press keys…" : shortcuts.display(action))
                    .font(.system(size: 12, weight: .semibold,
                                   design: recording ? .default : .monospaced))
                    .foregroundStyle(recording ? Theme.blue : Theme.ink)
                KeyCapture(recording: $recording) { chord in
                    if let chord { shortcuts.set(chord, for: action) }
                    recording = false
                }
            }
            .frame(width: 150, height: 28)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
