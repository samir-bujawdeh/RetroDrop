import AppKit
import CryptoKit

/// "Check for Updates…": asks GitHub for the latest release and, with one click, downloads it, verifies it
/// and swaps it in place of the running app. Only talks to the network when the user asks.
///
/// Safety: every release's disk image is signed with a private key that never leaves the developer's Mac
/// (scripts/update-signing.swift). The matching public key is built into Info.plist (RDUpdatePublicKey), and
/// an update is installed only if its signature checks out, it's RetroDrop (same bundle ID), it's the version
/// the release says, and its code signature is intact.
final class Updater: NSObject, URLSessionDownloadDelegate {
    static let shared = Updater()

    struct Release {
        let version: String
        let notes: String
        let dmg: URL
        let signature: URL?
        let page: URL
    }

    enum UpdateError: LocalizedError {
        case network(String), noDiskImage, unverified(String), wrongApp(String), install(String)
        var errorDescription: String? {
            switch self {
            case .network(let why): return "Couldn't reach GitHub (\(why))."
            case .noDiskImage: return "The latest release has no RetroDrop.dmg to install."
            case .unverified(let why): return "The update couldn't be verified, so it wasn't installed. \(why)"
            case .wrongApp(let why): return "The download isn't the expected RetroDrop app (\(why)), so it wasn't installed."
            case .install(let why): return "The update couldn't be installed (\(why))."
            }
        }
    }

    /// Defaults overrides (`-updateFeedURL`, `-updatePublicKey`) exist for testing.
    private var feedURL: URL {
        UserDefaults.standard.string(forKey: "updateFeedURL").flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/samir-bujawdeh/RetroDrop/releases/latest")!
    }
    private var publicKey: Curve25519.Signing.PublicKey? {
        let b64 = UserDefaults.standard.string(forKey: "updatePublicKey")
            ?? Bundle.main.object(forInfoDictionaryKey: "RDUpdatePublicKey") as? String
        return b64.flatMap { Data(base64Encoded: $0) }.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var busy = false
    private var progressPanel: ProgressPanel?
    private var downloadContinuation: ((Result<URL, Error>) -> Void)?
    private var session: URLSession?
    /// Called just before quitting to install; returns extra arguments for the relaunched app.
    var relaunchArguments: () -> [String] = { [] }

    // MARK: Checking

    /// `interactive: false` installs a newer version without asking (used by `--update-now` and tests).
    func checkForUpdates(interactive: Bool = true) {
        guard !busy else { return }
        busy = true
        fetchLatest { [self] result in
            busy = false
            switch result {
            case .failure(let error):
                if interactive { showError(error) } else { exitForTest("check failed: \(error.localizedDescription)") }
            case .success(let release):
                guard Self.isNewer(release.version, than: currentVersion) else {
                    if interactive {
                        alert("You're up to date", "RetroDrop \(currentVersion) is the newest version.")
                    } else { exitForTest("up to date") }
                    return
                }
                if interactive { offer(release) } else { install(release, interactive: false) }
            }
        }
    }

    private func fetchLatest(completion: @escaping (Result<Release, Error>) -> Void) {
        var request = URLRequest(url: feedURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RetroDrop/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release, Error>
            if let error {
                result = .failure(UpdateError.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(UpdateError.network("HTTP \(http.statusCode)"))
            } else if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String {
                let assets = (json["assets"] as? [[String: Any]] ?? []).reduce(into: [String: URL]()) { dict, a in
                    if let name = a["name"] as? String, let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) {
                        dict[name] = url
                    }
                }
                if let dmg = assets["RetroDrop.dmg"] {
                    result = .success(Release(
                        version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                        notes: json["body"] as? String ?? "",
                        dmg: dmg, signature: assets["RetroDrop.dmg.sig"],
                        page: (json["html_url"] as? String).flatMap(URL.init(string:))
                            ?? URL(string: "https://github.com/samir-bujawdeh/RetroDrop/releases/latest")!))
                } else {
                    result = .failure(UpdateError.noDiskImage)
                }
            } else {
                result = .failure(UpdateError.network("unexpected reply"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// "1.10.0" > "1.9.2"; missing parts count as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "RetroDrop \(release.version) is available"
        alert.informativeText = "You have \(currentVersion).\n\n" + Self.plainNotes(release.notes)
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Release Notes")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release, interactive: true)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    /// Release notes are Markdown; show them as readable plain text, trimmed.
    static func plainNotes(_ markdown: String) -> String {
        var text = markdown
        if let link = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#) {
            text = link.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "### ", with: "")
        if text.count > 700 { text = String(text.prefix(700)) + "…" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Installing

    private func install(_ release: Release, interactive: Bool) {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        if target.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: parent.path) {
            // Running from the disk image, a translocated copy, or a folder we can't write to.
            if interactive {
                alert("Install the update manually",
                      "RetroDrop can only update itself when it's in your Applications folder. The new version will "
                      + "download now. Open it and drag RetroDrop onto Applications.")
                NSWorkspace.shared.open(release.dmg)
            } else { exitForTest("can't write to \(parent.path)") }
            return
        }

        busy = true
        if interactive {
            progressPanel = ProgressPanel(title: "Downloading RetroDrop \(release.version)…") { [weak self] in
                self?.session?.invalidateAndCancel()
            }
        }
        download(release.dmg) { [self] result in
            switch result {
            case .failure(let error):
                finish(error: (error as? UpdateError) ?? UpdateError.network(error.localizedDescription), interactive: interactive)
            case .success(let dmgFile):
                progressPanel?.setStatus("Verifying…", indeterminate: true)
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        let staged = try verifyAndStage(dmgFile, release: release)
                        DispatchQueue.main.async { self.relaunch(into: target, from: staged) }
                    } catch {
                        DispatchQueue.main.async { self.finish(error: error, interactive: interactive) }
                    }
                }
            }
        }
    }

    private func finish(error: Error, interactive: Bool) {
        busy = false
        progressPanel?.close()
        progressPanel = nil
        if interactive { showError(error) } else { exitForTest("install failed: \(error.localizedDescription)") }
    }

    private func download(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        downloadContinuation = completion
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressPanel?.setProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this returns, so move it somewhere of our own.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("RetroDrop-update-\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.network("HTTP \(http.statusCode)")
            }
            downloadContinuation?(.success(kept))
        } catch {
            downloadContinuation?(.failure(error))
        }
        downloadContinuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            downloadContinuation?(.failure(UpdateError.network(cancelled ? "cancelled" : error.localizedDescription)))
            downloadContinuation = nil
        }
    }

    /// Checks the download's signature and contents, then copies the new app to a staging folder.
    /// Runs off the main thread.
    private func verifyAndStage(_ dmgFile: URL, release: Release) throws -> URL {
        defer { try? FileManager.default.removeItem(at: dmgFile) }
        guard let key = publicKey else { throw UpdateError.unverified("This copy of RetroDrop has no update key.") }
        guard let sigURL = release.signature,
              let sigText = try? String(contentsOf: sigURL, encoding: .utf8),
              let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw UpdateError.unverified("The release has no signature.") }
        guard let data = try? Data(contentsOf: dmgFile, options: .mappedIfSafe), key.isValidSignature(signature, for: data)
        else { throw UpdateError.unverified("Its signature doesn't match.") }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("RetroDrop-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        var staged: URL?
        defer { if staged == nil { try? FileManager.default.removeItem(at: work) } }  // refused: leave nothing behind
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmgFile.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }

        let newApp = mount.appendingPathComponent("RetroDrop.app")
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.wrongApp("no app inside")
        }
        let id = info["CFBundleIdentifier"] as? String, version = info["CFBundleShortVersionString"] as? String
        guard id == Bundle.main.bundleIdentifier else { throw UpdateError.wrongApp("different app ID") }
        guard version == release.version else { throw UpdateError.wrongApp("version \(version ?? "?"), expected \(release.version)") }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        } catch {
            throw UpdateError.wrongApp("code signature is broken")
        }

