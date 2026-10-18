import Foundation

/// Saves received files into the chosen folder without ever overwriting.
final class FileSaver {
    private let folder: () -> URL
    private let onSaved: (URL) -> Void
    private let lock = NSLock()
    private let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    init(folder: @escaping () -> URL, onSaved: @escaping (URL) -> Void) {
        self.folder = folder
        self.onSaved = onSaved
    }

    /// Old iPhones name every upload "image.jpg" / "photo.JPG", so names get a timestamp
    /// prefix, plus "-2", "-3"... if several arrive in the same second.
    @discardableResult
    func save(_ attachments: [MIME.Attachment]) -> [URL] {
        attachments.compactMap { save(name: $0.filename, data: $0.data) }
    }

    private func save(name: String, data: Data) -> URL? {
        let dir = folder()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var clean = (name as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean.hasPrefix(".") { clean = "file" + clean }
        let base = (clean as NSString).deletingPathExtension
        let ext = (clean as NSString).pathExtension

        lock.lock()
        defer { lock.unlock() }
        let stamp = stampFormat.string(from: Date())
        var url: URL
        var n = 1
        repeat {
            let suffix = n == 1 ? "" : "-\(n)"
            let file = "\(stamp)-\(base)\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
            url = dir.appendingPathComponent(file)
            n += 1
        } while FileManager.default.fileExists(atPath: url.path)

        do {
            try data.write(to: url, options: .atomic)  // never leaves half-written files behind
        } catch {
            NSLog("RetroDrop: couldn't save \(url.path): \(error)")
            return nil
        }
        onSaved(url)
        return url
    }
}

// MARK: - Web page (Safari): uploads on iOS 6+, downloads from the Mac on any iOS

enum WebUpload {
    static func handle(_ conn: Connection, saver: FileSaver, outbox: Outbox) {
        guard let requestLine = conn.readLine() else { return }
        var headers: [String: String] = [:]
        while let line = conn.readLine(), !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let target = parts.count > 1 ? String(parts[1]) : "/"
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")

        if path.hasPrefix("/out/") {
            let name = String(path.dropFirst("/out/".count)).removingPercentEncoding ?? ""
            guard let url = outbox.fileURL(named: name) else {
                return respond(conn, status: "404 Not Found", body: "")
            }
            let type = name.hasSuffix(".mp4") ? "video/mp4" : "image/jpeg"
            return serveFile(conn, url: url, contentType: type, range: headers["range"], headOnly: method == "HEAD")
        }
        if path.hasPrefix("/view/") {
            let id = String(path.dropFirst("/view/".count))
            guard let page = photoPage(id: id, outbox: outbox.snapshot()) else {
                return respond(conn, status: "404 Not Found", body: "")
            }
            return respond(conn, status: "200 OK", body: page)
        }
        if path != "/" {
            return respond(conn, status: "404 Not Found", body: "")
        }

        var message = ""
        if method == "POST" {
            let length = Int(headers["content-length"] ?? "") ?? 0
            guard length > 0, let body = conn.read(count: length) else { return }
            let entity = Data("Content-Type: \(headers["content-type"] ?? "")\r\n\r\n".utf8) + body
            let saved = saver.save(MIME.attachments(in: entity))
            if saved.isEmpty {
                message = "<p style=\"color:#c00\">Nothing received. Pick a photo or video first.</p>"
            } else {
                let names = saved.map { escape($0.lastPathComponent) }.joined(separator: "<br>")
                message = "<p style=\"color:#080\">Saved \(saved.count) file(s):<br>\(names)</p>"
            }
        }
        respond(conn, status: "200 OK", body: page(message: message, outbox: outbox.snapshot()))
    }

