// App entry point: restores last session's windows, opens new ones, builds the menus,
// handles t3pm:// links (t3pm://open?path=/<environment>/<thread>), and sends a
// notification click to the window that fits (see Notifier).

import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [ProWindowController] = []
    /// True while quitting, so closing windows keeps them for next launch instead of forgetting them.
    private(set) var isTerminating = false
    private let missionControl = MissionControlWatcher()
    /// The next New Window, already paired and loaded (see `prepareSpare`).
    private var spare: ProWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Notifier.shared.onClick = { [unowned self] tag, delivered in
            Task { await openNotification(tag: tag, delivered) }
        }
        Notifier.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        ControlServer.start { [unowned self] request in await self.handle(request) }
        missionControl.onChange = { [unowned self] active in
            controllers.forEach { $0.setMissionControl(active) }
        }
        missionControl.start()
        WindowTabs.shared.onSelect = { [unowned self] id in select(id) }
        WindowTabs.shared.onClose = { [unowned self] id in
            controllers.first { $0.record.id == id }?.window?.performClose(nil)
        }
        WindowTabs.shared.onNew = { [unowned self] in openWindow() }
        WindowTabs.shared.onMove = { [unowned self] id, index in move(id, to: index) }
        WindowTabs.shared.onRename = { [unowned self] id, name in
            controllers.first { $0.record.id == id }?.rename(name)
        }
        let saved = WindowStore.shared.records
        if saved.isEmpty {
            openWindow()
        } else {
            saved.forEach { show($0) }
        }
        Task {
            await removeOrphans()
            prepareSpare()
        }
    }

    /// Clears what a window leaves behind when the app dies before it can: a window
    /// closed for good normally revokes its session and deletes its WebKit store itself.
    /// Reads the open windows each time, so a window opened since launch is never touched.
    /// Runs before the first spare exists: the spare is in no list, so it would count as one.
    private func removeOrphans() async {
        await T3Server.revokeSessions(keeping: controllers.map(\.record.id))
        let live = Set(controllers.map(\.record.id))
        for id in await WKWebsiteDataStore.allDataStoreIdentifiers where !live.contains(id) {
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
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
        var frame: String?
        if let screen, NSScreen.screens.indices.contains(screen) {
            let visible = NSScreen.screens[screen].visibleFrame
            let size = NSSize(width: min(1280, visible.width), height: min(860, visible.height))
            frame = NSStringFromRect(NSRect(
                x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                width: size.width, height: size.height))
        } else if let front = NSApp.keyWindow {
            // Cascade from the frontmost window so a new one doesn't land exactly on top of it.
            frame = NSStringFromRect(front.frame.offsetBy(dx: 28, dy: -28))
        }

        // The spare has paired and loaded while out of sight: showing it skips the wait.
        if let spare {
            self.spare = nil
            spare.adopt(frame: frame, path: path)
            present(spare)
            prepareSpare()
            return spare
        }

        var record = WindowRecord(id: UUID())
        if let path, let origin = T3Server.origin() {
            record.url = origin.absoluteString.trimmingSuffix("/") + path
        }
        record.frame = frame
        WindowStore.shared.upsert(record)
        let controller = show(record)
        prepareSpare()
        return controller
    }

    @discardableResult
    private func show(_ record: WindowRecord) -> ProWindowController {
        let controller = ProWindowController(record: record)
        present(controller)
        controller.connect()
        return controller
    }

    private func present(_ controller: ProWindowController) {
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
            self?.listTabs()
        }
        controllers.append(controller)
        listTabs()
        controller.showWindow(nil)
    }

    private func listTabs() {
        WindowTabs.shared.tabs = controllers.map(\.tab)
    }

    /// A tab dropped at a new place: every window's strip follows, and so does the next launch.
    private func move(_ id: UUID, to index: Int) {
        guard let from = controllers.firstIndex(where: { $0.record.id == id }) else { return }
        controllers.insert(controllers.remove(at: from), at: min(index, controllers.count))
        listTabs()
        WindowStore.shared.reorder(controllers.map(\.record.id))
    }

    /// A click on a window's tab: brings it forward, from the Dock or another Space too.
    private func select(_ id: UUID) {
        guard let controller = controllers.first(where: { $0.record.id == id }) else { return }
        bringForward(controller)
    }

    private func bringForward(_ controller: ProWindowController) {
        guard let window = controller.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// A click on a notification (see Notifier): opens its thread in the window that fits,
    /// in order: the window showing it, a window that showed it before, a window filtered
    /// to its project, else a new window. Ties go to the window used last.
    private func openNotification(tag: String, _ delivered: Notifier.Delivered) async {
        let windows = controllers.sorted { $0.lastActive > $1.lastActive }
        if let showing = windows.first(where: { $0.currentThread == tag }) {
            bringForward(showing)
            return
        }
        var target = windows.first { $0.visitedThreads.contains(tag) }
        if target == nil, let project = delivered.project {
            let repository = await project.repositoryKey()
            for window in windows {
                if let filter = await window.projectFilter(), project.shown(byFilter: filter, repository: repository) {
                    target = window
                    break
                }
            }
        }
        if let target {
            bringForward(target)
            if let pageID = delivered.senders[target.record.id] {
                target.clickNotification(pageID, otherwise: delivered.path)
            } else if let path = delivered.path {
                target.navigate(path: path)
            }
            return
        }
        if let path = delivered.path {
            openWindow(path: path)
            NSApp.activate()
            return
        }
        // Not a thread the app could find (T3's database changed, or a guide notification):
        // T3's own handler, in the window that raised it and was used last.
        if let sender = windows.first(where: { delivered.senders[$0.record.id] != nil }),
           let pageID = delivered.senders[sender.record.id] {
            bringForward(sender)
            sender.clickNotification(pageID, otherwise: nil)
        }
    }

    /// Starts the next spare window: it pairs and loads T3 hidden, so the next New Window
    /// is ready at once. Never saved; a spare left at quit is cleared at the next launch.
    private func prepareSpare() {
        guard spare == nil, !isTerminating else { return }
        let controller = ProWindowController(record: WindowRecord(id: UUID()), spare: true)
        spare = controller
        controller.connect()
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

        // No shortcuts: T3 may use Cmd +/- itself. The title bar's zoom pill does the same.
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Actual Size", action: #selector(ProWindowController.actualSizePage(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Zoom In", action: #selector(ProWindowController.zoomInPage(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Zoom Out", action: #selector(ProWindowController.zoomOutPage(_:)), keyEquivalent: "")
        view.addItem(.separator())
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
