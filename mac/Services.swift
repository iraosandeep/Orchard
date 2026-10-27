// Everything the app starts and checks on launch: Apple Intelligence, the fm
// CLI and its license, the bundled Orchard server (web Tasks UI + API, which
// in turn keeps `fm serve` running), and the `orchard` command-line tool.
import AppKit
import Observation

@MainActor @Observable
final class Services {
    static let shared = Services()

    enum Server: Equatable {
        case stopped, starting
        case running(fmUp: Bool)
        case failed(String)
    }

    let addr = ProcessInfo.processInfo.environment["ORCHARD_ADDR"] ?? "127.0.0.1:1977"
    var webURL: URL { URL(string: "http://\(addr)")! }
    nonisolated static let fmPath = "/usr/bin/fm"

    var server: Server = .stopped
    var modelReason: String? = Assistant.unavailableReason
    var fmInstalled = FileManager.default.isExecutableFile(atPath: fmPath)
    var fmLicense: Bool?  // nil until checked
    var accessibility = Keys.trusted
    var cliPath: String?
    var cliMessage: String?

    private var process: Process?
    private var stopping = false
    private var timer: Timer?

    /// Something the user has to fix before everything works.
    var needsSetup: Bool { modelReason != nil || !fmInstalled || fmLicense == false }

    var serverSummary: String {
        switch server {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running(true): "Running · fm serve ready"
        case .running(false): "Running · waiting for fm serve"
        case .failed(let m): m
        }
    }

