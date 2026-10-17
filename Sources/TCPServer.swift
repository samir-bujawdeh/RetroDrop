import Foundation

/// A minimal blocking-socket TCP server: one background thread per connection.
/// Old phones send at most a handful of connections at once, so this keeps things simple.
final class TCPServer {
    enum StartError: LocalizedError {
        case socket(Int32)
        case bind(port: UInt16, errno: Int32)

        var errorDescription: String? {
            switch self {
            case .socket(let e): return "Couldn't open a network socket (\(String(cString: strerror(e))))."
            case .bind(let port, EADDRINUSE): return "Port \(port) is already in use by another app."
            case .bind(let port, let e): return "Couldn't use port \(port) (\(String(cString: strerror(e))))."
            }
        }
    }

    let port: UInt16
    private let handler: (Connection) -> Void
    private var source: DispatchSourceRead?
    private let closed = DispatchSemaphore(value: 0)
    private var clients = Set<Int32>()
    private let lock = NSLock()

    init(port: UInt16, handler: @escaping (Connection) -> Void) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw StartError.bind(port: port, errno: err)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        src.setEventHandler { [weak self] in self?.acceptPending(fd) }
        src.setCancelHandler { [closed] in
            close(fd)
            closed.signal()
        }
        src.resume()
        source = src
    }

    func stop() {
        if let source {
            source.cancel()
            _ = closed.wait(timeout: .now() + 2)  // port is free again when stop() returns
        }
        source = nil
        lock.lock()
        clients.forEach { shutdown($0, SHUT_RDWR) }  // wakes any connection threads so they exit
        lock.unlock()
    }

    private func acceptPending(_ listenFD: Int32) {
        while true {
            let c = accept(listenFD, nil, nil)
            guard c >= 0 else { return }  // EAGAIN: nothing more to accept right now
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
            var yes: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 120, tv_usec: 0)  // drop connections that go silent
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            lock.lock(); clients.insert(c); lock.unlock()
            Thread.detachNewThread { [weak self] in
                let conn = Connection(fd: c)
                self?.handler(conn)
                conn.close()
                self?.lock.lock(); self?.clients.remove(c); self?.lock.unlock()
            }
        }
    }
}

/// Buffered reading/writing on one client socket.
final class Connection {
    private let fd: Int32
    private var buffer = Data()
    private var start = 0  // read position in `buffer`; compacted occasionally
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    /// Reads up to and including "\n". Returns the line without its line ending, or nil on disconnect.
    func readLineData(limit: Int = 1 << 20) -> Data? {
        var searchFrom = start
        while true {
            if let nl = buffer[searchFrom...].firstIndex(of: UInt8(ascii: "\n")) {
                var end = nl
                if end > start, buffer[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                let line = buffer.subdata(in: start..<end)
                start = nl + 1
                compact()
                return line
            }
            if buffer.count - start > limit { return nil }
            searchFrom = buffer.count
            guard fill() else { return nil }
        }
    }

    func readLine() -> String? {
        readLineData().map { String(decoding: $0, as: UTF8.self) }
    }

    /// Reads exactly `count` bytes, or nil on disconnect.
    func read(count: Int) -> Data? {
        while buffer.count - start < count {
            guard fill() else { return nil }
        }
        let out = buffer.subdata(in: start..<(start + count))
        start += count
        compact()
        return out
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    func write(_ string: String) { write(Data(string.utf8)) }
    func writeLine(_ string: String) { write(string + "\r\n") }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = recv(fd, &chunk, chunk.count, 0)
        guard n > 0 else { return false }
        buffer.append(chunk, count: n)
        return true
    }

    private func compact() {
        if start > 1 << 20 {
            buffer.removeSubrange(0..<start)
            buffer = Data(buffer)  // reset indices to start at 0
            start = 0
        }
    }
}
