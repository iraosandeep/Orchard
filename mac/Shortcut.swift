// The Rewrite Selection shortcut: stored in UserDefaults, recordable from
// Settings, and re-registered as a global hotkey when it changes.
import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int // Carbon flags: cmdKey | optionKey | controlKey | shiftKey
    var key: String    // display name of the key, e.g. "R", "Space", "F5"

    static let standard = Shortcut(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey, key: "R")

    var label: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    var isFunctionKey: Bool { key.hasPrefix("F") && key.count > 1 && Int(key.dropFirst()) != nil }

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    init(event: NSEvent) {
        let f = event.modifierFlags
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        let code = Int(event.keyCode)
        let name = Self.specialKeys[code]
            ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        self.init(keyCode: code, modifiers: m, key: name.isEmpty ? "#\(code)" : name)
    }

    /// nil if usable; otherwise why not. Plain ⌘-letter combos would steal
    /// everyday app shortcuts, so require two modifiers (or a function key).
    var problem: String? {
        let strong = modifiers & (cmdKey | optionKey | controlKey)
        let count = [cmdKey, optionKey, controlKey, shiftKey].filter { modifiers & $0 != 0 }.count
        if isFunctionKey { return nil }
        if strong == 0 || count < 2 {
            return "Use at least two modifier keys (for example ⌃⌥R) so it doesn't clash with app shortcuts."
        }
        return nil
    }
}

@MainActor @Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    private static let key = "rewriteShortcut"

    var current: Shortcut
    var recording = false
    var message: String?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
            current = s
        } else {
            current = .standard
        }
    }

    /// Registers `s` as the global hotkey; keeps the old one if that fails.
    func set(_ s: Shortcut) {
        if let p = s.problem { message = p; return }
        guard RewriteController.shared.register(s) else {
            message = "\(s.label) couldn't be registered. Try a different combination."
            RewriteController.shared.register(current)
            return
        }
        current = s
        message = s == .standard ? nil : "Rewrite Selection is now \(s.label)."
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func reset() { set(.standard); message = nil }
}

/// Current shortcut as text, for menus and messages.
@MainActor var rewriteShortcutLabel: String { ShortcutStore.shared.current.label }

/// Click, then press the new combination. Esc cancels.
struct ShortcutRecorder: View {
    let store = ShortcutStore.shared
    @ViewState private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.recording ? stop() : start()
            } label: {
                Text(store.recording ? "Type shortcut…" : store.current.label)
                    .monospaced()
                    .frame(minWidth: 90)
            }
            .help(store.recording ? "Press the new combination, or Esc to cancel" : "Click to change")
            if store.current != .standard && !store.recording {
                Button("Reset") { store.reset() }
                    .help("Back to \(Shortcut.standard.label)")
            }
        }
        .onDisappear { stop() }
    }

    func start() {
        store.message = nil
        store.recording = true
        RewriteController.shared.unregister() // so pressing the old combo can be recorded
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else {
                let s = Shortcut(event: event)
                stop(registerCurrent: false)
                store.set(s)
            }
            return nil
        }
    }

    func stop(registerCurrent: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard store.recording else { return }
        store.recording = false
        if registerCurrent { RewriteController.shared.register(store.current) }
    }
}