    func start() {
        Task {
            await refresh()
            // A server from another Orchard version (e.g. orphaned when an
            // older app was killed) would serve stale code; replace it.
            if case .running = server, process == nil,
                await Self.serverVersion(webURL) != Self.appVersion
            {
                await stopStaleServer()
            }
            await ensureServer()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in await Services.shared.refresh() }
        }
    }

    /// Starts the server unless one is up. When the background agent is on,
    /// launchd runs it, so wait for that instead of starting a second one.
    func ensureServer() async {
        await refresh()
        if LoginItems.shared.agentActive {
            var waited = 0
            while waited < 30, case .stopped = server {
                try? await Task.sleep(for: .milliseconds(500))
                await refresh()
                waited += 1
            }
            if server == .stopped {
                // Something else (e.g. a hung server from an old copy) may hold
                // the port; clear it so launchd's next try can bind.
                await stopStaleServer()
                LoginItems.shared.restartAgent()
                server = .starting
            }
        } else if server == .stopped {
            startServer()
        }
    }

    func refresh() async {
        // Agent approved in System Settings after the app started its own
        // server: hand the port over, or launchd keeps relaunching the agent.
        LoginItems.shared.refresh()
        if LoginItems.shared.agentActive, process?.isRunning == true { stopServer() }
        modelReason = Assistant.unavailableReason
        accessibility = Keys.trusted
        fmInstalled = FileManager.default.isExecutableFile(atPath: Self.fmPath)
        if fmInstalled, fmLicense != true { fmLicense = await Self.licenseAgreed() }
        cliPath = Self.findCLI()
        switch await Self.healthStatus(webURL) {
        case 200?: server = .running(fmUp: true)
        case _?: server = .running(fmUp: false)
        case nil:
            if process?.isRunning == true {
                server = .starting
            } else if case .failed = server {
            } else {
                server = .stopped
            }
        }
    }

    // MARK: Orchard server

    var bundledBinary: String? {
        Bundle.main.path(forResource: "orchard", ofType: nil)
    }

    func startServer() {
        guard process?.isRunning != true else { return }
        guard let bin = bundledBinary else {
            server = .failed(
                "Orchard server binary missing from the app bundle; rebuild with ./build.sh")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["serve", "-addr", addr]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orchard")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("orchard.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                let s = Services.shared
                if !s.stopping && code != 0 {
                    s.server = .failed(
                        "Orchard server exited (code \(code)). See ~/.orchard/orchard.log")
                }
                s.process = nil
            }
        }
        do {
            stopping = false
            try p.run()
            process = p
            server = .starting
        } catch {
            server = .failed("Couldn't start Orchard server: \(error.localizedDescription)")
        }
    }

    /// Stops the server if this app started it (which also stops the fm
    /// serve it started).
    func stopServer() {
        guard let p = process, p.isRunning else { return }
        stopping = true
        p.terminate()
        let deadline = Date().addingTimeInterval(4)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        process = nil
        server = .stopped
    }

    func restartServer() {
        if LoginItems.shared.agentActive {
            LoginItems.shared.restartAgent()
            server = .starting
            return
        }
        stopServer()
        if case .running = server { return }  // someone else's server; leave it
        startServer()
    }

    var ownsServer: Bool { process?.isRunning == true || LoginItems.shared.agentActive }

    // MARK: Setup actions

    static func openAppleIntelligenceSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:",
        ]
        for u in urls where NSWorkspace.shared.open(URL(string: u)!) { return }
    }

    /// Opens `sudo fm license` in Terminal so the user reads and agrees to the
    /// terms themselves. fm requires root (the agreement is machine-wide) and
    /// a real TTY, so this can't be answered from inside the app.
    func openLicenseInTerminal() {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(
            "orchard-fm-license.command")
        let body = """
            #!/bin/sh
            echo "Orchard needs you to agree to Apple's Foundation Models terms."
            echo "Enter your Mac password, read the terms, then type yes."
            echo
            sudo \(Self.fmPath) license
            echo
            if \(Self.fmPath) license --status 2>/dev/null | grep -q "^Agreed to"; then
              echo "Done. You can close this window and return to Orchard."
            else
              echo "Not agreed yet. Use Review & Agree… in Orchard's Setup to try again."
            fi
            """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
        fmLicense = nil  // re-check on the next refresh
    }

    static func licenseAgreed() async -> Bool {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: fmPath)
            p.arguments = ["license", "--status"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            guard (try? p.run()) != nil else { return false }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).lowercased()
            return p.terminationStatus == 0 && text.contains("agreed to")
                && !text.contains("not agreed")
        }.value
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }

    /// The running server's version, or nil if it's unreachable or too old to say.
    static func serverVersion(_ base: URL) async -> String? {
        var req = URLRequest(url: base.appendingPathComponent("api/health"))
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["version"] as? String
    }

    /// Stops an Orchard server this app didn't start that's listening on our
    /// port. Only `orchard` processes are touched.
    func stopStaleServer() async {
        let port = addr.split(separator: ":").last.map(String.init) ?? "1977"
        let base = webURL
        await Task.detached {
            let lsof = Process()
            lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsof.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
            let out = Pipe()
            lsof.standardOutput = out
            lsof.standardError = FileHandle.nullDevice
            guard (try? lsof.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            lsof.waitUntilExit()
            for pid in String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap({
                Int32($0)
            }) {
                var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0,
                    URL(fileURLWithPath: String(cString: buf)).lastPathComponent == "orchard"
                else { continue }
                kill(pid, SIGTERM)
            }
        }.value
        var waited = 0
        while waited < 40, await Self.healthStatus(base) != nil {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        server = .stopped
    }

    static func healthStatus(_ base: URL) async -> Int? {
        var req = URLRequest(url: base.appendingPathComponent("api/health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.statusCode
    }

    // MARK: Command-line tool

    static var cliDirs: [String] {
        [
            "/opt/homebrew/bin", "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
                .path,
        ]
    }

    static func findCLI() -> String? {
        cliDirs.map { $0 + "/orchard" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Symlinks the bundled binary into the first writable bin directory.
    func installCLI() {
        guard let bin = bundledBinary else {
            cliMessage = "Binary missing from the app bundle."
            return
        }
        let fm = FileManager.default
        let local = Self.cliDirs.last!
        try? fm.createDirectory(atPath: local, withIntermediateDirectories: true)
        guard let dir = Self.cliDirs.first(where: { fm.isWritableFile(atPath: $0) }) else {
            cliMessage = "No writable bin directory found."
            return
        }
        let link = dir + "/orchard"
        if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil {
            try? fm.removeItem(atPath: link)
        }
        do {
            try fm.createSymbolicLink(atPath: link, withDestinationPath: bin)
            cliPath = link
            let onPath =
                (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
                    $0 == dir
                }
                || dir != local
            cliMessage =
                onPath ? "Installed at \(link)." : "Installed at \(link). Add \(dir) to your PATH."
        } catch {
            cliMessage = "Couldn't install: \(error.localizedDescription)"
        }
    }
}
