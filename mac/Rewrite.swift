// Rewrite selection in any app: press the shortcut (⌃⌥R by default), pick an instruction, and the
// rewritten text replaces the selection. Uses copy/paste key events, so it
// works in almost any text field. Needs Accessibility permission.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Keep rewrites well inside the context window so the output is never cut short.
let rewriteMaxChars = 6000

// MARK: - Global hotkey (Carbon; needs no extra permission)

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Fails if the combination can't be registered (e.g. another app owns it).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, ctx in
                let me = Unmanaged<HotKey>.fromOpaque(ctx!).takeUnretainedValue()
                DispatchQueue.main.async { me.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: OSType(0x4F52_4348), id: 1)  // 'ORCH'
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

// MARK: - Keyboard + pasteboard helpers

enum Keys {
    static func press(_ key: Int, flags: CGEventFlags = .maskCommand) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// Clears this app's (possibly stale) Accessibility entry so macOS asks afresh.
    static func resetTrust() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "local.orchard"]
        try? p.run()
        p.waitUntilExit()
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }
}

extension NSPasteboard {
    func snapshot() -> [NSPasteboardItem] {
        (pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
    }

    func restore(_ items: [NSPasteboardItem]) {
        clearContents()
        if !items.isEmpty { writeObjects(items) }
    }
}

// MARK: - State

@MainActor @Observable
final class RewriteState {
    static let presets: [(name: String, instruction: String)] = [
        (
            "Fix Grammar",
            "Fix spelling, grammar and punctuation. Keep the wording and meaning otherwise unchanged."
        ),
        ("Shorter", "Make it shorter and more concise. Keep the meaning."),
        ("Formal", "Make it more formal and professional."),
        ("Friendly", "Make it warmer and more friendly."),
    ]

    var original = ""
    var instruction = ""
    var result = ""
    var running = false
    var done = false
    var error: String?
    private var task: Task<Void, Never>?

    func reset(original: String, error: String? = nil) {
        task?.cancel()
        self.original = original
        self.error = error
        instruction = ""
        result = ""
        running = false
        done = false
    }

    func run(_ instruction: String) {
        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !original.isEmpty else { return }
        if let reason = Assistant.unavailableReason {
            error = reason
            return
        }
        if original.count > rewriteMaxChars {
            error =
                "Selection is too long (\(original.count) characters). Rewrite handles up to \(rewriteMaxChars) so nothing gets cut off."
            return
        }
        task?.cancel()
        error = nil
        result = ""
        done = false
        running = true
        let system = """
            Rewrite the user's text. Instruction: \(instruction)
            Output only the rewritten text: no preamble, no quotes, no explanation.
            """
        let input = original
        task = Task {
            do {
                for try await partial in Assistant.stream(instructions: system, input: input) {
                    result = partial
                }
                done = !result.isEmpty
            } catch is CancellationError {
            } catch {
                self.error = Assistant.describe(error)
            }
            running = false
        }
    }

