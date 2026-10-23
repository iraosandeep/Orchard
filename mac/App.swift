// Orchard for Mac: a native chat window for Apple's on-device model, plus
// Rewrite Selection (⌃⌥R) in any app.
import Combine
import SwiftUI

@main
struct OrchardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ViewState private var model = ChatModel()

    var body: some Scene {
        Window("Orchard", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 420)
        }
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { model.newChat() }.keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("Rewrite Selection in Other Apps…  \(rewriteShortcutLabel)") {
                    Task { await RewriteController.shared.trigger() }
                }
            }
        }
        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        MainActor.assumeIsolated { RewriteController.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false // keep running so the rewrite shortcut works
    }
}

struct SettingsView: View {
    @ViewState private var trusted = Keys.trusted
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Rewrite Selection") {
                LabeledContent("Shortcut", value: rewriteShortcutLabel)
                LabeledContent("Accessibility") {
                    if trusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { _ = Keys.requestTrust(); Keys.openAccessibilitySettings() }
                    }
                }
                Text("Select text in any app and press \(rewriteShortcutLabel). Pick an instruction and Orchard replaces the selection. Your clipboard is restored afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Model") {
                LabeledContent("Status", value: Assistant.unavailableReason ?? "Ready (on-device)")
                LabeledContent("Context", value: "\(Assistant.contextSize) tokens")
                LabeledContent("History", value: "~/.orchard/orchard.db (shared with the web UI)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onReceive(timer) { _ in trusted = Keys.trusted }
    }
}

/// SwiftUI's `@State` is a macro in the macOS 27 SDK, and its plugin only ships
/// with Xcode. This alias uses the underlying property wrapper directly so the
/// app builds with just the Command Line Tools.
typealias ViewState = SwiftUI.State
