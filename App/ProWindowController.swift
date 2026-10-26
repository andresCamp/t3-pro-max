// One T3 Code Pro Max window: a full T3 web client in a WKWebView.
//
// Each window has its own persistent WebKit data store (macOS 14+), so its sidebar
// filters, panels and drafts are its own and survive relaunch. The flip side is that
// each window is a separate client of the server and pairs on its own, silently,
// through `T3Server.pairingURL`. Closing a window for good revokes its session and
// deletes its store; quitting the app keeps both so the window comes back as it was.

import AppKit
import SwiftUI
import WebKit

@MainActor
final class ProWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private(set) var record: WindowRecord
    private let webView: WKWebView
    private let waiting = WaitingModel()
    private lazy var waitingView = NSHostingView(rootView: WaitingView(model: waiting))
    private var observations: [NSKeyValueObservation] = []
    private var pairingTask: Task<Void, Never>?
    private var pairAttempts = 0
    /// The page to show once pairing finishes: pairing always lands on T3's home page.
    private var pendingPath: String?
    /// True once the web page is showing; until then it loads under the cover, out of sight.
    private var revealed = false
    /// The current page has drawn T3's app shell (page-bridge.js says so).
    private var pageReady = false
    /// The page under the cover is the one to show: signed in, no redirect still to come.
    private var finalPage = false
    private var revealFallback: Task<Void, Never>?
    /// A spare window pairs and loads out of sight, so New Window can show a ready page
    /// at once. It is saved, listed and shown only once `adopt` makes it a real window.
    private(set) var isSpare: Bool

    /// Called when the window closes for good (not when the app quits).
    var onClose: ((ProWindowController) -> Void)?

    private let tools = TitlebarTools()
    private let tabStrip: TitlebarTabs
    /// The sidebar's project filter, as T3 labels it ("owner/name"); nil when all projects show.
    private(set) var scope: String?
    /// The page has reported its filter at least once, so a nil `scope` means all projects.
    private var scopeKnown = false
    /// The filtered project's icon, as T3's sidebar draws it.
    private var icon: NSImage?
    /// When the window last became key, to pick the most recently used window.
    private(set) var lastActive = Date.distantPast
    /// Tags (see ThreadIndex) of every thread this window has shown since launch.
    private(set) var visitedThreads: Set<String> = []

    static let defaultTitle = "T3 Code Pro Max"
    /// Zoom steps, as in Safari.
    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    init(record: WindowRecord, spare: Bool = false) {
        self.record = record
        isSpare = spare
        tabStrip = TitlebarTabs(current: record.id)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: record.id)
        configuration.preferences.isElementFullscreenEnabled = true
        let bridge = MessageProxy()
        configuration.userContentController.add(bridge, name: "t3pm")
        if let script = Bundle.main.url(forResource: "page-bridge", withExtension: "js")
            .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        if let settings = Notifier.settingsScript() {
            configuration.userContentController.addUserScript(
                WKUserScript(source: settings, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.pageZoom = record.zoom ?? 1

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = Self.defaultTitle
        // The tab strip names the window instead; the title still shows in the Window menu.
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 480, height: 360)
        window.tabbingIdentifier = "T3ProMax"
        window.isReleasedWhenClosed = false
        if let frame = record.frame { window.setFrame(NSRectFromString(frame), display: false) } else { window.center() }

        // One view stack for the window's whole life: the page loads under the cover, and
        // the cover fades out once there is something worth showing. Swapping the content
        // view instead showed every intermediate load (blank, pair page, home, saved page).
        let root = NSView()
        webView.frame = root.bounds
        webView.autoresizingMask = [.width, .height]
        root.addSubview(webView)
        window.contentView = root

        super.init(window: window)
        waitingView.frame = root.bounds
        waitingView.autoresizingMask = [.width, .height]
        waitingView.wantsLayer = true
        // The cover stays in the window for good, so it must not manage the window's
        // title or toolbar, which a hosting view does by default.
        waitingView.sceneBridgingOptions = []
        root.addSubview(waitingView)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        bridge.onMessage = { [weak self] body in self?.pageMessage(body) }
        window.addTitlebarAccessoryViewController(tools)
        window.addTitlebarAccessoryViewController(tabStrip)
        tabStrip.onContentWidth = { [weak self] in self?.fitTitlebar() }
        tools.zoomLabel = Self.percent(webView.pageZoom)
        tools.onZoom = { [weak self] step in self?.zoom(step) }

        waiting.onOpenT3 = { T3Server.openDesktopApp() }
        waiting.onRetry = { [weak self] in self?.pairAttempts = 0; self?.connect() }

        observations.append(webView.observe(\.url, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.urlChanged(web.url) }
        })
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Connecting and pairing

    /// Waits for the T3 server, then shows the saved page (or pairs first).
    func connect() {
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            guard let self else { return }
            var origin: URL?
            while !Task.isCancelled {
                if let found = T3Server.origin(), await T3Server.isReachable(found) { origin = found; break }
                self.showWaiting(.notRunning)
                try? await Task.sleep(for: .seconds(1.5))
            }
            guard let origin, !Task.isCancelled else { return }
            self.showWaiting(.loading)
            if self.record.paired {
                self.webView.load(URLRequest(url: await self.savedPage(on: origin)))
            } else {
                self.pendingPath = self.record.url.flatMap { URL(string: $0)?.pathQueryFragment }
                await self.pair()
            }
        }
    }

    private func pair() async {
        pairAttempts += 1
        // Three silent tries, then say so: a server refusing to pair needs a person.
        guard pairAttempts <= 3 else { showWaiting(.pairingFailed("T3 Code didn't accept the pairing.")); return }
        showWaiting(.loading)
        do {
            let url = try await T3Server.pairingURL(for: record.id)
            webView.load(URLRequest(url: url))
        } catch {
            showWaiting(.pairingFailed(error.localizedDescription))
        }
    }

    /// The saved page on the server's current port, since that can change. It keeps its
    /// own address when the server still answers there: a window is signed in only on the
    /// address it paired on, which is the network address `t3 pair` hands out, while the
    /// server reports 127.0.0.1. Loading there would mean pairing again on every launch.
    private func savedPage(on origin: URL) async -> URL {
        guard let saved = record.url.flatMap(URL.init(string:)) else { return origin }
        var base = origin
        if let host = saved.host, host != origin.host,
           var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) {
            parts.host = host
            if let signedIn = parts.url, await T3Server.isReachable(signedIn) { base = signedIn }
        }
        return URL(string: base.absoluteString.trimmingSuffix("/") + saved.pathQueryFragment) ?? origin
    }

    /// Where this window's pages live: the address it is signed in on, once it has a page.
    private var pageOrigin: URL? {
        guard let url = webView.url ?? record.url.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true, let host = url.host else {
            return T3Server.origin()
        }
        return URL(string: "\(url.scheme!)://\(host)\(url.port.map { ":\($0)" } ?? "")")
    }

    /// Asks the server, with this window's cookie, whether the window is signed in.
    private func isAuthenticated() async -> Bool? {
        let script = """
        const r = await fetch('/api/auth/session', { credentials: 'include' });
        return (await r.json()).authenticated === true;
        """
        return try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? Bool
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document: wait for it to draw before showing it.
        pageReady = false
        finalPage = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, !url.path.hasPrefix("/pair") else { return }
        Task {
            guard let authenticated = await isAuthenticated() else { revealWhenReady(); return }
            if authenticated {
                pairAttempts = 0
                record.paired = true
                persist()
                // Pairing lands on the home page, so a window opened on "/" is already there.
                if pendingPath == url.pathQueryFragment { pendingPath = nil }
                // On the address the window just signed in on, not the server's reported one.
                if let path = pendingPath, let origin = pageOrigin,
                   let target = URL(string: origin.absoluteString.trimmingSuffix("/") + path) {
                    pendingPath = nil
                    webView.load(URLRequest(url: target))
                } else {
                    revealWhenReady()
                }
            } else {
                // The session expired or was revoked in T3's settings: pair again, keep the page.
                record.paired = false
                pendingPath = pendingPath ?? record.url.flatMap { URL(string: $0)?.pathQueryFragment }
                await pair()
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // -999 is a load replaced by another (the pair page redirecting); anything else
        // usually means the server went away, e.g. the desktop app quit.
        if (error as NSError).code != NSURLErrorCancelled { connect() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    private func urlChanged(_ url: URL?) {
        guard let url, url.scheme?.hasPrefix("http") == true, !url.path.hasPrefix("/pair") else { return }
        record.url = url.absoluteString
        persist()
        if let thread = ThreadIndex.tag(page: url) { visitedThreads.insert(thread) }
    }

    /// The tag of the thread this window shows, nil when it shows no thread.
    var currentThread: String? {
        ThreadIndex.tag(page: webView.url ?? record.url.flatMap(URL.init(string:)))
    }

    // MARK: Folder title, zoom and Mission Control

    /// Shows the page once it is the final one and has drawn. T3 can render without the
    /// sidebar (collapsed), so the bridge's signal never comes; a short wait covers that.
    private func revealWhenReady() {
        finalPage = true
        if pageReady { reveal(); return }
        revealFallback?.cancel()
        revealFallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.reveal()
        }
    }

    private func reveal() {
        revealFallback?.cancel()
        guard !revealed else { return }
        revealed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            waitingView.animator().alphaValue = 0
        }
        // Hidden on a timer, not in the animation's completion handler: the cover stayed
        // up over a loaded page when that handler never ran.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard let self, self.revealed else { return }
            self.waitingView.isHidden = true
            self.window?.makeFirstResponder(self.webView)
        }
    }

    /// Messages from page-bridge.js.
    private func pageMessage(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        if message["type"] as? String == "ready" {
            pageReady = true
            if finalPage { reveal() }
            return
        }
        if let type = message["type"] as? String, type.hasPrefix("notify"),
           let id = message["id"] as? Int, let tag = message["tag"] as? String {
            if type == "notify" {
                Notifier.shared.post(from: record.id, pageID: id, title: message["title"] as? String ?? "",
                                     body: message["body"] as? String ?? "", tag: tag)
            } else {
                Notifier.shared.close(from: record.id, pageID: id, tag: tag)
            }
            return
        }
        guard message["type"] as? String == "scope" else { return }
        scope = message["name"] as? String
        scopeKnown = true
        // The title is the short name ("SalesAutomation-Project"); the owner shows in Mission Control.
        window?.title = scope.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? Self.defaultTitle
        icon = nil
        WindowTabs.shared.update(tab)
        captureIcon(message["icon"] as? [String: Any])
    }

    /// What this window's tab shows.
    var tab: WindowTabs.Tab {
        let name = scope.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            ?? (scopeKnown ? "All projects" : Self.defaultTitle)
        return WindowTabs.Tab(id: record.id, name: name, icon: icon)
    }

    /// Copies the project icon from T3's sidebar (`rect` in CSS pixels) for the tab. A
    /// picture of the page, so it matches whatever T3 draws: an image, an SVG or initials.
    private func captureIcon(_ rect: [String: Any]?) {
        guard let rect, let x = rect["x"] as? Double, let y = rect["y"] as? Double,
              let width = rect["width"] as? Double, let height = rect["height"] as? Double,
              width > 0, height > 0 else { return }
        let zoom = Double(webView.pageZoom)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
        let expected = scope
        Task { [weak self] in
            // Give an image icon a moment to load.
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, self.scope == expected,
                  let image = try? await self.webView.takeSnapshot(configuration: configuration) else { return }
            self.icon = image
            WindowTabs.shared.update(self.tab)
        }
    }

    /// Sizes the title bar's two sides to the window: the tabs get the room the tools
    /// leave, and a narrow window drops the zoom pill (zoom stays in the View menu).
    private func fitTitlebar() {
        guard let window else { return }
        tools.compact = window.frame.width < 720
        let buttons = window.standardWindowButton(.zoomButton)?.frame.maxX ?? 70
        tabStrip.fit(room: window.frame.width - buttons - 12 - tools.view.frame.width - 12)
    }

    /// -1 zooms out a step, +1 in, 0 back to 100%.
    func zoom(_ step: Int) {
        let steps = Self.zoomSteps
        let current = steps.firstIndex { $0 >= webView.pageZoom - 0.001 } ?? steps.firstIndex(of: 1)!
        let next = step == 0 ? 1 : steps[max(0, min(steps.count - 1, current + step))]
        webView.pageZoom = next
        tools.zoomLabel = Self.percent(next)
        record.zoom = next == 1 ? nil : Double(next)
        persist()
    }

    @objc func zoomInPage(_ sender: Any?) { zoom(1) }
    @objc func zoomOutPage(_ sender: Any?) { zoom(-1) }
    @objc func actualSizePage(_ sender: Any?) { zoom(0) }

    private static func percent(_ zoom: CGFloat) -> String { "\(Int((zoom * 100).rounded()))%" }

    /// Shows or hides the folder overlay while Mission Control is open.
    func setMissionControl(_ active: Bool) {
        guard revealed else { return }
        var argument: [String: Any] = ["show": active]
        if active, let icon = NSApp.applicationIconImage.pngData(size: 240) {
            argument["appIcon"] = "data:image/png;base64," + icon.base64EncodedString()
        }
        webView.callAsyncJavaScript("window.__t3pmOverlay && window.__t3pmOverlay(argument)",
                                    arguments: ["argument": argument], in: nil, in: .page)
    }

    // MARK: Control (used by the MCP server through AppDelegate)

    /// Turns the spare into a real window: placed at `frame`, on `path` if one is given.
    /// The spare has usually paired and loaded T3 already, so the page shows at once.
    func adopt(frame: String?, path: String?) {
        isSpare = false
        if let frame {
            record.frame = frame
            window?.setFrame(NSRectFromString(frame), display: false)
        }
        persist()
        guard let path, path != webView.url?.pathQueryFragment else { return }
        // Cover the switch: the spare's own page should not show on the way.
        showWaiting(.loading)
        navigate(path: path)
    }

    private func persist() {
        guard !isSpare else { return }
        WindowStore.shared.upsert(record)
    }

    /// Shows a T3 page (path, query and fragment) in this window.
    func navigate(path: String) {
        guard let origin = pageOrigin,
              let url = URL(string: origin.absoluteString.trimmingSuffix("/") + path) else { return }
        if record.paired {
            // Saved first: a window still connecting loads its saved page when it gets there.
            record.url = url.absoluteString
            persist()
            webView.load(URLRequest(url: url))
        } else {
            pendingPath = path
        }
    }

    /// The key of the project filter in the sidebar (see ThreadIndex.Project), nil when
    /// the window shows every project. T3 keeps it in the page's own storage.
    func projectFilter() async -> String? {
        let script = """
            const state = JSON.parse(localStorage.getItem("t3code:ui-state:v1") ?? "null");
            return state?.sidebarProjectScopeKey ?? null;
            """
        return try? await webView.callAsyncJavaScript(script, contentWorld: .page) as? String
    }

    /// Runs T3's own click handler for a notification this page raised, which opens its
    /// thread without reloading the page. Loads `path` instead if the page no longer has it.
    func clickNotification(_ pageID: Int, otherwise path: String?) {
        Task {
            let handled = try? await webView.callAsyncJavaScript(
                "return window.__t3pmNotificationClick ? window.__t3pmNotificationClick(id) : false",
                arguments: ["id": pageID], in: nil, contentWorld: .page) as? Bool
            if handled != true, let path { navigate(path: path) }
        }
    }


    /// A PNG of the whole window: the title bar with its tabs, and the web page or the
    /// waiting screen under it. WebKit draws the page only through its own snapshot.
    func snapshot() async -> Data? {
        guard let frameView = window?.contentView?.superview, let content = window?.contentView else { return nil }
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        if revealed, let page = try? await webView.takeSnapshot(configuration: nil) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // Window coordinates: the bitmap, like the window, has its origin at the bottom left.
            page.draw(in: content.convert(content.bounds, to: nil))
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep.representation(using: .png, properties: [:])
    }

    /// What `list_windows` reports for this window.
    var summary: [String: Any] {
        let frame = window?.frame ?? .zero
        return [
            "id": record.id.uuidString,
            "title": window?.title ?? "",
            "url": record.url ?? "",
            "screen": window?.screen.flatMap { NSScreen.screens.firstIndex(of: $0) } ?? 0,
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height],
            "focused": window?.isKeyWindow ?? false,
            "folder": scope ?? "",
            "zoom": Double(webView.pageZoom),
            "connected": revealed && record.paired,
        ]
    }

    // MARK: Waiting screen

    /// Covers the page again, at once: only an error or a lost server brings the cover back.
    private func showWaiting(_ state: WaitingModel.State) {
        waiting.state = state
        revealFallback?.cancel()
        guard revealed || waitingView.isHidden else { return }
        revealed = false
        waitingView.alphaValue = 1
        waitingView.isHidden = false
    }

    // MARK: Links, dialogs and file pickers

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // A clicked link to another site opens in the default browser, not over T3.
        if action.navigationType == .linkActivated, let url = action.request.url,
           let origin = T3Server.origin(), url.host != origin.host || url.port != origin.port {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank: a T3 page opens in a new Pro Max window, anything else in the browser.
        guard let url = action.request.url else { return nil }
        if let origin = T3Server.origin(), url.host == origin.host, url.port == origin.port {
            (NSApp.delegate as? AppDelegate)?.openWindow(path: url.pathQueryFragment)
        } else {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window else { return nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = message
        if let window { _ = await alert.beginSheetModal(for: window) }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return false }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    // MARK: Window lifecycle

    func windowDidBecomeKey(_ notification: Notification) { lastActive = Date() }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) {
        saveFrame()
        fitTitlebar()
    }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        record.frame = NSStringFromRect(frame)
        persist()
    }

    func windowWillClose(_ notification: Notification) {
        pairingTask?.cancel()
        revealFallback?.cancel()
        observations.removeAll()
        // Quitting keeps every window for next launch; closing one forgets it.
        guard (NSApp.delegate as? AppDelegate)?.isTerminating != true else { return }
        let id = record.id
        WindowStore.shared.remove(id)
        webView.removeFromSuperview()
        onClose?(self)
        // WebKit asserts that data stores are removed on the main thread.
        Task { @MainActor in
            await T3Server.revokeSessions(for: id)
            // The store can only be removed once no web view uses it.
            try? await Task.sleep(for: .seconds(1))
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
    }
}

