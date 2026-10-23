// Orchard for Mac: one app for everything. A native chat window, Rewrite
// Selection (⌃⌥R) in any app, and a menu-bar item. On launch it starts the
// bundled Orchard server (web Tasks UI + API), which keeps `fm serve` running.
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
            CommandGroup(replacing: .appSettings) {
                SetupCommand()
            }
        }

        Settings { SetupView() }

        MenuBarExtra("Orchard", systemImage: "leaf") { MenuBarContent() }
    }
}

struct SetupCommand: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button("Setup & Status…") { openSettings() }.keyboardShortcut(",")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        MainActor.assumeIsolated {
            RewriteController.shared.start()
            Services.shared.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false // keep running for the menu bar, the server and the rewrite shortcut
    }

    func applicationWillTerminate(_ note: Notification) {
        MainActor.assumeIsolated { Services.shared.stopServer() }
    }
}

/// SwiftUI's `@State` is a macro in the macOS 27 SDK, and its plugin only ships
/// with Xcode. This alias uses the underlying property wrapper directly so the
/// app builds with just the Command Line Tools.
typealias ViewState = SwiftUI.State
