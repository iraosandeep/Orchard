// Grammarly-style selection widget: when you select text in another app, a
// small leaf button appears next to it. Hovering it shows the same actions as
// the Rewrite shortcut; picking one opens the Rewrite window already running.
//
// The selection is read through the Accessibility API (the same permission
// Rewrite uses), so the clipboard is never touched just to show the button.
import AppKit
import ApplicationServices
import Observation
import SwiftUI

@MainActor @Observable
final class SelectionWidget {
    static let shared = SelectionWidget()

    /// Shown on selection (Setup and the menu bar can turn it off).
    var enabled = UserDefaults.standard.object(forKey: "selectionWidget") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "selectionWidget")
            if !enabled { hide() }
        }
    }

    /// Bundle IDs of apps where the widget never shows.
    private(set) var ignored = Set(UserDefaults.standard.stringArray(forKey: "selectionWidgetIgnored") ?? [])

    var expanded = false
    private(set) var text = ""
    private(set) var app: NSRunningApplication?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var host: NSHostingView<SelectionWidgetView>?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var mouseDownAt: NSPoint?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var collapse: Task<Void, Never>?

    static let badgeSize: CGFloat = 26

    func start() {
        guard monitors.isEmpty else { return }
        let global: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] e in self?.mouseDownAt = NSEvent.mouseLocation; self?.hide() }),
            (.leftMouseUp, { [weak self] e in self?.mouseUp(e) }),
            (.keyDown, { [weak self] _ in self?.hide() }),
            (.keyUp, { [weak self] e in self?.keyUp(e) }),
            (.scrollWheel, { [weak self] _ in self?.hide() }),
        ]
        for (mask, handler) in global {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { e in
                MainActor.assumeIsolated { handler(e) }
            }) {
                monitors.append(m)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                SelectionWidget.shared.hide()
                // Electron apps (Slack, VS Code, Notion…) only expose their
                // text to Accessibility once asked to.
                if let pid = app?.processIdentifier {
                    AXUIElementSetAttributeValue(
                        AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
                }
            }
        }
    }

    // MARK: Detecting a selection

    private func mouseUp(_ e: NSEvent) {
        // Only after a drag or a double/triple click: a plain click doesn't select.
        let down = mouseDownAt ?? NSEvent.mouseLocation
        let up = NSEvent.mouseLocation
        let dragged = hypot(up.x - down.x, up.y - down.y) > 4
        guard dragged || e.clickCount >= 2 else { return }
        scheduleCheck(near: up)
    }

    private func keyUp(_ e: NSEvent) {
        // Shift+arrows/Home/End extend a selection; ⌘A selects all.
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let selectAll = flags.contains(.command) && e.charactersIgnoringModifiers?.lowercased() == "a"
        guard flags.contains(.shift) || selectAll else { return }
        scheduleCheck(near: nil)
    }

    /// The app updates its selection just after the event; check a moment later.
    private func scheduleCheck(near mouse: NSPoint?) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.check(near: mouse)
        }
    }

    private func check(near mouse: NSPoint?) {
        guard enabled, AXIsProcessTrusted(),
            let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            !ignored.contains(front.bundleIdentifier ?? ""),
            let sel = Self.readSelection()
        else { return }
        let trimmed = sel.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = sel.text
        app = front
        show(below: sel.bounds, mouse: mouse)
    }

    /// The focused element's selected text, and its on-screen bounds (Cocoa
    /// coordinates) when the app reports them.
    static func readSelection() -> (text: String, bounds: NSRect?)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)  // never hang on a busy app
        guard let focused: AXUIElement = axAttribute(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        let subrole: String? = axAttribute(focused, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) { return nil }  // passwords
        guard let text: String = axAttribute(focused, kAXSelectedTextAttribute), !text.isEmpty else { return nil }

        var bounds: NSRect?
        var range: CFTypeRef?
        var rect: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
            let range,
            AXUIElementCopyParameterizedAttributeValue(
                focused, kAXBoundsForRangeParameterizedAttribute as CFString, range, &rect) == .success,
            let rect, CFGetTypeID(rect) == AXValueGetTypeID()
        {
            var r = CGRect.zero
            if AXValueGetValue(rect as! AXValue, .cgRect, &r), r.width > 0 || r.height > 0,
                let primary = NSScreen.screens.first
            {
                // Accessibility measures from the top-left of the main screen.
                bounds = NSRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
            }
        }
        return (text, bounds)
    }

    private static func axAttribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }

    // MARK: Showing and hiding

    private func show(below selection: NSRect?, mouse: NSPoint?) {
        let panel = self.panel ?? makePanel()
        expanded = false
        let size = Self.badgeSize
        // Just below the end of the selection; else next to the pointer.
        var origin: NSPoint
        if let s = selection, NSScreen.screens.contains(where: { $0.frame.intersects(s) }) {
            origin = NSPoint(x: s.maxX - size / 2, y: s.minY - size - 6)
            if let mouse, !s.insetBy(dx: -200, dy: -200).contains(mouse) {
                origin = NSPoint(x: mouse.x + 8, y: mouse.y - size - 8)  // bounds look wrong
            }
        } else if let mouse {
            origin = NSPoint(x: mouse.x + 8, y: mouse.y - size - 8)
        } else {
            return  // keyboard selection in an app that doesn't report bounds
        }
        panel.setFrame(clamp(NSRect(origin: origin, size: NSSize(width: size, height: size))), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        pending?.cancel()
        collapse?.cancel()
        expanded = false
        panel?.orderOut(nil)
    }

    /// Hovering the badge opens the action card; leaving closes it again.
    func hover(_ inside: Bool) {
        collapse?.cancel()
        if inside {
            if !expanded { setExpanded(true) }
        } else if expanded {
            collapse = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                self?.setExpanded(false)
            }
        }
    }

    private func setExpanded(_ open: Bool) {
        guard let panel, let host else { return }
        expanded = open
        host.layoutSubtreeIfNeeded()
        let size = open ? host.fittingSize : NSSize(width: Self.badgeSize, height: Self.badgeSize)
        // Keep the top-left corner (where the badge is) in place.
        let top = panel.frame.maxY
        panel.setFrame(
            clamp(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height)),
            display: true)
    }

    private func clamp(_ r: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: r.midX, y: r.midY)) } ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return r }
        var r = r
        r.origin.x = min(max(r.minX, vis.minX + 4), vis.maxX - r.width - 4)
        r.origin.y = min(max(r.minY, vis.minY + 4), vis.maxY - r.height - 4)
        return r
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.badgeSize, height: Self.badgeSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let h = NSHostingView(rootView: SelectionWidgetView(widget: self))
        h.sizingOptions = []
        p.contentView = h
        panel = p
        host = h
        return p
    }

    // MARK: Actions

    func run(_ action: RewriteController.Action?) {
        let text = self.text
        let app = self.app
        hide()
        RewriteController.shared.open(selection: text, from: app, action: action)
    }

    func ignoreCurrentApp() {
        guard let id = app?.bundleIdentifier else { return }
        ignored.insert(id)
        UserDefaults.standard.set(Array(ignored), forKey: "selectionWidgetIgnored")
        hide()
    }

    func clearIgnored() {
        ignored = []
        UserDefaults.standard.removeObject(forKey: "selectionWidgetIgnored")
    }
}

