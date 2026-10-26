// Shows T3's notifications ("Thread completed", "Input needed") as this app's own, so a
// click comes back here instead of going to the T3 Code desktop app.
//
// Every window runs T3's web client, and every window that is not focused raises the same
// notification for the same event (page-bridge.js hands it over). T3 tags each one with a
// hash of its thread, so the app shows one notification per tag. AppDelegate decides which
// window a click opens: the window showing the thread, then one that showed it before,
// then one filtered to the thread's project, then a new window.

import AppKit
import SQLite3
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// A notification on screen: where it leads, and which windows raised it.
    struct Delivered {
        /// The thread's page, `/<environment>/<thread>`. Nil when the tag names no known
        /// thread, e.g. T3's provider guide notifications.
        var path: String?
        var project: ThreadIndex.Project?
        /// Each window that raised it, with the page's id for its copy.
        var senders: [UUID: Int] = [:]
        var postedAt = Date()
    }

    private var delivered: [String: Delivered] = [:]
    /// A click on a notification, with its tag.
    var onClick: ((String, Delivered) -> Void)?

    /// A script for the start of every page that gives the window T3 Code's own
    /// notification settings. T3's web client keeps its settings in each window's storage,
    /// where notifications start off; the desktop app keeps them in a file. The chime stays
    /// with the desktop app, which plays it for every window, so it sounds once.
    static func settingsScript() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/client-settings.json")
        guard let data = try? Data(contentsOf: file),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = settings["notificationMode"] as? String else { return nil }
        settings["notificationMode"] = mode == "notifications-and-sound" ? "notifications" : mode
        guard let json = try? JSONSerialization.data(withJSONObject: settings),
              let desktop = String(data: json, encoding: .utf8) else { return nil }
        return """
            (() => {
              const key = "t3code:client-settings:v1";
              const desktop = \(desktop);
              try {
                const stored = JSON.parse(localStorage.getItem(key) ?? "null");
                // A new window has none yet: it starts from all of the desktop app's settings.
                const settings = stored && typeof stored === "object" ? stored : desktop;
                settings.notificationMode = desktop.notificationMode;
                settings.inAppNotificationsEnabled = desktop.inAppNotificationsEnabled;
                localStorage.setItem(key, JSON.stringify(settings));
              } catch {}
            })();
            """
    }

    /// Must run before the app finishes launching, or a click that launches it is lost.
    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// A page raised a notification.
    func post(from window: UUID, pageID: Int, title: String, body: String, tag: String) {
        guard !tag.isEmpty else { return }
        // The other windows raise the same one a moment later: note them, show it once.
        if var entry = delivered[tag], Date().timeIntervalSince(entry.postedAt) < 2 {
            entry.senders[window] = pageID
            delivered[tag] = entry
            return
        }
        // While a window is focused, T3 shows the event in that window itself.
        guard !NSApp.isActive else { return }
        let thread = ThreadIndex.thread(tag: tag)
        delivered[tag] = Delivered(path: thread?.path, project: thread?.project, senders: [window: pageID])

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let project = thread?.project { content.subtitle = project.title }
        // Kept with the notification, for a click that arrives after a relaunch.
        content.userInfo = [
            "path": thread?.path ?? "",
            "projectTitle": thread?.project?.title ?? "",
            "projectRoot": thread?.project?.root ?? "",
        ]
        let request = UNNotificationRequest(identifier: tag, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }

    /// A page closed a notification: T3 does so when the window is focused or the thread
    /// is opened. It also closes the old copy after raising a new one with the same tag,
    /// so only the window's latest copy counts.
    func close(from window: UUID, pageID: Int, tag: String) {
        guard delivered[tag]?.senders[window] == pageID else { return }
        delivered[tag] = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tag])
    }


    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tag = response.notification.request.identifier
        let info = response.notification.request.content.userInfo
        let path = (info["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let title = info["projectTitle"] as? String ?? ""
        let root = info["projectRoot"] as? String ?? ""
        Task { @MainActor in
            let saved = Delivered(path: path, project: title.isEmpty ? nil : ThreadIndex.Project(title: title, root: root))
            let entry = self.delivered.removeValue(forKey: tag) ?? saved
            self.onClick?(tag, entry)
            completionHandler()
        }
    }
}

