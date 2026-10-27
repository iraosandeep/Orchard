// In-app updates from GitHub releases: check the latest release, download
// Orchard.zip, verify it's signed by the same identity as the running app,
// swap the bundle and relaunch.
import AppKit
import Observation
import Security

@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let repo = "iraosandeep/Orchard"

    struct Release: Equatable {
        let version: String
        let notes: String
        let zipURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case installing(String) // step description
        case failed(String)
    }

    var state: State = .idle
    var lastChecked: Date?
    var current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    var isDevBuild: Bool { current.contains("dev") }

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates") }
    }

    var available: Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    private var timer: Timer?

    func start() {
        // Dev builds (./build.sh without a version) only check when asked.
        guard !isDevBuild else { return }
        if autoCheck { Task { await check(userInitiated: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in
                let u = Updater.shared
                if u.autoCheck { await u.check(userInitiated: false) }
            }
        }
    }

    // MARK: Check

    func check(userInitiated: Bool) async {
        if case .installing = state { return }
        state = .checking
        do {
            let r = try await Self.fetchLatest()
            lastChecked = Date()
            if Self.isNewer(r.version, than: current) {
                state = .available(r)
                if !userInitiated { promptIfNew(r) } else { prompt(r) }
            } else {
                state = .upToDate
                if userInitiated { info("You're up to date", "Orchard \(current) is the latest version.") }
            }
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
            if userInitiated { info("Couldn't check for updates", error.localizedDescription) }
        }
    }

    static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("GitHub returned \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct GHRelease: Decodable { let tag_name: String; let body: String?; let html_url: URL; let assets: [Asset] }
        let gh = try JSONDecoder().decode(GHRelease.self, from: data)
        guard let zip = gh.assets.first(where: { $0.name == "Orchard.zip" }) else {
            throw UpdateError("The latest release has no Orchard.zip")
        }
        let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
        return Release(version: version, notes: gh.body ?? "", zipURL: zip.browser_download_url, pageURL: gh.html_url)
    }

    /// Numeric compare of dotted versions; any dev build counts as older.
    static func isNewer(_ a: String, than b: String) -> Bool {
        if b.contains("dev") { return true }
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Prompts

    private func promptIfNew(_ r: Release) {
        // Ask once per version; after that it stays in the menu bar and Setup.
        let key = "promptedUpdateVersion"
        guard UserDefaults.standard.string(forKey: key) != r.version else { return }
        UserDefaults.standard.set(r.version, forKey: key)
        prompt(r)
    }

    func prompt(_ r: Release) {
        let a = NSAlert()
        a.messageText = "Orchard \(r.version) is available"
        a.informativeText = "You have \(current). Orchard will download the update, check its signature, and relaunch."
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Release Notes")
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: Task { await install(r) }
        case .alertThirdButtonReturn: NSWorkspace.shared.open(r.pageURL)
        default: break
        }
    }

    private func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }

    // MARK: Install

    func install(_ r: Release) async {
        let dest = Bundle.main.bundleURL
        if dest.pathComponents.contains("AppTranslocation") {
            state = .failed("This copy is running from macOS's temporary App Translocation folder, so it can't update itself. Reinstall Orchard with the command at https://github.com/iraosandeep/Orchard#install, then open the installed copy.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            state = .failed("Can't write to \(dest.deletingLastPathComponent().path). Install Orchard in a writable folder or reinstall with the command at https://github.com/iraosandeep/Orchard#install.")
            return
        }
        do {
            state = .installing("Downloading \(r.version)…")
            let newApp = try await Self.downloadAndVerify(r)
            state = .installing("Relaunching…")
            try Self.spawnInstaller(newApp: newApp, dest: dest, waitForPID: ProcessInfo.processInfo.processIdentifier, relaunch: true)
            NSApp.terminate(nil) // stops the server; the installer swaps the bundle and reopens
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
            info("Update failed", error.localizedDescription)
        }
    }

    /// Downloads and unzips the release, and checks that the new app is signed
    /// by the same identity as this one. Returns the unpacked Orchard.app.
    nonisolated static func downloadAndVerify(_ r: Release) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("orchard-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (tmp, resp) = try await URLSession.shared.download(from: r.zipURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed") }
        let zip = dir.appendingPathComponent("Orchard.zip")
        try FileManager.default.moveItem(at: tmp, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        let app = dir.appendingPathComponent("Orchard.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError("Orchard.app missing from the download") }
        try verifySameSigner(app)
        return app
    }

    /// The update must satisfy this app's own designated requirement
    /// (same bundle identifier and signing certificate).
    nonisolated static func verifySameSigner(_ app: URL) throws {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &req) == errSecSuccess, let req
        else { throw UpdateError("Couldn't read this app's signature") }
        var newStatic: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newStatic) == errSecSuccess, let newStatic else {
            throw UpdateError("Couldn't read the update's signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(newStatic, flags, req)
        guard status == errSecSuccess else {
            throw UpdateError("The update isn't signed by the same identity as this app (error \(status)), so it wasn't installed.")
        }
    }

    /// Starts a detached script that waits for `waitForPID` to exit, swaps
    /// `dest` for `newApp` (rolling back on failure) and optionally reopens it.
    nonisolated static func spawnInstaller(newApp: URL, dest: URL, waitForPID: Int32, relaunch: Bool) throws {
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            NEW="$2"; DEST="$3"
            rm -rf "$DEST.old"
            if mv "$DEST" "$DEST.old" && ditto "$NEW" "$DEST"; then
              rm -rf "$DEST.old"
            else
              rm -rf "$DEST"; mv "$DEST.old" "$DEST"
            fi
            xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
            touch "$DEST"
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null
            [ "$4" = 1 ] && open "$DEST"
            rm -rf "$(dirname "$NEW")"
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "orchard-updater", String(waitForPID), newApp.path, dest.path, relaunch ? "1" : "0"]
        try p.run()
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(tool) failed (\(p.terminationStatus))") }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