/// The title bar's right side: a zoom pill (− 100% +), drawn as Granola draws its
/// "New note" button: a white capsule with a hairline border.
@MainActor
final class TitlebarTools: NSTitlebarAccessoryViewController {
    var onZoom: (Int) -> Void = { _ in }
    var zoomLabel = "100%" { didSet { percentButton?.title = zoomLabel } }
    private var percentButton: NSButton?
    private var zoomPill: NSView?
    /// Hides the zoom pill, for a narrow window.
    var compact = false {
        didSet {
            guard compact != oldValue, let row = view as? NSStackView else { return }
            zoomPill?.isHidden = compact
            row.frame.size.width = row.fittingSize.width
        }
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        // Set before the window adds the accessory: it reads the position then, and the
        // default (.bottom) reserves a strip under the title bar that the content view
        // never gets back.
        layoutAttribute = .trailing
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let zoomOut = PillButton.make(symbol: "minus", title: nil, tooltip: "Zoom Out") { [weak self] in self?.onZoom(-1) }
        let percent = PillButton.make(symbol: nil, title: zoomLabel, tooltip: "Actual Size") { [weak self] in self?.onZoom(0) }
        percent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percent.contentTintColor = .secondaryLabelColor
        percentButton = percent
        let zoomIn = PillButton.make(symbol: "plus", title: nil, tooltip: "Zoom In") { [weak self] in self?.onZoom(1) }
        let zoomPill = Capsule(views: [zoomOut, Divider(), percent, Divider(), zoomIn])
        self.zoomPill = zoomPill

        let row = NSStackView(views: [zoomPill])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        row.frame.size = NSSize(width: row.fittingSize.width, height: 28)
        view = row
    }
}