/// Finds the thread behind a notification. T3's tag is a hash of "<environment>:<thread>",
/// so the app hashes the threads it knows and compares.
enum ThreadIndex {
    struct Project {
        /// T3's name for the project, e.g. "Euro Mechanical", shown under the title.
        var title: String
        /// The project's folder on disk.
        var root: String

        /// True when a window's project filter shows this project's threads. T3 keys the
        /// filter by the project's git repository ("github.com/owner/repo", so one filter
        /// holds every project in that repository), or by "<environment>:<folder>" for a
        /// project without a remote. `repository` is this project's `repositoryKey()`.
        func shown(byFilter key: String, repository: String?) -> Bool {
            if let colon = key.firstIndex(of: ":"), key[key.index(after: colon)...].hasPrefix("/") {
                return String(key[key.index(after: colon)...]) == root
            }
            return repository != nil && repository == key.lowercased()
        }

        /// The project's repository as T3 names it: the git remote (origin first) as
        /// "host/owner/repo", lowercased. Nil for a folder without a remote.
        func repositoryKey() async -> String? {
            let root = root
            return await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", root, "config", "--get-regexp", #"^remote\..*\.url$"#]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                // Lines read "remote.<name>.url <url>".
                let remotes = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> (String, String)? in
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return nil }
                    return (parts[0].dropFirst("remote.".count).dropLast(".url".count).description, parts[1])
                }.sorted { $0.0 < $1.0 }
                let url = remotes.first { $0.0 == "origin" }?.1 ?? remotes.first?.1
                return url.flatMap(Project.repositoryKey(remote:))
            }.value
        }

        /// "https://github.com/Owner/Repo.git" and "git@github.com:Owner/Repo.git" both
        /// become "github.com/owner/repo".
        static func repositoryKey(remote: String) -> String? {
            let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
            var key: String
            if let url = URL(string: text), url.scheme != nil, let host = url.host {
                key = host + url.path
            } else if let at = text.firstIndex(of: "@"), let colon = text[at...].firstIndex(of: ":") {
                key = text[text.index(after: at)..<colon] + "/" + text[text.index(after: colon)...]
            } else {
                return nil
            }
            key = key.trimmingSuffix("/").trimmingSuffix(".git")
            return key.lowercased()
        }
    }

    struct Thread {
        var path: String
        var project: Project?
    }

    private static let userdata = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".t3/userdata")

    /// The server's environment id, the first segment of every thread path.
    static var environmentID: String? {
        (try? String(contentsOf: userdata.appendingPathComponent("environment-id"), encoding: .utf8))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// T3's notification tag for a thread: 64-bit FNV-1a over the UTF-16 units of
    /// "<environment>:<thread>", as 16 hex digits (`H4` in T3's web client).
    static func tag(environment: String, thread: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for unit in "\(environment):\(thread)".utf16 {
            hash ^= UInt64(unit)
            hash &*= 1099511628211
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The tag of the thread a page shows, nil for drafts, settings and the home page.
    static func tag(page url: URL?) -> String? {
        guard let url, let environment = environmentID else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == environment else { return nil }
        return tag(environment: environment, thread: parts[1])
    }

    /// The thread a tag names, with its project. Reads T3's own database, read only; nil
    /// when the tag names no thread or a T3 update has changed the tables. Clicks then
    /// still find a window showing the thread, and otherwise run T3's own click handler.
    static func thread(tag wanted: String) -> Thread? {
        guard let environment = environmentID else { return nil }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let file = userdata.appendingPathComponent("statev2.sqlite").path
        guard sqlite3_open_v2(file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 500)
        let sql = """
            SELECT t.thread_id, p.title, p.workspace_root
            FROM orchestration_v2_projection_threads t
            LEFT JOIN projection_projects p ON p.project_id = t.project_id
            WHERE t.deleted_at IS NULL
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let thread = text(0), tag(environment: environment, thread: thread) == wanted else { continue }
            // T3 writes ids such as "thread:mcp:…" into the address with the colons encoded.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encoded = thread.addingPercentEncoding(withAllowedCharacters: allowed) ?? thread
            let project = text(1).map { Project(title: $0, root: text(2) ?? "") }
            return Thread(path: "/\(environment)/\(encoded)", project: project)
        }
        return nil
    }
}
