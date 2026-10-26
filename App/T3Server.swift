// Talks to the T3 Code server that the T3 Code desktop app runs on this Mac.
// Every window in this app is a web client of that one server: it finds the server
// from the runtime file the server writes, and pairs each window with a one-time
// token minted by the user's own `t3` CLI, so the user never sees a pairing link.

import AppKit
import Foundation

enum T3Server {
    /// Where the T3 server records its address while it runs.
    static let runtimeFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".t3/userdata/server-runtime.json")

    /// Bundle identifier shared by the T3 Code desktop builds (Alpha and Nightly).
    static let desktopBundleID = "com.t3tools.t3code"

    struct PairingFailed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The server's origin from its runtime file, e.g. `http://127.0.0.1:3773`.
    /// Nil when T3 Code has never run or the file is unreadable.
    static func origin() -> URL? {
        guard let data = try? Data(contentsOf: runtimeFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origin = json["origin"] as? String else { return nil }
        return URL(string: origin)
    }

    /// True when the server answers its unauthenticated session endpoint.
    /// The runtime file outlives the server, so the file alone does not prove it is up.
    static func isReachable(_ origin: URL) async -> Bool {
        var request = URLRequest(url: origin.appendingPathComponent("api/auth/session"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The server's environment id, the first segment of every thread path (`/<environment>/<thread>`).
    static func environmentID(_ origin: URL) async -> String? {
        let url = origin.appendingPathComponent(".well-known/t3/environment")
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["environmentId"] as? String
    }

    /// The `t3` CLI. The desktop app installs it in ~/.t3/bin; a separate install may be on PATH.
    static func cli() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".t3/bin/t3").path,
            "/opt/homebrew/bin/t3",
            "/usr/local/bin/t3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// The label a window's session carries in the server's connections list.
    /// Unique per window, so closing a window can revoke exactly its session.
    static func sessionLabel(for windowID: UUID) -> String {
        "T3 Code Pro Max · \(windowID.uuidString.prefix(8))"
    }

    /// Mints a one-time pairing URL for one window.
    /// - Throws: `PairingFailed` when the CLI is missing or prints no pairing URL.
    static func pairingURL(for windowID: UUID) async throws -> URL {
        guard let cli = cli() else {
            throw PairingFailed(message: "Couldn't find the t3 command. Update T3 Code and try again.")
        }
        let output = try await run(cli, ["pair", "--label", sessionLabel(for: windowID), "--ttl", "2m"])
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("Pairing URL:") }),
              let url = URL(string: line.dropFirst("Pairing URL:".count).trimmingCharacters(in: .whitespaces))
        else {
            let reason = failureReason(output).map { " \($0)" } ?? ""
            throw PairingFailed(message: "T3 Code didn't return a pairing link.\(reason)")
        }
        return url
    }

    /// The message of a failed CLI command. The CLI logs failures on stdout as
    /// "[16:03:25.537] ERROR (#2): NoRunningServerError: No running T3 Code server found.",
    /// and this returns the part after the error's type name.
    static func failureReason(_ output: String) -> String? {
        guard let match = output.firstMatch(of: #/ERROR \(\#\d+\): (?:\w+Error: )?(.+)/#) else { return nil }
        let reason = match.1.trimmingCharacters(in: .whitespaces)
        return reason.isEmpty ? nil : reason
    }

    /// Revokes every session labelled for this window. Best effort: a session that
    /// already expired or was revoked in T3's settings is simply not found.
    static func revokeSessions(for windowID: UUID) async {
        let label = sessionLabel(for: windowID)
        await revokeSessions { $0 == label }
    }

    /// Revokes this app's sessions that belong to none of `windows`: left behind when the
    /// app crashed or was killed before a closed window could revoke its own.
    static func revokeSessions(keeping windows: [UUID]) async {
        let kept = Set(windows.map(sessionLabel(for:)))
        await revokeSessions { $0.hasPrefix("T3 Code Pro Max · ") && !kept.contains($0) }
    }

    /// Revokes every session whose client label matches.
    private static func revokeSessions(where matches: (String) -> Bool) async {
        guard let cli = cli(), let list = try? await run(cli, ["auth", "session", "list"]) else { return }
        // `t3 auth session list` prints blocks separated by blank lines; the first
        // line of a block is the session id, and a later line reads "client: <label> | ...".
        for block in list.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let label = lines.first { $0.hasPrefix("client: ") }
                .map { $0.dropFirst("client: ".count).components(separatedBy: " | ")[0] }
            guard let id = lines.first, let label, matches(label) else { continue }
            _ = try? await run(cli, ["auth", "session", "revoke", id])
        }
    }

    /// Opens the T3 Code desktop app, which starts the server.
    /// - Returns: false when no T3 Code build is installed.
    @MainActor @discardableResult
    static func openDesktopApp() -> Bool {
        guard let app = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: desktopBundleID).first else {
            return false
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// Runs a CLI command and returns stdout. Off the main thread.
    private static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Read before waiting: a full pipe would otherwise block the child forever.
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
