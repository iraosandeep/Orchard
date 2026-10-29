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
    /// The card opened upwards from the badge, so its bottom row sits under the pointer.
    private(set) var opensUp = false
    private(set) var text = ""
    private(set) var app: NSRunningApplication?

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var host: NSHostingView<SelectionWidgetView>?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var mouseDownAt: NSPoint?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var collapse: Task<Void, Never>?
    /// Where the collapsed badge sits; the card opens from here.
    @ObservationIgnored private var badgeFrame = NSRect.zero
    /// The source app's window, when Accessibility reports it.
    @ObservationIgnored private var windowFrame: NSRect?

    static let badgeSize: CGFloat = 26

    func start() {
        guard monitors.isEmpty else { return }
        let global: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.leftMouseDown, { [weak self] e in self?.mouseDownAt = NSEvent.mouseLocation; self?.hide() }),
            (.leftMouseUp, { [weak self] e in self?.mouseUp(e) }),
            (.keyDown, { [weak self] e in
                guard let self else { return }
                self.hide()
                let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if flags.contains(.command), e.keyCode == 0 {
                    self.scheduleCheck(near: NSEvent.mouseLocation)
                }
            }),
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
        let selectAll = flags.contains(.command) && e.keyCode == 0
        guard flags.contains(.shift) || selectAll else { return }
        scheduleCheck(near: NSEvent.mouseLocation)
    }

    /// The app updates its selection just after the event; check a moment later.
    private func scheduleCheck(near mouse: NSPoint?) {
        pending?.cancel()
        pending = Task { [weak self] in
            for delay in [120, 240, 400] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self else { return }
                if self.check(near: mouse) { return }
            }
        }
    }

    @discardableResult
    private func check(near mouse: NSPoint?) -> Bool {
        guard enabled, AXIsProcessTrusted(),
            let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            !ignored.contains(front.bundleIdentifier ?? ""),
            let sel = Self.readSelection()
        else { return false }
        let trimmed = sel.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        text = sel.text
        app = front
        windowFrame = sel.window
        show(below: sel.bounds, mouse: mouse)
        return true
    }

    /// The focused element's selected text, plus its on-screen bounds and its
    /// window's frame (Cocoa coordinates) when the app reports them.
    static func readSelection() -> (text: String, bounds: NSRect?, window: NSRect?)? {
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
            if AXValueGetValue(rect as! AXValue, .cgRect, &r), r.width > 0 || r.height > 0 {
                bounds = cocoa(r)
            }
        }

        var window: NSRect?
        if let win: AXUIElement = axAttribute(focused, kAXWindowAttribute),
            let pos: AXValue = axAttribute(win, kAXPositionAttribute),
            let size: AXValue = axAttribute(win, kAXSizeAttribute)
        {
            var p = CGPoint.zero
            var s = CGSize.zero
            if AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s), s.width > 0, s.height > 0 {
                window = cocoa(CGRect(origin: p, size: s))
            }
        }
        return (text, bounds, window)
    }

    /// Accessibility measures from the top-left of the main screen; Cocoa from the bottom-left.
    private static func cocoa(_ r: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private static func axAttribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == AXValue.self {
            return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }

    // MARK: Showing and hiding

    private func show(below selection: NSRect?, mouse: NSPoint?) {
        let panel = self.panel ?? makePanel()
        expanded = false
        let size = NSHostingView(rootView: SelectionWidgetView(widget: self)).fittingSize
        // Just below the end of the selection; else next to the pointer.
        var origin: NSPoint
        if let s = selection, NSScreen.screens.contains(where: { $0.frame.intersects(s) }) {
            origin = NSPoint(x: s.maxX - size.width / 2, y: s.minY - size.height - 6)
            if let mouse, !s.insetBy(dx: -200, dy: -200).contains(mouse) {
                origin = NSPoint(x: mouse.x + 8, y: mouse.y - size.height - 8)  // bounds look wrong
            }
        } else if let mouse {
            origin = NSPoint(x: mouse.x + 8, y: mouse.y - size.height - 8)
        } else {
            return
        }
        badgeFrame = clamp(NSRect(origin: origin, size: size))
        panel.setFrame(badgeFrame, display: true)
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
        guard open else {
            panel.setFrame(badgeFrame, display: true)
            return
        }
        // Measure with a fresh view: `host` may not have redrawn as the card yet.
        let size = NSHostingView(rootView: SelectionWidgetView(widget: self)).fittingSize
        // Room to work with: the source window if we know it, kept on screen.
        var area = screen(for: badgeFrame)?.visibleFrame ?? .infinite
        if let w = windowFrame, w.intersects(area) { area = area.intersection(w) }
        // Open downwards from the badge; if it doesn't fit and there's more
        // room above, open upwards. Either way the card covers the badge, so
        // the pointer stays inside it.
        var r = NSRect(x: badgeFrame.minX, y: badgeFrame.maxY - size.height, width: size.width, height: size.height)
        let below = badgeFrame.maxY - area.minY
        let above = area.maxY - badgeFrame.minY
        opensUp = size.height > below && above > below
        if opensUp {
            r.origin.y = badgeFrame.minY
        }
        panel.setFrame(clamp(r), display: true)
    }

    private func screen(for r: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: r.midX, y: r.midY)) } ?? NSScreen.main
    }

    private func clamp(_ r: NSRect) -> NSRect {
        guard let vis = screen(for: r)?.visibleFrame else { return r }
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
                HStack(spacing: 4) {
                    Image(systemName: "leaf.fill")
                    Text("Orchard")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: SelectionWidget.badgeSize)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .contentShape(Capsule())
                .fixedSize()
                .onTapGesture { widget.hover(true) }
            }
        }
        .onHover { widget.hover($0) }
    }

    /// The header always sits where the badge was (under the pointer) and
    /// "Don't Show" at the far end, so opening the card never lands on it.
    private var card: some View {
        VStack(alignment: .leading, spacing: 1) {
            if widget.opensUp {
                dontShow
                actions
                header
            } else {
                header
                actions
                dontShow
            }
        }
        .padding(5)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        Label("Orchard", systemImage: "leaf.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    @ViewBuilder private var actions: some View {
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
    }

    @ViewBuilder private var dontShow: some View {
        if let name = widget.app?.localizedName {
            if !widget.opensUp { Divider().padding(.vertical, 3) }
            Button("Don't Show in \(name)") { widget.ignoreCurrentApp() }
                .buttonStyle(RowStyle(secondary: true))
            if widget.opensUp { Divider().padding(.vertical, 3) }
        }
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
