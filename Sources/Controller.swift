import AppKit
import Combine
import UniformTypeIdentifiers

struct Photo: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int
    var id: String { url.path }
    /// Changes whenever the file changes, so stale thumbnails aren't reused.
    var cacheKey: String { "\(url.path)|\(size)|\(date.timeIntervalSince1970)" }
}

/// Runs the upload servers and keeps track of the received files.
final class Controller: ObservableObject {
    static let shared = Controller()

    static let defaultWebPort: UInt16 = 8765
    /// If the web port is busy, try the next ones up to this many.
    static let webPortAttempts: UInt16 = 20
    static let smtpPort: UInt16 = 25
    static let popPort: UInt16 = 110

    @Published private(set) var isRunning = false
    @Published private(set) var ip = ""
    /// The port the Safari page is on. Remembered, so phone bookmarks keep working.
    @Published private(set) var webPort: UInt16
    @Published private(set) var webAvailable = false
    @Published private(set) var mailAvailable = false
    @Published private(set) var error: String?
    /// Set when one route works but the other couldn't start.
    @Published private(set) var mailWarning: String?
    /// Set when the remembered web port was busy and another one was picked.
    @Published private(set) var portNotice: String?
    @Published private(set) var folder: URL
    /// Everything in the folder, newest first.
    @Published private(set) var allPhotos: [Photo] = []
    /// Paths received since the last Start, newest first.
    @Published private(set) var sessionPaths: [String] = []
    /// Photos and videos waiting for the phone to pick up, oldest first.
    @Published private(set) var outboxItems: [OutboxItem] = []
    /// How many files are still being converted for the phone.
    @Published private(set) var outboxPreparing = 0

    /// `-outboxDir <path>` (a defaults argument) keeps tests away from the real outbox.
    let outbox = UserDefaults.standard.string(forKey: "outboxDir")
        .map { Outbox(dir: URL(fileURLWithPath: $0)) } ?? Outbox()

