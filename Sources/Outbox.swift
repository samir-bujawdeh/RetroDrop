import Foundation

/// A photo or video waiting to be picked up by the phone, already converted for old iPhones.
struct OutboxItem: Codable, Identifiable, Equatable {
    let id: String
    let name: String       // shown to the user, e.g. "IMG_1234.jpg"
    let kind: MediaKind
    let added: Date
    var duration: Double?  // videos only

    var file: String { "\(id).\(kind == .photo ? "jpg" : "mp4")" }
    var thumb: String { "\(id)-thumb.jpg" }
    var message: String { "\(id).eml" }
    var mimeType: String { kind == .photo ? "image/jpeg" : "video/mp4" }
}

/// Files the Mac is sending to phones. Lives in ~/Library/Application Support/RetroDrop/Outbox
/// and survives restarts until removed. Thread-safe: the servers read it from their own threads.
final class Outbox {
    let dir: URL
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private var items: [OutboxItem] = []
    private var preparing = 0
    private let queue = DispatchQueue(label: "RetroDrop.outbox", qos: .userInitiated)

    init(dir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RetroDrop/Outbox")) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL),
           let saved = try? JSONDecoder().decode([OutboxItem].self, from: data) {
            items = saved.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.file).path) }
        }
    }

    private var manifestURL: URL { dir.appendingPathComponent("outbox.json") }

    /// Oldest first, which is also the order the phone's Mail app receives them in.
    func snapshot() -> [OutboxItem] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    var preparingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return preparing
    }

    /// Converts and queues the files in the background. Calls `completion` on the main queue with
    /// the names of files that couldn't be added and why.
    func add(_ urls: [URL], completion: (([(String, String)]) -> Void)? = nil) {
        let candidates = urls.filter { MediaConverter.kind(of: $0) != nil }
        let skipped = urls.filter { MediaConverter.kind(of: $0) == nil }
            .map { ($0.lastPathComponent, "Not a photo or video.") }
        lock.lock(); preparing += candidates.count; lock.unlock()
        notify()

        queue.async { [self] in
            var failures = skipped
            for url in candidates {
                do {
                    try add(url)
                } catch {
                    failures.append((url.lastPathComponent, error.localizedDescription))
                }
                lock.lock(); preparing -= 1; lock.unlock()
                notify()
            }
            DispatchQueue.main.async { completion?(failures) }
        }
    }

    private func add(_ src: URL) throws {
        guard let kind = MediaConverter.kind(of: src) else { throw MediaConverter.ConvertError.unsupported }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let base = (src.deletingPathExtension().lastPathComponent as NSString).replacingOccurrences(of: "/", with: "-")
        var item = OutboxItem(id: id, name: "\(base).\(kind == .photo ? "jpg" : "mp4")", kind: kind, added: Date())
        let fileURL = dir.appendingPathComponent(item.file)
        do {
            switch kind {
            case .photo: try MediaConverter.convertPhoto(src, to: fileURL)
            case .video: item.duration = try MediaConverter.convertVideo(src, to: fileURL)
            }
            try MediaConverter.writeThumbnail(of: fileURL, kind: kind, to: dir.appendingPathComponent(item.thumb))
            try Self.emailMessage(for: item, file: fileURL).write(to: dir.appendingPathComponent(item.message))
        } catch {
            removeFiles(of: item)
            throw error
        }
        lock.lock(); items.append(item); lock.unlock()
        save()
    }

    func remove(_ id: String) {
        lock.lock()
        let removed = items.filter { $0.id == id }
        items.removeAll { $0.id == id }
        lock.unlock()
        removed.forEach(removeFiles)
        save()
    }

    func clear() {
        snapshot().forEach { remove($0.id) }
    }

    /// The URL of one of an item's files, or nil if `name` isn't part of the outbox
    /// (so the web server can never be asked for anything else on the Mac).
    func fileURL(named name: String) -> URL? {
        let known = snapshot().contains { [$0.file, $0.thumb].contains(name) }
        return known ? dir.appendingPathComponent(name) : nil
    }

    func messageURL(for item: OutboxItem) -> URL { dir.appendingPathComponent(item.message) }

    private func removeFiles(of item: OutboxItem) {
        for name in [item.file, item.thumb, item.message] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snapshot()) {
            try? data.write(to: manifestURL, options: .atomic)
        }
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    // MARK: Email for the Mail route

    /// One email per item, with the photo or video attached. Built once, so the POP server can report
    /// exact sizes. Uses CRLF line endings, and no line starts with "." (so no dot-stuffing needed).
    static func emailMessage(for item: OutboxItem, file: URL) throws -> Data {
        let data = try Data(contentsOf: file)
        let boundary = "RetroDrop-\(item.id)"
        let asciiName = String(item.name.unicodeScalars.map { $0.isASCII && $0 != "\"" ? Character($0) : "_" })
        let what = item.kind == .photo ? "Photo" : "Video"
        let date: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return f.string(from: item.added)
        }()
        let howTo = item.kind == .photo
            ? "Touch and hold the photo below and choose Save Image to add it to your Camera Roll."
            : "Touch and hold the video below and choose Save Video, if your iOS version offers it."

        var lines = [
            "From: RetroDrop <retrodrop@mac.local>",
            "To: RetroDrop <retrodrop@mac.local>",
            "Subject: \(what) from your Mac: \(asciiName)",
            "Date: \(date)",
            "Message-ID: <\(item.id)@retrodrop.local>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
            "Content-Type: text/plain; charset=us-ascii",
            "Content-Transfer-Encoding: 7bit",
            "",
            "Sent from RetroDrop on your Mac.",
            howTo,
            "",
            "--\(boundary)",
            "Content-Type: \(item.mimeType); name=\"\(asciiName)\"",
            "Content-Transfer-Encoding: base64",
            "Content-Disposition: \(item.kind == .photo ? "inline" : "attachment"); filename=\"\(asciiName)\"",
            "",
        ]
        let b64 = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        lines.append(b64)
        lines.append("--\(boundary)--")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}
