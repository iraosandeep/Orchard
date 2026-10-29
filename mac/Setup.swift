import ServiceManagement
import SwiftUI

/// Settings (⌘,): everything on one resizable page, every dependency with a
/// one-click fix where macOS allows.
struct SettingsView: View {
    let s = Services.shared
    @Bindable var rewrite = RewriteController.shared.state
    @AppStorage("systemPrompt") private var systemPrompt = defaultSystemPrompt

    var body: some View {
        Form {
            Section {
                StatusRow("Apple Intelligence", ok: s.modelReason == nil,
                          detail: s.modelReason ?? "Ready · on-device, \(Assistant.contextSize)-token context") {
                    Button("Open Settings…") { Services.openAppleIntelligenceSettings() }
                }
            } header: {
                Text("Model")
            } footer: {
                if s.modelReason != nil {
                    Text("Chat and Rewrite need Apple Intelligence. Turn it on under Apple Intelligence & Siri; the model may take a while to download. Orchard picks it up automatically.")
                }
            }

            Section {
                TextEditor(text: $systemPrompt)
                    .font(.body)
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                HStack {
                    Spacer()
                    Button("Reset") { systemPrompt = defaultSystemPrompt }
                        .disabled(systemPrompt == defaultSystemPrompt)
                }
            } header: {
                Text("Chat Instructions")
            } footer: {
                Text("The system prompt for all your chats. / tasks use their own instructions.")
            }

            Section("Rewrite Selection") {
                LabeledContent("Shortcut") { ShortcutRecorder() }
                Text(ShortcutStore.shared.message
                     ?? "Click the shortcut to change it. If nothing happens when you press it, another app may be using the same keys. Pick a different one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SelectionWidgetToggle()
                StatusRow("Accessibility", ok: s.accessibility,
                          detail: s.accessibility ? "Allowed" : "Needed to copy and replace text in other apps") {
                    HStack {
                        Button("Reset") { Keys.resetTrust(); _ = Keys.requestTrust() }
                            .help("Use this if Orchard already looks switched on in System Settings")
                        Button("Allow…") { _ = Keys.requestTrust(); Keys.openAccessibilitySettings() }
                    }
                }
            }

            Section {
                Picker("Translate to", selection: $rewrite.translateTo) {
                    ForEach(RewriteState.languages, id: \.self) { Text($0) }
                }
            } header: {
                Text("Translate")
            } footer: {
                Text("Used by Translate (⌘5), the selection button and Services › Translate with Orchard.")
            }

            BackgroundSection()

            UpdatesSection()

            Section("Command Line") {
                StatusRow("orchard", ok: s.cliPath != nil,
                          detail: s.cliMessage ?? s.cliPath ?? "Not installed. Lets you run tasks like 'orchard run commit' from scripts and git hooks.") {
                    Button("Install") { s.installCLI() }
                }
            }

            Section {
                StatusRow("fm tool", ok: s.fmInstalled,
                          detail: s.fmInstalled ? Services.fmPath : "Not found. It ships with macOS 26 or later.") { EmptyView() }
                if s.fmInstalled {
                    StatusRow("fm license", ok: s.fmLicense == true,
                              detail: s.fmLicense == nil ? "Checking…" : s.fmLicense! ? "Agreed" : "Not agreed yet. fm serve won't run until you agree.") {
                        Button("Review & Agree…") { s.openLicenseInTerminal() }
                    }
                }
                StatusRow("Orchard server", ok: isRunning(fmToo: true), detail: s.serverSummary) {
                    if s.ownsServer || !isRunning(fmToo: false) {
                        Button(isRunning(fmToo: false) ? "Restart" : "Start") { s.restartServer() }
                    }
                }
                if isRunning(fmToo: false) {
                    LabeledContent("Tasks in browser") {
                        Link(s.webURL.absoluteString, destination: s.webURL)
                    }
                }
            } header: {
                Text("Tasks & fm serve")
            } footer: {
                Text("Tasks and `orchard run` use fm serve, which Orchard starts and restarts for you. Chat doesn't need it.")
            }

            Section("Help & Feedback") {
                FeedbackRow("Report a Bug", systemImage: "ladybug") {
                    NSWorkspace.shared.open(Feedback.newIssue(bug: true))
                }
                FeedbackRow("Request a Feature", systemImage: "lightbulb") {
                    NSWorkspace.shared.open(Feedback.newIssue(bug: false))
                }
                EmailRow()
                FeedbackRow("Release Notes", systemImage: "doc.text") {
                    NSWorkspace.shared.open(Feedback.repo.appending(path: "releases"))
                }
                FeedbackRow("Show Logs in Finder", systemImage: "folder", external: false) {
                    Feedback.showLogs()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity,
               minHeight: 320, idealHeight: 705, maxHeight: .infinity)
        .background(ResizableWindow())
        .task { await s.refresh() }
    }

    func isRunning(fmToo: Bool) -> Bool {
        if case .running(let fmUp) = s.server { return fmToo ? fmUp : true }
        return false
    }
}

/// A System Settings–style row: icon, title, and an arrow; the whole row is clickable.
private struct FeedbackRow: View {
    let title: String
    let systemImage: String
    var external = true
    let action: () -> Void

    init(_ title: String, systemImage: String, external: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.external = external
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: external ? "arrow.up.right" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Email" with the address underneath and a copy icon that confirms with a checkmark.
private struct EmailRow: View {
    @ViewState private var copied = false

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Email")
                    Text(Feedback.email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } icon: {
                Image(systemName: "envelope")
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Feedback.email, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(copied ? "Copied" : "Copy email address")
        }
    }
}

/// SwiftUI creates the Settings window without a resize handle, and for
/// stretchy content it opens it at its stock 900×450. Make it resizable,
/// restore the size the user last chose, or else open at a size that fits.
private struct ResizableWindow: NSViewRepresentable {
    static let autosave = "OrchardSettings"
    static let defaultSize = NSSize(width: 520, height: 705)

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            guard let w = window else { return }
            w.styleMask.insert(.resizable)
            // After SwiftUI has applied its own size for this showing.
            DispatchQueue.main.async {
                if !w.setFrameUsingName(ResizableWindow.autosave) {
                    w.setContentSize(ResizableWindow.defaultSize)
                    w.center()
                }
                w.setFrameAutosaveName(ResizableWindow.autosave)
            }
        }
    }
}

/// Links to GitHub issues (pre-filled with what a bug report needs) and logs.
enum Feedback {
    static let repo = URL(string: "https://github.com/iraosandeep/Orchard")!
    static let email = "iraosandeep.dev@gmail.com"

    /// Versions and status, so a report doesn't need a round trip to ask for them.
    @MainActor static var env: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return """
            Orchard \(Updater.shared.current) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \
            model: \(Services.shared.modelReason ?? "ready") · server: \(Services.shared.serverSummary)
            """
    }

    @MainActor static func newIssue(bug: Bool) -> URL {
        let body = bug
            ? "**What happened?**\n\n\n**What did you expect?**\n\n\n**Steps to reproduce**\n1. \n\n---\n\(env)"
            : "**What would you like Orchard to do?**\n\n\n**Why would it help?**\n\n\n---\n\(env)"
        var c = URLComponents(url: repo.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "labels", value: bug ? "bug" : "enhancement"),
            URLQueryItem(name: "body", value: body),
        ]
        return c.url!
    }