    private static func respond(_ conn: Connection, status: String, body: String) {
        let data = Data(body.utf8)
        conn.write("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                   + "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n")
        conn.write(data)
    }

    /// Sends a file, honouring "Range: bytes=..." requests. Mobile Safari only plays videos from
    /// servers that support ranges.
    private static func serveFile(_ conn: Connection, url: URL, contentType: String, range: String?, headOnly: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        else { return respond(conn, status: "404 Not Found", body: "") }
        defer { try? handle.close() }

        var first: Int64 = 0, last = size - 1, status = "200 OK"
        if let range, range.hasPrefix("bytes="), !range.contains(",") {
            let spec = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2 {
                if spec[0].isEmpty, let n = Int64(spec[1]) {            // "-500": the last 500 bytes
                    first = max(0, size - n)
                } else if let a = Int64(spec[0]) {                      // "100-" or "100-199"
                    first = a
                    if let b = Int64(spec[1]) { last = min(b, size - 1) }
                }
                guard first <= last, first < size else {
                    conn.write("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\n"
                               + "Content-Length: 0\r\nConnection: close\r\n\r\n")
                    return
                }
                status = "206 Partial Content"
            }
        }
        let length = last - first + 1
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\n"
            + "Accept-Ranges: bytes\r\nCache-Control: no-cache\r\nConnection: close\r\n"
        if status.hasPrefix("206") { head += "Content-Range: bytes \(first)-\(last)/\(size)\r\n" }
        conn.write(head + "\r\n")
        guard !headOnly else { return }

        try? handle.seek(toOffset: UInt64(first))
        var remaining = length
        while remaining > 0 {
            let chunk = handle.readData(ofLength: Int(min(remaining, 256 * 1024)))
            if chunk.isEmpty { break }
            conn.write(chunk)
            remaining -= Int64(chunk.count)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        let s = Int(seconds.rounded())
        return String(format: " %d:%02d", s / 60, s % 60)
    }

    /// One full-size photo (under 2 MP, so old Safari shows it sharply), ready to touch and hold and save.
    private static func photoPage(id: String, outbox: [OutboxItem]) -> String? {
        let photos = Array(outbox.filter { $0.kind == .photo }.reversed())  // same order as the main page
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return nil }
        let item = photos[i]
        let prev = i > 0 ? "<a href=\"/view/\(photos[i - 1].id)\">&larr; Previous</a>" : ""
        let next = i < photos.count - 1 ? "<a href=\"/view/\(photos[i + 1].id)\">Next &rarr;</a>" : ""
        return """
        <html><head><meta name="viewport" content="width=device-width">
        <title>\(escape(item.name))</title></head>
        <body style="font-family:Helvetica;margin:0;background:#fff;color:#222">
        <p style="margin:12px 16px"><a href="/">&larr; RetroDrop</a>
        <span style="float:right;color:#888">\(i + 1) of \(photos.count)</span></p>
        <p style="margin:0 16px 12px"><b>Touch and hold the photo</b>, then tap <b>Save Image</b>.</p>
        <img src="/out/\(item.file)" alt="\(escape(item.name))" style="width:100%;display:block">
        <p style="margin:14px 16px;font-size:18px">\(prev)<span style="float:right">\(next)</span></p>
        </body></html>
        """
    }

    /// Plain HTML that old Mobile Safari renders fine; no HTTPS, no modern JS or CSS.
    private static func page(message: String, outbox: [OutboxItem]) -> String {
        var fromMac = ""
        if !outbox.isEmpty {
            let photos = outbox.filter { $0.kind == .photo }
            let videos = outbox.filter { $0.kind == .video }
            fromMac += "<h3 style=\"margin-top:28px\">From your Mac</h3>"
            if !photos.isEmpty {
                fromMac += "<p>Tap a photo to open it full size, then <b>touch and hold</b> it and tap "
                    + "<b>Save Image</b>.</p><p>"
                // Thumbnails are link backgrounds, not <img>s: touching and holding one offers Open/Copy,
                // never "Save Image", so nobody saves the small preview by mistake.
                for item in photos.reversed() {
                    fromMac += "<a href=\"/view/\(item.id)\" title=\"\(escape(item.name))\" style=\"display:inline-block;"
                        + "width:96px;height:96px;margin:0 6px 6px 0;border-radius:6px;background:#ddd "
                        + "url(/out/\(item.thumb)) center no-repeat;-webkit-background-size:cover;background-size:cover\">"
                        + "</a>"
                }
                fromMac += "</p>"
            }
            if !videos.isEmpty {
                fromMac += "<p>Tap a video to play it. Safari can't save videos to your phone. To keep one, "
                    + "receive it by Mail instead (see How to Connect a Phone in the RetroDrop menu).</p>"
                for item in videos.reversed() {
                    fromMac += "<p><a href=\"/out/\(item.file)\"><img src=\"/out/\(item.thumb)\" height=\"72\" "
                        + "style=\"vertical-align:middle;margin-right:8px;border-radius:6px\">"
                        + "&#9654;\(duration(item.duration)) \(escape(item.name))</a></p>"
                }
            }
        }
        return """
        <html><head><meta name="viewport" content="width=device-width">
        <title>RetroDrop</title></head>
        <body style="font-family:Helvetica;margin:16px;background:#fff;color:#222">
        <h2>RetroDrop</h2>
        <p>Send photos &amp; videos to your Mac.</p>
        \(message)
        <form method="post" enctype="multipart/form-data" onsubmit="document.getElementById('busy').style.display='block'">
        <p><input type="file" name="file" accept="image/*,video/*" multiple></p>
        <p><input type="submit" value="Upload" style="font-size:20px;padding:8px 20px"></p>
        <p id="busy" style="display:none;color:#06c">Uploading&hellip; videos can take a minute. Keep this page open.</p>
        </form>
        <p style="color:#888;font-size:13px">Button greyed out? Your phone is on iOS 5 or older &mdash;
        send by email instead. On the Mac, open the RetroDrop menu &gt; How to Connect a Phone.</p>
        \(fromMac)
        </body></html>
        """
    }
}

// MARK: - Email upload (any iPhone's Mail app)
//
// A tiny outgoing-mail (SMTP) server that saves attachments instead of delivering mail,
// plus an incoming-mail (POP3) server that delivers whatever the Mac is sending to the phone.
// Any username and password are accepted. Nothing is ever sent onwards.

enum MailUpload {
    static func handleSMTP(_ conn: Connection, saver: FileSaver) {
        conn.writeLine("220 RetroDrop ready")
        while let line = conn.readLine() {
            let verb = line.split(separator: " ").first.map { $0.uppercased() } ?? ""
            let args = line.split(separator: " ").dropFirst().map(String.init)
            switch verb {
            case "EHLO":
                conn.writeLine("250-RetroDrop")
                conn.writeLine("250-AUTH PLAIN LOGIN")
                conn.writeLine("250-8BITMIME")
                conn.writeLine("250 SIZE 0")
            case "HELO":
                conn.writeLine("250 RetroDrop")
            case "AUTH":
                let mech = args.first?.uppercased() ?? ""
                if mech == "LOGIN" {
                    if args.count < 2 {
                        conn.writeLine("334 VXNlcm5hbWU6")  // "Username:"
                        _ = conn.readLine()
                    }
                    conn.writeLine("334 UGFzc3dvcmQ6")      // "Password:"
                    _ = conn.readLine()
                } else if mech == "PLAIN" && args.count < 2 {
                    conn.writeLine("334 ")
                    _ = conn.readLine()
                }
                conn.writeLine("235 OK")
            case "DATA":
                conn.writeLine("354 Send it")
                var message = Data()
                while let l = conn.readLineData() {
                    if l == Data(".".utf8) { break }
                    message.append(l.first == UInt8(ascii: ".") ? l.dropFirst() : l)  // dot-unstuffing
                    message.append(contentsOf: [13, 10])
                }
                saver.save(MIME.attachments(in: message))
                conn.writeLine("250 Saved")
            case "QUIT":
                conn.writeLine("221 Bye")
                return
            case "MAIL", "RCPT", "RSET", "NOOP":
                conn.writeLine("250 OK")
            default:
                conn.writeLine("502 Not supported")
            }
        }
    }

