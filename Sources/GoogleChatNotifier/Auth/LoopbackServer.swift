import Darwin
import Foundation

/// A one-shot HTTP listener on 127.0.0.1 used as the OAuth redirect target
/// (Google's recommended "loopback IP address" flow for desktop apps).
/// Implemented with plain BSD sockets: bind to 127.0.0.1 on an OS-assigned port.
///
/// `@unchecked Sendable`: every mutable property is only read or written on `queue`
/// (a private serial queue), which provides the synchronization the compiler can't verify.
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lendingpad.GoogleChatNotifier.loopback")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    /// Starts listening on 127.0.0.1 with an OS-assigned port and returns that port.
    func start() async throws -> UInt16 {
        try queue.sync { try self.openListener() }
    }

    /// Waits for the browser to hit the redirect URI. Returns the query parameters.
    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let result = self.result {
                    cont.resume(with: result)
                    return
                }
                self.continuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.complete(.failure(AuthError.timedOut))
                }
            }
        }
    }

    func cancel() {
        queue.async { self.complete(.failure(CancellationError())) }
    }

    func stop() {
        queue.async {
            self.acceptSource?.cancel()   // cancel handler closes the socket
            self.acceptSource = nil
            self.listenFD = -1
        }
    }

    // MARK: - Private (all on `queue`)

    private static func posixError(_ what: String) -> Error {
        let code = errno
        let message = String(cString: strerror(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "Local sign-in listener failed (\(what)): \(message)"])
    }

    private func openListener() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError("socket") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                                  // let the OS pick a free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = Self.posixError("bind")
            Darwin.close(fd)
            throw error
        }
        guard listen(fd, 8) == 0 else {
            let error = Self.posixError("listen")
            Darwin.close(fd)
            throw error
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            let error = Self.posixError("getsockname")
            Darwin.close(fd)
            throw error
        }
        let port = UInt16(bigEndian: bound.sin_port)

        // Non-blocking listener driven by a dispatch source.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { _ = Darwin.close(fd) }
        source.resume()

        listenFD = fd
        acceptSource = source
        return port
    }

    private func acceptPending() {
        guard listenFD >= 0 else { return }
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { break }   // EAGAIN: nothing more to accept
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { Darwin.close(client) }

        // Accepted sockets inherit O_NONBLOCK on macOS; make this one blocking with a timeout.
        let flags = fcntl(client, F_GETFL)
        _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Read until the end of the request headers (we only need the request line).
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.count < 65536 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            received.append(contentsOf: buffer[0..<count])
            if received.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }

        let request = String(decoding: received, as: UTF8.self)
        let requestLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1" + parts[1])
        else {
            respond(client, status: "400 Bad Request", body: Self.page("Bad request"))
            return
        }

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            params[item.name] = item.value ?? ""
        }

        // Ignore unrelated requests such as /favicon.ico.
        guard params["code"] != nil || params["error"] != nil else {
            respond(client, status: "404 Not Found", body: Self.page("Not found"))
            return
        }

        if let error = params["error"] {
            respond(client, status: "200 OK",
                    body: Self.page("Sign-in was not completed (\(error)). You can close this tab."))
        } else {
            respond(client, status: "200 OK",
                    body: Self.page("You're signed in to Google Chat Notifier. You can close this tab."))
        }
        complete(.success(params))
    }

    private func respond(_ client: Int32, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(bodyData)
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(client, base + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func complete(_ newResult: Result<[String: String], Error>) {
        guard result == nil else { return }
        result = newResult
        if let continuation {
            self.continuation = nil
            continuation.resume(with: newResult)
        }
    }

    private static func page(_ message: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Google Chat Notifier</title>
        <style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;
        justify-content:center;height:90vh;color:#1d1d1f;background:#f5f5f7}div{background:#fff;padding:32px 40px;
        border-radius:14px;box-shadow:0 2px 12px rgba(0,0,0,.08)}</style></head>
        <body><div>\(message)</div></body></html>
        """
    }
}