    static func showLogs() {
        let dir = ProcessInfo.processInfo.environment["ORCHARD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orchard")
        let log = dir.appendingPathComponent("orchard.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }
}

/// A check or warning icon, a title and detail, and a fix button when not OK.
private struct StatusRow<Fix: View>: View {
    let title: String
    let ok: Bool
    let detail: String
    @ViewBuilder let fix: Fix

    init(_ title: String, ok: Bool, detail: String, @ViewBuilder fix: () -> Fix) {
        self.title = title
        self.ok = ok
        self.detail = detail
        self.fix = fix()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if !ok { fix }
        }
    }
}

/// Banner shown above the chat when the model can't run.
struct ModelBanner: View {
    let s = Services.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let reason = s.modelReason {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(reason)
                Spacer()
                Button("Open Settings…") { Services.openAppleIntelligenceSettings() }
                Button("Details") { openSettings() }
            }
            .font(.callout)
            .padding(10)
            .background(.orange.opacity(0.12))
        }
    }
}

/// Open at login (shown in System Settings › Login Items) and how much of the
/// app shows at launch.
struct BackgroundSection: View {
    @Bindable var l = LoginItems.shared

    var body: some View {
        Section {
            Toggle(isOn: $l.openAtLogin) {
                Text("Open Orchard at login")
                Text(detail(l.appStatus, l.appError,
                            on: "The menu bar, \(rewriteShortcutLabel) Rewrite and the selection button start when you log in."))
            }
            Toggle(isOn: $l.showChatAtLaunch) {
                Text("Open the chat window when Orchard starts")
                Text("Off: Orchard starts in the menu bar only. It always does when opened at login.")
            }
            Toggle(isOn: $l.showInDock) {
                Text("Show in Dock")
                Text("Off: Orchard lives in the menu bar only, and stays out of the Dock and ⌘Tab.")
            }
            if l.translocated {
                Text("Move Orchard to your Applications folder and reopen it to turn on Open at Login.")
                    .font(.caption).foregroundStyle(.orange)
            } else if l.appStatus == .requiresApproval {
                Button("Allow in Login Items…") { l.openSystemSettings() }
            }
        } header: {
            Text("Startup")
        }
        .onAppear { l.refresh() }
    }

