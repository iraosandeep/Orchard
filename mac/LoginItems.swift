// Startup options. Open at login is a login item (System Settings › Login
// Items) that starts the menu bar, Rewrite and the selection button; the others
// decide how much of the app shows: the Dock icon and the chat window at launch.
import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class LoginItems {
    static let shared = LoginItems()

    private let app = SMAppService.mainApp

    /// Off until the user says yes, either in the first-launch prompt or in Settings.
    var openAtLogin = UserDefaults.standard.bool(forKey: "openAtLogin") {
        didSet {
            UserDefaults.standard.set(openAtLogin, forKey: "openAtLogin")
            UserDefaults.standard.set(true, forKey: "askedOpenAtLogin")
            appError = apply(app, openAtLogin)
            refresh()
        }
    }

    var showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            applyDockPolicy()
        }
    }

    /// Off: Orchard starts in the menu bar only. Launches at login always do.
    var showChatAtLaunch = UserDefaults.standard.object(forKey: "showChatAtLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showChatAtLaunch, forKey: "showChatAtLaunch") }
    }

    private(set) var appStatus: SMAppService.Status = .notRegistered
    private(set) var appError: String?

    /// Run from a translocated (quarantined, unmoved) copy, registering would
    /// point launchd at a temporary path that disappears.
    var translocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// True when this launch came from the login item rather than the user.
    static var launchedAtLogin: Bool {
        NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true
    }

    func start() {
        guard !translocated else { return refresh() }
        appError = apply(app, openAtLogin)
        // v0.4.6 registered the server as a background agent that macOS won't
        // run; remove it so launchd stops retrying and the app runs the server.
        let agent = SMAppService.agent(plistName: "local.orchard.server.plist")
        if agent.status != .notRegistered && agent.status != .notFound { try? agent.unregister() }
        refresh()
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        if !showInDock { NSApp.activate() }  // keep any open window in front
    }

    /// Asks once, on the first launch, instead of quietly adding a login item.
    func askOpenAtLoginIfNeeded() {
        guard !translocated, !UserDefaults.standard.bool(forKey: "askedOpenAtLogin") else { return }
        let a = NSAlert()
        a.messageText = "Open Orchard when you log in?"
        a.informativeText = "Keeps the menu bar, \(rewriteShortcutLabel) Rewrite and the selection button ready in every app. You can change this anytime in Settings."
        a.addButton(withTitle: "Open at Login")
        a.addButton(withTitle: "Not Now")
        NSApp.activate()
        openAtLogin = a.runModal() == .alertFirstButtonReturn
    }

    func refresh() {
        appStatus = app.status
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func apply(_ service: SMAppService, _ on: Bool) -> String? {
        guard !translocated else { return nil }
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