    var sessionPhotos: [Photo] {
        let byPath = Dictionary(allPhotos.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        return sessionPaths.compactMap { byPath[$0] }
    }

    private var servers: [TCPServer] = []
    private var ipTimer: Timer?
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var reloadPending = false
    private let folderLock = NSLock()
    private var currentFolder: URL  // thread-safe copy for the server threads

    private static let folderKey = "saveFolder"
    private static let webPortKey = "webPort"
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/RetroDrop")

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0) }
        let initial = saved ?? Self.defaultFolder
        folder = initial
        currentFolder = initial
        let storedPort = UserDefaults.standard.integer(forKey: Self.webPortKey)
        webPort = (1024...65535).contains(storedPort) ? UInt16(storedPort) : Self.defaultWebPort
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        refreshIP()
        reloadFolder()
        watchFolder()
        outbox.onChange = { [weak self] in
            guard let self else { return }
            self.outboxItems = self.outbox.snapshot()
            self.outboxPreparing = self.outbox.preparingCount
        }
        outboxItems = outbox.snapshot()
    }

    // MARK: Servers

    func start() {
        guard !isRunning else { return }
        error = nil
        mailWarning = nil
        portNotice = nil
        sessionPaths = []

        let saver = FileSaver(folder: { [weak self] in self?.saveFolder() ?? Controller.defaultFolder },
                              onSaved: { [weak self] url in
                                  DispatchQueue.main.async { self?.didSave(url) }
                              })

        // Safari route: the remembered port, or the next free one after it.
        var webError: String?
        let preferred = webPort
        for offset in 0..<Self.webPortAttempts {
            let (port, overflow) = preferred.addingReportingOverflow(offset)
            if overflow { break }
            let web = TCPServer(port: port) { [outbox] in WebUpload.handle($0, saver: saver, outbox: outbox) }
            do {
                try web.start()
                servers.append(web)
                if port != preferred {
                    portNotice = "Port \(preferred) was busy, so the Safari address now uses port \(port). "
                        + "Update any bookmarks on your phones."
                }
                webPort = port
                UserDefaults.standard.set(Int(port), forKey: Self.webPortKey)
                webError = nil
                break
            } catch {
                webError = webError ?? error.localizedDescription
            }
        }
        if let webError {
            let last = preferred &+ (Self.webPortAttempts - 1)
            self.error = "Safari uploads are off: \(webError) Ports \(preferred)–\(last) were all busy."
        }
        webAvailable = webError == nil

        // Mail route: needs both standard ports (old iPhones try those first).
        var mailServers: [TCPServer] = []
        var mailErrors: [String] = []
        for server in [TCPServer(port: Self.smtpPort) { MailUpload.handleSMTP($0, saver: saver) },
                       TCPServer(port: Self.popPort) { [outbox] in MailUpload.handlePOP($0, outbox: outbox) }] {
            do {
                try server.start()
                mailServers.append(server)
            } catch {
                mailErrors.append(error.localizedDescription)
            }
        }
        if mailErrors.isEmpty {
            servers += mailServers
        } else {
            mailServers.forEach { $0.stop() }
            mailWarning = "Email uploads are off: " + mailErrors.joined(separator: " ")
        }
        mailAvailable = mailErrors.isEmpty

        guard webAvailable || mailAvailable else {
            mailWarning = nil
            error = (error ?? "") + " Email uploads are off too: " + mailErrors.joined(separator: " ")
            return
        }

        isRunning = true
        refreshIP()
        ipTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshIP()
        }
        RunLoop.main.add(ipTimer!, forMode: .common)  // keep updating while the menu is open
    }

    func stop() {
        servers.forEach { $0.stop() }
        servers = []
        isRunning = false
        webAvailable = false
        mailAvailable = false
        mailWarning = nil
        portNotice = nil
        ipTimer?.invalidate()
        ipTimer = nil
    }

    private func didSave(_ url: URL) {
        sessionPaths.insert(url.standardizedFileURL.path, at: 0)
        reloadFolder()
    }

    // MARK: Sending to the phone

    /// Converts the files for old iPhones and queues them. Reports files that couldn't be added.
    func send(_ urls: [URL]) {
        outbox.add(urls) { failures in
            guard !failures.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = failures.count == 1 ? "Couldn't send “\(failures[0].0)”"
                                                    : "Couldn't send \(failures.count) files"
            alert.informativeText = failures.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func chooseFilesToSend() {
        let panel = NSOpenPanel()
        panel.title = "Choose photos and videos to send to your phone"
        panel.prompt = "Send to Phone"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        send(panel.urls)
    }

    // MARK: Folder

    private func saveFolder() -> URL {
        folderLock.lock(); defer { folderLock.unlock() }
        return currentFolder
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where RetroDrop saves photos and videos"
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func setFolder(_ url: URL) {
        folder = url.standardizedFileURL
        folderLock.lock(); currentFolder = folder; folderLock.unlock()
        UserDefaults.standard.set(folder.path, forKey: Self.folderKey)
        sessionPaths = []
        reloadFolder()
        watchFolder()
    }

    func reloadFolder() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        allPhotos = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return Photo(url: url.standardizedFileURL,
                         date: v.creationDate ?? v.contentModificationDate ?? .distantPast,
                         size: v.fileSize ?? 0)
        }
        .sorted { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    /// Reload whenever files are added, removed or renamed in the folder (e.g. in Finder).
    private func watchFolder() {
        folderWatcher?.cancel()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, !self.reloadPending else { return }
            self.reloadPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.reloadPending = false
                self.reloadFolder()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        folderWatcher = src
    }

    // MARK: Network

    func refreshIP() {
        let newIP = Self.lanIPv4() ?? "No network"
        if newIP != ip { ip = newIP }
    }

    /// The address phones should use to reach this Mac.
    ///
    /// 1. The address of the interface macOS would use for its default route, if that's a
    ///    real network port (Wi-Fi/Ethernet), not a VPN tunnel.
    /// 2. Otherwise the best Wi-Fi/Ethernet address: private ranges first, en0 first,
    ///    never self-assigned 169.254.x.x addresses.
    static func lanIPv4() -> String? {
        let candidates = interfaceAddresses()
        if let routed = defaultRouteAddress(), candidates.contains(where: { $0.address == routed }) {
            return routed
        }
        return candidates.sorted {
            ($0.isPrivate ? 0 : 1, $0.name == "en0" ? 0 : 1, $0.name) < ($1.isPrivate ? 0 : 1, $1.name == "en0" ? 0 : 1, $1.name)
        }.first?.address
    }

    private struct InterfaceAddress {
        let name: String
        let address: String
        var isPrivate: Bool {
            let p = address.split(separator: ".").compactMap { Int($0) }
            guard p.count == 4 else { return false }
            return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
        }
    }

    /// IPv4 addresses on up-and-running Wi-Fi/Ethernet interfaces (en*), excluding link-local.
    private static func interfaceAddresses() -> [InterfaceAddress] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var found: [InterfaceAddress] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }  // skips VPN tunnels, bridges, AirDrop (awdl)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if address.hasPrefix("169.254.") { continue }  // self-assigned: no router, unreachable
            found.append(InterfaceAddress(name: name, address: address))
        }
        return found
    }

    /// Which local address macOS would send from by default. "Connecting" a UDP socket only
    /// looks up the route; no packet is sent. 192.0.2.1 is a reserved documentation address.
    private static func defaultRouteAddress() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(9).bigEndian
        remote.sin_addr.s_addr = inet_addr("192.0.2.1")
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard ok == 0 else { return nil }
        return String(cString: inet_ntoa(local.sin_addr))
    }
}
