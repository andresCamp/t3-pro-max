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

    private let tools = TitlebarTools()
    /// The sidebar's project filter, as T3 labels it ("owner/name"); nil when all projects show.
    private(set) var scope: String?

    static let defaultTitle = "T3 Code Pro Max"
    /// Zoom steps, as in Safari.
    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    init(record: WindowRecord) {
        self.record = record

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
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.pageZoom = record.zoom ?? 1

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = Self.defaultTitle
        window.minSize = NSSize(width: 480, height: 360)
        window.tabbingIdentifier = "T3ProMax"
        window.isReleasedWhenClosed = false
        if let frame = record.frame { window.setFrame(NSRectFromString(frame), display: false) } else { window.center() }

        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        bridge.onMessage = { [weak self] body in self?.pageMessage(body) }
        window.addTitlebarAccessoryViewController(tools)
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

    // MARK: Folder title, zoom and Mission Control

    /// Messages from page-bridge.js.
    private func pageMessage(_ body: Any) {
        guard let message = body as? [String: Any], message["type"] as? String == "scope" else { return }
        scope = message["name"] as? String
        // The title is the short name ("SalesAutomation-Project"); the owner shows in Mission Control.
        window?.title = scope.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? Self.defaultTitle
    }

    /// -1 zooms out a step, +1 in, 0 back to 100%.
    func zoom(_ step: Int) {
        let steps = Self.zoomSteps
        let current = steps.firstIndex { $0 >= webView.pageZoom - 0.001 } ?? steps.firstIndex(of: 1)!
        let next = step == 0 ? 1 : steps[max(0, min(steps.count - 1, current + step))]
        webView.pageZoom = next
        tools.zoomLabel = Self.percent(next)
        record.zoom = next == 1 ? nil : Double(next)
        WindowStore.shared.upsert(record)
    }

    private static func percent(_ zoom: CGFloat) -> String { "\(Int((zoom * 100).rounded()))%" }

    /// Shows or hides the folder overlay while Mission Control is open.
    func setMissionControl(_ active: Bool) {
        guard window?.contentView === webView else { return }
        var argument: [String: Any] = ["show": active]
        if active, let icon = NSApp.applicationIconImage.pngData(size: 240) {
            argument["appIcon"] = "data:image/png;base64," + icon.base64EncodedString()
        }
        webView.callAsyncJavaScript("window.__t3pmOverlay && window.__t3pmOverlay(argument)",
                                    arguments: ["argument": argument], in: nil, in: .page)
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
            "folder": scope ?? "",
            "zoom": Double(webView.pageZoom),
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

/// The title bar's right side: a zoom pill (− 100% +) and a "New window" pill,
/// drawn as Granola draws its "New note" button: a white capsule with a hairline border.
@MainActor
final class TitlebarTools: NSTitlebarAccessoryViewController {
    var onZoom: (Int) -> Void = { _ in }
    var zoomLabel = "100%" { didSet { percentButton?.title = zoomLabel } }
    private var percentButton: NSButton?

    override func loadView() {
        let zoomOut = PillButton.make(symbol: "minus", title: nil, tooltip: "Zoom Out") { [weak self] in self?.onZoom(-1) }
        let percent = PillButton.make(symbol: nil, title: zoomLabel, tooltip: "Actual Size") { [weak self] in self?.onZoom(0) }
        percent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percent.contentTintColor = .secondaryLabelColor
        percentButton = percent
        let zoomIn = PillButton.make(symbol: "plus", title: nil, tooltip: "Zoom In") { [weak self] in self?.onZoom(1) }
        let zoomPill = Capsule(views: [zoomOut, Divider(), percent, Divider(), zoomIn])

        let newWindow = PillButton.make(symbol: "plus", title: "New window", tooltip: "New Window") {
            (NSApp.delegate as? AppDelegate)?.newWindow(nil)
        }
        let newWindowPill = Capsule(views: [newWindow])

        let row = NSStackView(views: [zoomPill, newWindowPill])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        row.frame.size = NSSize(width: row.fittingSize.width, height: 28)
        view = row
        layoutAttribute = .trailing
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
