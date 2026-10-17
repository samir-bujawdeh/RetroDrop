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

// MARK: - Web upload (Safari on iOS 6 and later)

enum WebUpload {
    static func handle(_ conn: Connection, saver: FileSaver) {
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
        let path = parts.count > 1 ? String(parts[1]) : "/"

        if path == "/favicon.ico" || path == "/apple-touch-icon.png" || path.hasPrefix("/apple-touch-icon") {
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
        respond(conn, status: "200 OK", body: page(message: message))
    }

    private static func respond(_ conn: Connection, status: String, body: String) {
        let data = Data(body.utf8)
        conn.write("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                   + "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n")
        conn.write(data)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Plain HTML that old Mobile Safari renders fine; no HTTPS, no modern JS.
    private static func page(message: String) -> String {
        """
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
        </body></html>
        """
    }
}

// MARK: - Email upload (any iPhone's Mail app)
//
// A tiny outgoing-mail (SMTP) server that saves attachments instead of delivering mail,
// plus an empty incoming-mail (POP3) server so the phone accepts the account setup.
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

    static func handlePOP(_ conn: Connection) {
        conn.writeLine("+OK RetroDrop")
        while let line = conn.readLine() {
            switch line.split(separator: " ").first.map({ $0.uppercased() }) ?? "" {
            case "STAT":
                conn.writeLine("+OK 0 0")
            case "LIST", "UIDL":
                conn.writeLine("+OK 0 messages")
                conn.writeLine(".")
            case "CAPA":
                conn.writeLine("+OK")
                conn.writeLine("USER")
                conn.writeLine("UIDL")
                conn.writeLine(".")
            case "QUIT":
                conn.writeLine("+OK Bye")
                return
            case "USER", "PASS", "NOOP", "RSET":
                conn.writeLine("+OK")
            default:
                conn.writeLine("-ERR Not supported")
            }
        }
    }
}
