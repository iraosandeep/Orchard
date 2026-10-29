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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.shared.check(userInitiated: true) } }
            }
        }

        Settings { SettingsView() }
            .windowResizability(.contentMinSize)

        MenuBarExtra("Orchard", systemImage: "leaf") { MenuBarContent() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        // Set the Dock / ⌘Tab icon explicitly. macOS caches app icons by bundle,
        // so a copy first launched before it had an icon keeps showing the
        // generic one there even though Finder shows the right icon.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        let atLogin = LoginItems.launchedAtLogin
        MainActor.assumeIsolated {
            LoginItems.shared.applyDockPolicy()
            LoginItems.shared.start()
            NSApp.servicesProvider = TextServices.shared
            NSUpdateDynamicServices()
            RewriteController.shared.start()
            SelectionWidget.shared.start()
            Services.shared.start()
            Updater.shared.start()
        }
        // Opened at login, or set to: start quietly in the menu bar, without the chat window.
        let showChat = MainActor.assumeIsolated { LoginItems.shared.showChatAtLaunch }
        if atLogin || !showChat {
            DispatchQueue.main.async {
                for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true {
                    w.close()
                }
            }
        }
        if !atLogin {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { LoginItems.shared.askOpenAtLoginIfNeeded() }
            }
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
