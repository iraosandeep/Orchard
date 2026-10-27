// Startup and background options. Two are background items, as listed in
// System Settings › Login Items: the app itself opens at login (menu bar,
// Rewrite, selection button), and the bundled Orchard server runs as a launchd
// agent that keeps going after the app quits. The others decide how much of
// the app shows: the Dock icon and the chat window at launch.
import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class LoginItems {
    static let shared = LoginItems()

    nonisolated static let agentLabel = "local.orchard.server"
    private let agent = SMAppService.agent(plistName: "\(agentLabel).plist")
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

    var backgroundServer = UserDefaults.standard.object(forKey: "backgroundServer") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(backgroundServer, forKey: "backgroundServer")
            let services = Services.shared
            if backgroundServer { services.stopServer() }  // free the port for the agent
            agentError = apply(agent, backgroundServer)
            refresh()
            Task {
                // Turned off: launchd stops the agent's server; let it release
                // the port before the app starts its own.
                if !backgroundServer {
                    for _ in 0..<50 where await Services.healthStatus(services.webURL) != nil {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                await services.ensureServer()
            }
        }
    }

    private(set) var appStatus: SMAppService.Status = .notRegistered
    private(set) var agentStatus: SMAppService.Status = .notRegistered
    private(set) var appError: String?
    private(set) var agentError: String?

    /// Run from a translocated (quarantined, unmoved) copy, registering would
    /// point launchd at a temporary path that disappears.
    var translocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    /// launchd runs the server; the app shouldn't start its own. The agent
    /// listens on the default address, so an ORCHARD_ADDR override opts out.
    var agentActive: Bool {
        backgroundServer && agentStatus == .enabled && Services.shared.addr == "127.0.0.1:1977"
    }

    /// True when this launch came from the login item rather than the user.
    static var launchedAtLogin: Bool {
        NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true
    }

    func start() {
        guard !translocated else { return refresh() }
        appError = apply(app, openAtLogin)
        agentError = apply(agent, backgroundServer)
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
        agentStatus = agent.status
    }

    /// Restarts the agent's server (launchd relaunches it right away).
    func restartAgent() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.agentLabel)"]
        try? p.run()
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
