// The app's control channel, used by the bundled MCP server (`t3pm-mcp`) so agents can
// open, arrange and inspect windows. A Unix socket in the app's support folder,
// readable only by this user; one JSON request per connection, one JSON reply.
//
// Request: {"command": "open_window", "path": "/env/thread", "screen": 1}
// Reply:   {"ok": true, ...} or {"ok": false, "error": "..."}

import AppKit
import Foundation

enum ControlServer {
    static var socketPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("T3 Code Pro Max/control.sock").path
    }

    /// Starts listening. Called once at launch; failures are logged, the app works without it.
    static func start(handler: @escaping @Sendable ([String: Any]) async -> [String: Any]) {
        // A client that hangs up before its reply (a timed-out MCP call) makes the write
        // raise SIGPIPE, whose default action kills the whole app. Ignored, the write
        // just fails with EPIPE.
        signal(SIGPIPE, SIG_IGN)
        let path = socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return NSLog("t3pm: socket() failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return NSLog("t3pm: bind/listen failed on \(path)") }
        chmod(path, 0o600)

        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                Task.detached {
                    let reply: [String: Any]
                    if let request = readRequest(client) {
                        reply = await handler(request)
                    } else {
                        reply = ["ok": false, "error": "Bad request"]
                    }
                    var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
                    data.append(0x0A)
                    data.withUnsafeBytes { _ = write(client, $0.baseAddress, data.count) }
                    close(client)
                }
            }
        }
    }

    /// Reads up to the first newline (or EOF) and parses it as a JSON object.
    private static func readRequest(_ fd: Int32) -> [String: Any]? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(0x0A) { break }
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