/// A borderless button inside a pill, running a closure when clicked.
final class PillButton: NSButton {
    private var handler: () -> Void = {}

    static func make(symbol: String?, title: String?, tooltip: String, handler: @escaping () -> Void) -> PillButton {
        let button = PillButton()
        button.handler = handler
        button.isBordered = false
        button.title = title ?? ""
        button.font = .systemFont(ofSize: 12.5)
        button.toolTip = tooltip
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            button.imagePosition = title == nil ? .imageOnly : .imageLeading
            button.imageHugsTitle = true
        }
        button.contentTintColor = .labelColor
        button.target = button
        button.action = #selector(fire)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: title == nil ? 26 : 0).isActive = true
        return button
    }

    @objc private func fire() { handler() }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if !title.isEmpty { size.width += 18 }
        return size
    }
}

/// White capsule with a hairline border holding a row of pill buttons.
final class Capsule: NSStackView {
    convenience init(views: [NSView]) {
        self.init()
        views.forEach(addArrangedSubview)
        spacing = 0
        edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        updateLayer()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Resolve the dynamic colors for the current appearance (light or dark).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { updateLayer() }
}

/// The hairline between buttons in the zoom pill.
final class Divider: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 1).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Holds the page's message handler weakly: WKUserContentController retains its
/// handlers, so the window controller registering itself would never be freed.
final class MessageProxy: NSObject, WKScriptMessageHandler {
    var onMessage: (Any) -> Void = { _ in }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage(message.body)
    }
}

extension URL {
    /// Path, query and fragment, e.g. `/env/thread?x=1#y`, for moving a page between origins.
    var pathQueryFragment: String {
        var result = path.isEmpty ? "/" : path
        if let query { result += "?" + query }
        if let fragment { result += "#" + fragment }
        return result
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A PNG of the image drawn at `size` by `size` pixels.
    func pngData(size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
