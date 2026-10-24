// App entry point: restores last session's windows, opens new ones, builds the menus,
// and handles t3pm:// links (t3pm://open?path=/<environment>/<thread>).

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [ProWindowController] = []
    /// True while quitting, so closing windows keeps them for next launch instead of forgetting them.
    private(set) var isTerminating = false
    private let missionControl = MissionControlWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        ControlServer.start { [unowned self] request in await self.handle(request) }
        missionControl.onChange = { [unowned self] active in
            controllers.forEach { $0.setMissionControl(active) }
        }
        missionControl.start()
        let saved = WindowStore.shared.records
        if saved.isEmpty {
            openWindow()
        } else {
            saved.forEach { show($0) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        return .terminateNow
    }

    /// Quitting from the last window's close button would forget that window, so keep running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func newWindow(_ sender: Any?) { openWindow() }

    /// Opens a new window, optionally on a T3 page (path, query and fragment on the server)
    /// and on a given display (index into `NSScreen.screens`, 0 is the main display).
    @discardableResult
    func openWindow(path: String? = nil, screen: Int? = nil) -> ProWindowController {
        var record = WindowRecord(id: UUID())
        if let path, let origin = T3Server.origin() {
            record.url = origin.absoluteString.trimmingSuffix("/") + path
        }
        if let screen, NSScreen.screens.indices.contains(screen) {
            let visible = NSScreen.screens[screen].visibleFrame
            let size = NSSize(width: min(1280, visible.width), height: min(860, visible.height))
            record.frame = NSStringFromRect(NSRect(
                x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                width: size.width, height: size.height))
        } else if let front = NSApp.keyWindow {
            // Cascade from the frontmost window so a new one doesn't land exactly on top of it.
            record.frame = NSStringFromRect(front.frame.offsetBy(dx: 28, dy: -28))
        }
        WindowStore.shared.upsert(record)
        return show(record)
    }

    @discardableResult
    private func show(_ record: WindowRecord) -> ProWindowController {
        let controller = ProWindowController(record: record)
        controller.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.connect()
        return controller
    }

    // MARK: Control channel (see ControlServer and the t3pm-mcp tool)

    func handle(_ request: [String: Any]) async -> [String: Any] {
        func fail(_ message: String) -> [String: Any] { ["ok": false, "error": message] }
        let command = request["command"] as? String ?? ""
        let target = (request["id"] as? String).flatMap { id in
            controllers.first { $0.record.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
        }

        switch command {
        case "list_windows":
            return ["ok": true, "windows": controllers.map(\.summary), "screens": NSScreen.screens.count]

        case "open_window":
            let path = await resolvePath(request)
            let controller = openWindow(path: path, screen: request["screen"] as? Int)
            NSApp.activate()
            return ["ok": true, "window": controller.summary]

        case "focus_window":
            guard let target else { return fail("No window with that id.") }
            target.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return ["ok": true]

        case "navigate_window":
            guard let target else { return fail("No window with that id.") }
            guard let path = await resolvePath(request) else { return fail("Give a path, url or thread_id.") }
            target.navigate(path: path)
            return ["ok": true]

        case "zoom_window":
            guard let target else { return fail("No window with that id.") }
            target.zoom(request["step"] as? Int ?? 0)
            return ["ok": true, "window": target.summary]

        case "close_window":
            guard let target else { return fail("No window with that id.") }
            target.window?.performClose(nil)
            return ["ok": true]

        case "arrange_windows":
            arrange(layout: request["layout"] as? String ?? "columns", screen: request["screen"] as? Int)
            return ["ok": true, "windows": controllers.map(\.summary)]

        case "snapshot_window":
            guard let target = target ?? controllers.first(where: { $0.window?.isKeyWindow == true }) ?? controllers.first
            else { return fail("No windows are open.") }
            guard let png = await target.snapshot() else { return fail("Couldn't capture the window.") }
            return ["ok": true, "id": target.record.id.uuidString, "png_base64": png.base64EncodedString()]

        default:
            return fail("Unknown command \(command).")
        }
    }

    /// A T3 page path from `path`, a full `url`, or a `thread_id` (with an optional `environment_id`).
    private func resolvePath(_ request: [String: Any]) async -> String? {
        if let path = request["path"] as? String { return path.hasPrefix("/") ? path : "/" + path }
        if let url = (request["url"] as? String).flatMap(URL.init(string:)) { return url.pathQueryFragment }
        if let thread = request["thread_id"] as? String {
            let environment: String?
            if let given = request["environment_id"] as? String {
                environment = given
            } else if let origin = T3Server.origin() {
                environment = await T3Server.environmentID(origin)
            } else {
                environment = nil
            }
            return environment.map { "/\($0)/\(thread)" }
        }
        return nil
    }

    /// Tiles the windows on one display (or each display its own windows): side by side, or a grid.
    private func arrange(layout: String, screen: Int?) {
        let groups = Dictionary(grouping: controllers) { controller -> Int in
            controller.window?.screen.flatMap { NSScreen.screens.firstIndex(of: $0) } ?? 0
        }
        for (index, members) in groups {
            let target = screen ?? index
            guard NSScreen.screens.indices.contains(target) else { continue }
            let area = NSScreen.screens[target].visibleFrame
            let count = members.count
            let columns = layout == "grid" ? Int(ceil(sqrt(Double(count)))) : count
            let rows = Int(ceil(Double(count) / Double(columns)))
            let width = area.width / CGFloat(columns), height = area.height / CGFloat(rows)
            for (position, controller) in members.enumerated() {
                let column = position % columns, row = position / columns
                let frame = NSRect(x: area.minX + CGFloat(column) * width,
                                   y: area.maxY - CGFloat(row + 1) * height,
                                   width: width, height: height)
                controller.window?.setFrame(frame, display: true, animate: true)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "t3pm" {
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "path" }?.value
            openWindow(path: path)
        }
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About T3 Code Pro Max", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide T3 Code Pro Max", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit T3 Code Pro Max", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, titled: "T3 Code Pro Max", to: main)

        // No shortcut on New Window: T3 uses Cmd+N, Cmd+Shift+N and Cmd+Option+N itself.
        // Users can assign one in System Settings, Keyboard, Keyboard Shortcuts, App Shortcuts.
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, titled: "File", to: main)

        // Without these items WKWebView gets no copy, paste or undo.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, titled: "Edit", to: main)

        let view = NSMenu(title: "View")
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        add(view, titled: "View", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