    private func detail(_ status: SMAppService.Status, _ error: String?, on: String) -> String {
        if let error { return error }
        return status == .requiresApproval ? "Needs your approval in System Settings › Login Items." : on
    }
}

/// On/off for the button that appears next to selected text, and a way to
/// bring it back in apps it was hidden in.
struct SelectionWidgetToggle: View {
    @Bindable var w = SelectionWidget.shared

    var body: some View {
        Toggle(isOn: $w.enabled) {
            Text("Show Orchard button when you select text")
            Text(w.ignored.isEmpty
                 ? "Hover it for the same actions as the shortcut."
                 : "Hidden in \(w.ignored.count) app\(w.ignored.count == 1 ? "" : "s").")
        }
        if !w.ignored.isEmpty {
            Button("Show in All Apps Again") { w.clearIgnored() }
        }
    }
}

struct MenuBarContent: View {
    let s = Services.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let r = Updater.shared.available {
            Button("Update to Orchard \(r.version)…") { Updater.shared.prompt(r) }
            Divider()
        }
        Text(s.modelReason == nil ? "Model ready" : "Model unavailable")
        Text("Server: \(s.serverSummary)")
        Divider()
        Button("Open Chat") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Button("Rewrite Selection  \(rewriteShortcutLabel)") {
            Task { await RewriteController.shared.trigger() }
        }
        Toggle("Show Button on Selected Text", isOn: Bindable(SelectionWidget.shared).enabled)
        Toggle("Open at Login", isOn: Bindable(LoginItems.shared).openAtLogin)
        Divider()
        Button(s.needsSetup ? "Settings… ⚠︎" : "Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button("Check for Updates…") { Task { await Updater.shared.check(userInitiated: true) } }
        Divider()
        // The native app covers everything; the browser UI is a fallback.
        Button("Open Tasks in Browser") { NSWorkspace.shared.open(s.webURL) }
            .disabled({ if case .running = s.server { false } else { true } }())
        Button("Quit Orchard") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct UpdatesSection: View {
    let u = Updater.shared

    var body: some View {
        Section("Updates") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orchard \(u.current)")
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch u.state {
                case .available(let r):
                    Button("Install \(r.version)") { Task { await u.install(r) } }
                        .buttonStyle(.borderedProminent)
                case .checking, .installing:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check Now") { Task { await u.check(userInitiated: true) } }
                }
            }
            Toggle("Check for updates automatically", isOn: Binding(get: { u.autoCheck }, set: { u.autoCheck = $0 }))
        }
    }

    var status: String {
        switch u.state {
        case .idle: u.isDevBuild ? "Development build" : "Not checked yet"
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .available(let r): "Version \(r.version) is available"
        case .installing(let step): step
        case .failed(let m): m
        }
    }
}