// MARK: - Views

struct SelectionWidgetView: View {
    let widget: SelectionWidget

    var body: some View {
        Group {
            if widget.expanded {
                card
            } else {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: SelectionWidget.badgeSize, height: SelectionWidget.badgeSize)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.separator))
                    .contentShape(Circle())
                    .onTapGesture { widget.hover(true) }
            }
        }
        .onHover { widget.hover($0) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Orchard", systemImage: "leaf.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            ForEach(Array(RewriteState.presets.enumerated()), id: \.offset) { _, p in
                Button(p.name) { widget.run(.instruction(p.instruction)) }
                    .buttonStyle(RowStyle())
            }
            Divider().padding(.vertical, 3)
            let lang = RewriteController.shared.state.translateTo
            HStack(spacing: 0) {
                Button("Translate to \(lang)") { widget.run(.translate(lang)) }
                    .buttonStyle(RowStyle())
                Menu {
                    ForEach(RewriteState.languages, id: \.self) { l in
                        Button(l) { widget.run(.translate(l)) }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 6)
                .help("Other languages")
            }
            Button("Rewrite…") { widget.run(nil) }
                .buttonStyle(RowStyle())
                .help("Open the Rewrite window to describe your own change")
            if let name = widget.app?.localizedName {
                Divider().padding(.vertical, 3)
                Button("Don't Show in \(name)") { widget.ignoreCurrentApp() }
                    .buttonStyle(RowStyle(secondary: true))
            }
        }
        .padding(5)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A menu-like row: full width, highlighted under the pointer.
private struct RowStyle: ButtonStyle {
    var secondary = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, secondary: secondary)
    }

    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        let secondary: Bool
        @ViewState private var hovered = false

        var body: some View {
            configuration.label
                .font(secondary ? .callout : .body)
                .foregroundStyle(hovered ? AnyShapeStyle(.white) : secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(hovered ? Color.accentColor : .clear))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}
