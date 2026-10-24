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

    /// Called when the window closes for good (not when the app quits).
    var onClose: ((ProWindowController) -> Void)?

    init(record: WindowRecord) {
        self.record = record

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: record.id)
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "T3 Code Pro Max"
        window.minSize = NSSize(width: 480, height: 360)
        window.tabbingIdentifier = "T3ProMax"
        window.isReleasedWhenClosed = false
        if let frame = record.frame { window.setFrame(NSRectFromString(frame), display: false) } else { window.center() }

        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.addTitlebarAccessoryViewController(NewWindowAccessory())

        waiting.onOpenT3 = { T3Server.openDesktopApp() }
        waiting.onRetry = { [weak self] in self?.pairAttempts = 0; self?.connect() }

        observations.append(webView.observe(\.url, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.urlChanged(web.url) }
        })
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                if let title = web.title, !title.isEmpty { self?.window?.title = title }
            }
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
            self.showWeb()
            if self.record.paired {
                self.webView.load(URLRequest(url: self.savedPage(on: origin)))
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
        showWaiting(.pairing)
        do {
            let url = try await T3Server.pairingURL(for: record.id)
            showWeb()
            webView.load(URLRequest(url: url))
        } catch {
            showWaiting(.pairingFailed(error.localizedDescription))
        }
    }

    /// The saved page moved onto the server's current origin, since its port can change.
    private func savedPage(on origin: URL) -> URL {
        guard let saved = record.url.flatMap(URL.init(string:)),
              let rebuilt = URL(string: origin.absoluteString.trimmingSuffix("/") + saved.pathQueryFragment)
        else { return origin }
        return rebuilt
    }

    /// Asks the server, with this window's cookie, whether the window is signed in.
    private func isAuthenticated() async -> Bool? {
        let script = """
        const r = await fetch('/api/auth/session', { credentials: 'include' });
        return (await r.json()).authenticated === true;
        """
        return try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? Bool
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, !url.path.hasPrefix("/pair") else { return }
        Task {
            guard let authenticated = await isAuthenticated() else { return }
            if authenticated {
                pairAttempts = 0
                record.paired = true
                WindowStore.shared.upsert(record)
                if let path = pendingPath, let origin = T3Server.origin(),
                   let target = URL(string: origin.absoluteString.trimmingSuffix("/") + path) {
                    pendingPath = nil
                    webView.load(URLRequest(url: target))
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
        WindowStore.shared.upsert(record)
    }

    // MARK: Control (used by the MCP server through AppDelegate)

    /// Shows a T3 page (path, query and fragment) in this window.
    func navigate(path: String) {
        guard let origin = T3Server.origin(),
              let url = URL(string: origin.absoluteString.trimmingSuffix("/") + path) else { return }
        if record.paired {
            webView.load(URLRequest(url: url))
        } else {
            pendingPath = path
        }
    }

    /// A PNG of what the window shows: the web page, or the waiting screen.
    func snapshot() async -> Data? {
        guard let window else { return nil }
        if window.contentView === webView, let image = try? await webView.takeSnapshot(configuration: nil) {
            return image.pngData
        }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
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
            "connected": window?.contentView === webView && record.paired,
        ]
    }

    // MARK: Waiting screen

    private func showWaiting(_ state: WaitingModel.State) {
        waiting.state = state
        if window?.contentView !== waitingView { window?.contentView = waitingView }
    }

    private func showWeb() {
        if window?.contentView !== webView { window?.contentView = webView }
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

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let frame = window?.frame else { return }
        record.frame = NSStringFromRect(frame)
        WindowStore.shared.upsert(record)
    }

    func windowWillClose(_ notification: Notification) {
        pairingTask?.cancel()
        observations.removeAll()
        // Quitting keeps every window for next launch; closing one forgets it.
        guard (NSApp.delegate as? AppDelegate)?.isTerminating != true else { return }
        let id = record.id
        WindowStore.shared.remove(id)
        webView.removeFromSuperview()
        onClose?(self)
        Task.detached {
            await T3Server.revokeSessions(for: id)
            // The store can only be removed once no web view uses it.
            try? await Task.sleep(for: .seconds(1))
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
    }
}

/// The "New Window" button in each window's title bar.
final class NewWindowAccessory: NSTitlebarAccessoryViewController {
    override func loadView() {
        let button = NSButton(
            image: NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: "New Window")!,
            target: nil, action: #selector(AppDelegate.newWindow(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = "New Window"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        button.frame = NSRect(x: 6, y: 2, width: 28, height: 24)
        container.addSubview(button)
        view = container
        layoutAttribute = .trailing
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
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
