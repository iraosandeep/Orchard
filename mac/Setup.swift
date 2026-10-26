import SwiftUI

/// "Setup & Status": every dependency with a one-click fix where macOS allows.
struct SetupView: View {
    let s = Services.shared

    var body: some View {
        Form {
            Section {
                row("Apple Intelligence", ok: s.modelReason == nil,
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
                row("fm tool", ok: s.fmInstalled,
                    detail: s.fmInstalled ? Services.fmPath : "Not found. It ships with macOS 26 or later.") { EmptyView() }
                if s.fmInstalled {
                    row("fm license", ok: s.fmLicense == true,
                        detail: s.fmLicense == nil ? "Checking…" : s.fmLicense! ? "Agreed" : "Not agreed yet. fm serve won't run until you agree.") {
                        Button("Review & Agree…") { s.openLicenseInTerminal() }
                    }
                }
                row("Orchard server", ok: isRunning(fmToo: true), detail: s.serverSummary) {
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
                Text("The Tasks screen and `orchard run` use fm serve, which Orchard starts and restarts for you. Chat doesn't need it.")
            }

            Section("Rewrite Selection") {
                LabeledContent("Shortcut") { ShortcutRecorder() }
                SelectionWidgetToggle()
                Text(ShortcutStore.shared.message
                     ?? "Click the shortcut to change it. If nothing happens when you press it, another app may be using the same keys. Pick a different one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                row("Accessibility", ok: s.accessibility,
                    detail: s.accessibility ? "Allowed" : "Needed to copy and replace text in other apps") {
                    HStack {
                        Button("Reset") { Keys.resetTrust(); _ = Keys.requestTrust() }
                            .help("Use this if Orchard already looks switched on in Settings")
                        Button("Allow…") { _ = Keys.requestTrust(); Keys.openAccessibilitySettings() }
                    }
                }
            }

            UpdatesSection()

            Section("Command Line") {
                row("orchard", ok: s.cliPath != nil,
                    detail: s.cliMessage ?? s.cliPath ?? "Not installed. Lets you run tasks like 'orchard run commit' from scripts and git hooks.") {
                    Button("Install") { s.installCLI() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task { await s.refresh() }
    }

    func isRunning(fmToo: Bool) -> Bool {
        if case .running(let fmUp) = s.server { return fmToo ? fmUp : true }
        return false
    }

    @ViewBuilder
    func row(_ title: String, ok: Bool, detail: String, @ViewBuilder fix: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if !ok { fix() }
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
        Button("Open Tasks in Browser") { NSWorkspace.shared.open(s.webURL) }
            .disabled({ if case .running = s.server { false } else { true } }())
        Button("Rewrite Selection  \(rewriteShortcutLabel)") {
            Task { await RewriteController.shared.trigger() }
        }
        Toggle("Show Button on Selected Text", isOn: Bindable(SelectionWidget.shared).enabled)
        Divider()
        Button(s.needsSetup ? "Setup & Status… ⚠︎" : "Setup & Status…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button("Check for Updates…") { Task { await Updater.shared.check(userInitiated: true) } }
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