    /// The phone's inbox: one message per item the Mac is sending. Numbering is fixed for the session,
    /// as POP3 requires. UIDL lets the phone download each message only once. Deleting is accepted but
    /// ignored; items leave the outbox only when removed on the Mac.
    static func handlePOP(_ conn: Connection, outbox: Outbox) {
        let mailbox: [(item: OutboxItem, url: URL, size: Int)] = outbox.snapshot().compactMap { item in
            let url = outbox.messageURL(for: item)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            else { return nil }
            return (item, url, size)
        }
        func message(_ arg: String?) -> (index: Int, entry: (item: OutboxItem, url: URL, size: Int))? {
            guard let arg, let n = Int(arg), n >= 1, n <= mailbox.count else { return nil }
            return (n, mailbox[n - 1])
        }

        conn.writeLine("+OK RetroDrop")
        while let line = conn.readLine() {
            let words = line.split(separator: " ").map(String.init)
            let arg = words.count > 1 ? words[1] : nil
            switch words.first?.uppercased() ?? "" {
            case "STAT":
                conn.writeLine("+OK \(mailbox.count) \(mailbox.reduce(0) { $0 + $1.size })")
            case "LIST":
                if arg != nil {
                    guard let m = message(arg) else { conn.writeLine("-ERR No such message"); continue }
                    conn.writeLine("+OK \(m.index) \(m.entry.size)")
                } else {
                    conn.writeLine("+OK \(mailbox.count) messages")
                    for (i, m) in mailbox.enumerated() { conn.writeLine("\(i + 1) \(m.size)") }
                    conn.writeLine(".")
                }
            case "UIDL":
                if arg != nil {
                    guard let m = message(arg) else { conn.writeLine("-ERR No such message"); continue }
                    conn.writeLine("+OK \(m.index) \(m.entry.item.id)")
                } else {
                    conn.writeLine("+OK")
                    for (i, m) in mailbox.enumerated() { conn.writeLine("\(i + 1) \(m.item.id)") }
                    conn.writeLine(".")
                }
            case "RETR":
                guard let m = message(arg), let data = try? Data(contentsOf: m.entry.url) else {
                    conn.writeLine("-ERR No such message"); continue
                }
                conn.writeLine("+OK \(data.count) octets")
                conn.write(data)  // CRLF throughout, no line starts with "." (see Outbox.emailMessage)
                conn.writeLine(".")
            case "TOP":
                // Headers plus the first N body lines; the phone uses this to preview messages.
                guard let m = message(arg), words.count > 2, let n = Int(words[2]),
                      let data = try? Data(contentsOf: m.entry.url) else {
                    conn.writeLine("-ERR No such message"); continue
                }
                let text = String(decoding: data, as: UTF8.self)
                let parts = text.components(separatedBy: "\r\n\r\n")
                let body = parts.dropFirst().joined(separator: "\r\n\r\n").components(separatedBy: "\r\n")
                conn.writeLine("+OK")
                conn.write(parts[0] + "\r\n\r\n")
                for l in body.prefix(n) { conn.writeLine(l) }
                conn.writeLine(".")
            case "CAPA":
                conn.writeLine("+OK")
                conn.writeLine("USER")
                conn.writeLine("UIDL")
                conn.writeLine("TOP")
                conn.writeLine(".")
            case "QUIT":
                conn.writeLine("+OK Bye")
                return
            case "DELE":
                guard message(arg) != nil else { conn.writeLine("-ERR No such message"); continue }
                conn.writeLine("+OK")
            case "USER", "PASS", "NOOP", "RSET":
                conn.writeLine("+OK")
            default:
                conn.writeLine("-ERR Not supported")
            }
        }
    }
}