        let app = work.appendingPathComponent("RetroDrop.app")
        try run("/usr/bin/ditto", [newApp.path, app.path])
        staged = app
        return app
    }

    /// Hands over to a tiny script that waits for us to quit, swaps the app (keeping the old one until the
    /// new one is in place) and opens the new version.
    private func relaunch(into target: URL, from staged: URL) {
        progressPanel?.setStatus("Restarting RetroDrop…", indeterminate: true)
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$2.old"
        if /bin/mv "$2" "$2.old" && /usr/bin/ditto "$3" "$2"; then
          /bin/rm -rf "$2.old"
        else
          /bin/rm -rf "$2"; /bin/mv "$2.old" "$2"
        fi
        /bin/rm -rf "$(/usr/bin/dirname "$3")"
        shift 3
        /usr/bin/open "$TARGET_APP" --args "$@"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), target.path, staged.path]
            + relaunchArguments()
        var env = ProcessInfo.processInfo.environment
        env["TARGET_APP"] = target.path
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            finish(error: UpdateError.install(error.localizedDescription), interactive: progressPanel != nil)
            return
        }
        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw UpdateError.install("\((tool as NSString).lastPathComponent): \(text)") }
        return text
    }

    // MARK: UI helpers

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func showError(_ error: Error) {
        alert("Update failed", error.localizedDescription)
    }

    /// Non-interactive runs (tests) report the outcome and quit instead of showing alerts.
    private func exitForTest(_ message: String) {
        print("updater: \(message)")
        fflush(stdout)
        NSApp.terminate(nil)
    }
}

/// Small window with a progress bar and a Cancel button.
final class ProgressPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let onCancel: () -> Void

    init(title: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled],
                        backing: .buffered, defer: false)
        panel.title = "Updating RetroDrop"
        panel.isFloatingPanel = true
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        label.stringValue = title
        label.frame = NSRect(x: 20, y: 76, width: 340, height: 20)
        bar.frame = NSRect(x: 20, y: 48, width: 340, height: 20)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.frame = NSRect(x: 270, y: 10, width: 90, height: 30)
        cancel.bezelStyle = .rounded
        content.addSubview(label)
        content.addSubview(bar)
        content.addSubview(cancel)
        panel.contentView = content
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func setProgress(_ fraction: Double) {
        bar.isIndeterminate = false
        bar.doubleValue = fraction
    }

    func setStatus(_ text: String, indeterminate: Bool) {
        label.stringValue = text
        bar.isIndeterminate = indeterminate
        if indeterminate { bar.startAnimation(nil) }
    }

    func close() { panel.close() }

    @objc private func cancelPressed() {
        onCancel()
        close()
    }
}