    func cancel() { task?.cancel() }
}

// MARK: - Controller + panel

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class RewriteController {
    static let shared = RewriteController()
    let state = RewriteState()
    private var hotKey: HotKey?
    private var panel: KeyPanel?
    private var sourceApp: NSRunningApplication?

    func start() {
        if !register(ShortcutStore.shared.current) {
            ShortcutStore.shared.message = "\(rewriteShortcutLabel) is used by another app. Pick a different shortcut."
        }
    }

    /// Replaces the global hotkey; returns false if it couldn't be registered.
    @discardableResult
    func register(_ s: Shortcut) -> Bool {
        hotKey = nil // unregister the old one first
        hotKey = HotKey(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in
            Task { @MainActor in await self?.trigger() }
        }
        return hotKey != nil
    }

    func unregister() { hotKey = nil }

    func trigger() async {
        guard Keys.requestTrust() else {
            let a = NSAlert()
            a.messageText = "Allow Orchard to rewrite text in other apps"
            a.informativeText = """
                Rewrite Selection copies your selection and pastes the result, which needs Accessibility access. \
                Turn on Orchard in System Settings › Privacy & Security › Accessibility, then press \(rewriteShortcutLabel) again.

                If Orchard already looks switched on, that entry belongs to an older build. \
                Click Reset Permission, then switch Orchard on again.
                """
            a.addButton(withTitle: "Open Settings")
            a.addButton(withTitle: "Reset Permission")
            a.addButton(withTitle: "Cancel")
            NSApp.activate()
            switch a.runModal() {
            case .alertFirstButtonReturn:
                Keys.openAccessibilitySettings()
            case .alertSecondButtonReturn:
                Keys.resetTrust()
                _ = Keys.requestTrust()
                Keys.openAccessibilitySettings()
            default: break
            }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // Orchard itself is frontmost: just toggle the panel.
            if panel?.isVisible == true { close() }
            return
        }
        sourceApp = front

        let selection = await copySelection()
        if selection.isEmpty {
            state.reset(
                original: "",
                error:
                    "No text selected. Select text in any app, then press \(rewriteShortcutLabel).")
        } else {
            state.reset(original: selection)
        }
        show()
    }

    /// Sends ⌘C to the frontmost app and returns the copied text, leaving the
    /// user's clipboard as it was.
    private func copySelection() async -> String {
        let pb = NSPasteboard.general
        let saved = pb.snapshot()
        let before = pb.changeCount
        // Let the user release the hotkey modifiers first.
        try? await Task.sleep(for: .milliseconds(120))
        Keys.press(kVK_ANSI_C)
        for _ in 0..<30 where pb.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pb.changeCount != before else { return "" }
        let text = pb.string(forType: .string) ?? ""
        pb.restore(saved)
        return text
    }

    func replace() {
        let text = state.result
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let saved = pb.snapshot()
        pb.clearContents()
        pb.setString(text, forType: .string)
        close()
        sourceApp?.activate()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            Keys.press(kVK_ANSI_V)
            try? await Task.sleep(for: .milliseconds(600))
            pb.restore(saved)
        }
    }

    func copyResult() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.result, forType: .string)
        close()
    }

    func close() {
        state.cancel()
        panel?.orderOut(nil)
    }

    private func show() {
        if panel == nil {
            let p = KeyPanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: RewriteView(state: state, controller: self))
            panel = p
        }
        // Place near the mouse, kept on screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let p = panel, let vis = screen?.visibleFrame {
            var origin = NSPoint(x: mouse.x - p.frame.width / 2, y: mouse.y - p.frame.height - 16)
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - p.frame.width - 8)
            origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - p.frame.height - 8)
            p.setFrameOrigin(origin)
            p.makeKeyAndOrderFront(nil)
        }
    }
}

struct RewriteView: View {
    @Bindable var state: RewriteState
    let controller: RewriteController
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Rewrite Selection", systemImage: "leaf").font(.headline)

            if !state.original.isEmpty {
                Text(state.original)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    ForEach(Array(RewriteState.presets.enumerated()), id: \.offset) { i, p in
                        Button(p.name) { state.run(p.instruction) }
                            .keyboardShortcut(
                                KeyEquivalent(Character("\(i + 1)")), modifiers: .command
                            )
                            .help("⌘\(i + 1)")
                    }
                }
                .disabled(state.running)

                TextField("Or describe a change…", text: $state.instruction)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit {
                        if !state.instruction.trimmingCharacters(in: .whitespaces).isEmpty {
                            state.run(state.instruction)
                        } else if state.done {
                            controller.replace()
                        }
                    }
            }

            if let e = state.error {
                Label(e, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if state.running || !state.result.isEmpty {
                ScrollView {
                    Text(state.result.isEmpty ? "…" : state.result)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: .infinity)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Spacer(minLength: 0)
            }

            HStack {
                if state.running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { controller.close() }.keyboardShortcut(.cancelAction)
                Button("Copy") { controller.copyResult() }.disabled(!state.done)
                Button("Replace") { controller.replace() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.done)
                    .help("Replace selection (⌘Return)")
            }
        }
        .padding(16)
        .padding(.top, 8)
        .frame(width: 460, height: 360)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true }
        .onChange(of: state.original) { fieldFocused = true }
    }
}
