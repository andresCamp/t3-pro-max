// t3pm-mcp: the MCP server agents use to drive T3 Code Pro Max windows.
//
// Ships inside the app (Contents/MacOS/t3pm-mcp). An agent starts it over stdio;
// it speaks MCP (JSON-RPC 2.0, one message per line) and forwards each tool call to
// the running app through its control socket (see App/ControlServer.swift). If the
// app is not running, the first call launches it.
//
// Register with Claude Code:
//   claude mcp add t3-pro-max --scope user -- "/Applications/T3 Code Pro Max.app/Contents/MacOS/t3pm-mcp"

import Foundation

let socketPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("T3 Code Pro Max/control.sock").path
let appBundleID = "com.andrescampos.t3promax"

// MARK: Tools

let idProperty: [String: Any] = [
    "type": "string",
    "description": "Window id from list_windows. The first 8 characters are enough.",
]
let pageProperties: [String: Any] = [
    "thread_id": ["type": "string", "description": "A T3 thread id; the window shows that thread."],
    "path": ["type": "string", "description": "A T3 page path instead, e.g. /settings or /<environment>/<thread>."],
]

let tools: [[String: Any]] = [
    [
        "name": "list_windows",
        "description": "List the open T3 Code Pro Max windows: id, title, page url, project folder filter, display index, frame, zoom, and which is focused.",
        "inputSchema": ["type": "object", "properties": [String: Any]()],
    ],
    [
        "name": "open_window",
        "description": "Open a new T3 Code Pro Max window, optionally on a thread and on a given display. Each window is a full T3 client with its own filters and zoom.",
        "inputSchema": ["type": "object", "properties": pageProperties.merging([
            "screen": ["type": "integer", "description": "Display index, 0 is the main display."],
        ]) { a, _ in a }],
    ],
    [
        "name": "navigate_window",
        "description": "Show a thread or page in an existing window.",
        "inputSchema": ["type": "object", "properties": pageProperties.merging(["id": idProperty]) { a, _ in a }, "required": ["id"]],
    ],
    [
        "name": "focus_window",
        "description": "Bring a window to the front.",
        "inputSchema": ["type": "object", "properties": ["id": idProperty], "required": ["id"]],
    ],
    [
        "name": "zoom_window",
        "description": "Zoom a window's page: step -1 zooms out, 1 zooms in, 0 resets to 100%.",
        "inputSchema": ["type": "object", "properties": [
            "id": idProperty,
            "step": ["type": "integer", "enum": [-1, 0, 1]],
        ], "required": ["id", "step"]],
    ],
    [
        "name": "arrange_windows",
        "description": "Tile the windows on each display, side by side (columns) or in a grid. With screen set, every window moves to that display.",
        "inputSchema": ["type": "object", "properties": [
            "layout": ["type": "string", "enum": ["columns", "grid"]],
            "screen": ["type": "integer", "description": "Display index, 0 is the main display."],
        ]],
    ],
    [
        "name": "close_window",
        "description": "Close a window for good: its session is revoked and its filters and drafts are deleted.",
        "inputSchema": ["type": "object", "properties": ["id": idProperty], "required": ["id"]],
    ],
    [
        "name": "snapshot_window",
        "description": "Take a PNG screenshot of what a window shows (the focused window if no id). Needs no Screen Recording permission.",
        "inputSchema": ["type": "object", "properties": ["id": idProperty]],
    ],
]

// MARK: Talking to the app

enum AppError: Error { case unreachable }

/// Sends one request to the app's control socket and returns its JSON reply.
func send(_ request: [String: Any]) throws -> [String: Any] {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw AppError.unreachable }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        socketPath.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw AppError.unreachable }
    var data = try JSONSerialization.data(withJSONObject: request)
    data.append(0x0A)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        reply.append(contentsOf: buffer[0..<count])
    }
    return (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? ["ok": false, "error": "Unreadable reply from the app."]
}

/// Sends a request, launching the app first if it is not running.
func sendLaunchingIfNeeded(_ request: [String: Any]) -> [String: Any] {
    if let reply = try? send(request) { return reply }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", appBundleID]
    try? open.run()
    open.waitUntilExit()
    // Wait up to ten seconds for the app's socket.
    for _ in 0..<40 {
        Thread.sleep(forTimeInterval: 0.25)
        if let reply = try? send(request) { return reply }
    }
    return ["ok": false, "error": "T3 Code Pro Max is not installed or did not start. Install it in /Applications and try again."]
}

// MARK: MCP over stdio

func respond(_ id: Any, result: [String: Any]) {
    emit(["jsonrpc": "2.0", "id": id, "result": result])
}

func respondError(_ id: Any, code: Int, message: String) {
    emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func emit(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
    guard tools.contains(where: { $0["name"] as? String == name }) else {
        return ["content": [["type": "text", "text": "Unknown tool \(name)."]], "isError": true]
    }
    var request = arguments
    request["command"] = name
    var reply = sendLaunchingIfNeeded(request)
    let ok = reply["ok"] as? Bool ?? false
    reply.removeValue(forKey: "ok")

    var content: [[String: Any]] = []
    if let png = reply.removeValue(forKey: "png_base64") as? String {
        content.append(["type": "image", "data": png, "mimeType": "image/png"])
    }
    if !ok {
        content.append(["type": "text", "text": reply["error"] as? String ?? "The app refused the request."])
    } else if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.prettyPrinted, .sortedKeys]) {
        content.append(["type": "text", "text": String(decoding: data, as: UTF8.self)])
    }
    return ["content": content, "isError": !ok]
}

while let line = readLine() {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = message["method"] as? String else { continue }
    // Notifications (no id) need no reply.
    guard let id = message["id"] else { continue }
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        respond(id, result: [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "t3-pro-max", "version": "0.1.0"],
            "instructions": "Controls T3 Code Pro Max, the multi-window companion for T3 Code. Each window is a T3 client. Get thread ids from T3's own tools (t3_thread_list) and open them in windows here.",
        ])
    case "ping":
        respond(id, result: [:])
    case "tools/list":
        respond(id, result: ["tools": tools])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        respond(id, result: callTool(name, params["arguments"] as? [String: Any] ?? [:]))
    default:
        respondError(id, code: -32601, message: "Method not found: \(method)")
    }
}
