// Orchard menu-bar launcher: starts `orchard serve` (which keeps fm serve up),
// shows status, and opens the UI. Build with launcher/build.sh.
import AppKit

let addr = ProcessInfo.processInfo.environment["ORCHARD_ADDR"] ?? "127.0.0.1:1977"
let uiURL = URL(string: "http://\(addr)")!
let healthURL = uiURL.appendingPathComponent("api/health")

enum Status { case down, noModel, up }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statusLine = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    let toggle = NSMenuItem(title: "Start Orchard", action: #selector(toggleServer), keyEquivalent: "s")
    var server: Process?
    var status = Status.down
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Orchard", action: #selector(openUI), keyEquivalent: "o")
        menu.addItem(toggle)
        menu.addItem(withTitle: "Edit Tasks…", action: #selector(editTasks), keyEquivalent: "t")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        for i in menu.items where i.action != nil { i.target = self }
        item.menu = menu
        render()

        // Attach to an already-running Orchard, otherwise start one.
        check { [weak self] in
            if $0 == .down { self?.startServer() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
    }

    func menuWillOpen(_ menu: NSMenu) { check() }

    func check(then done: ((Status) -> Void)? = nil) {
        var req = URLRequest(url: healthURL)
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode
            let s: Status = code == 200 ? .up : code == nil ? .down : .noModel
            DispatchQueue.main.async {
                self.status = s
                self.render()
                done?(s)
            }
        }.resume()
    }

    func render() {
        let (symbol, text): (String, String) = switch status {
        case .up: ("leaf.fill", "Orchard running · model ready")
        case .noModel: ("leaf", "Orchard running · fm serve starting…")
        case .down: ("leaf", "Orchard stopped")
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Orchard")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.appearsDisabled = status == .down
        statusLine.title = text
        toggle.title = status == .down ? "Start Orchard" : "Stop Orchard"
        toggle.isEnabled = status == .down || server?.isRunning == true
    }

    func orchardBinary() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["ORCHARD_BIN"],
            Bundle.main.path(forResource: "orchard", ofType: nil),
            "/opt/homebrew/bin/orchard", "/usr/local/bin/orchard",
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func startServer() {
        guard server?.isRunning != true else { return }
        guard let bin = orchardBinary() else {
            alert("Can't find the orchard binary", "Rebuild the app with launcher/build.sh, or set ORCHARD_BIN.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["serve", "-addr", addr]
        // GUI apps get a minimal PATH; make sure `fm` (in /usr/bin) is found.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orchard/orchard.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { _ in DispatchQueue.main.async { self.check() } }
        do {
            try p.run()
            server = p
        } catch {
            alert("Couldn't start Orchard", error.localizedDescription)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.check() }
    }

    func stopServer() {
        guard let p = server, p.isRunning else { return }
        p.terminate() // SIGTERM: orchard stops the fm serve it started
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        server = nil
    }

    @objc func toggleServer() {
        if status == .down { startServer() } else { stopServer(); check() }
    }

    @objc func openUI() {
        if status == .down {
            startServer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSWorkspace.shared.open(uiURL) }
        } else {
            NSWorkspace.shared.open(uiURL)
        }
    }

    @objc func editTasks() {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orchard/tasks.yaml")
        if FileManager.default.fileExists(atPath: f.path) {
            NSWorkspace.shared.open(f)
        } else {
            alert("No tasks.yaml yet", "Start Orchard once to create ~/.orchard/tasks.yaml.")
        }
    }

    @objc func quit() {
        stopServer()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ note: Notification) { stopServer() }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
