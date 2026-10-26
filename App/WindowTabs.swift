// The tab strip in every window's title bar: one tab per open window, named by its
// project, with the project's icon from T3's sidebar. The window's own tab is raised,
// so the strip doubles as the title. Clicking a tab brings that window forward, its ×
// (on hover) closes it, and the + after the last tab opens a new one.
//
// These are not macOS window tabs (`NSWindow` tabbing merges windows into one frame,
// and each window here lives on its own display or Space).

import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowTabs: ObservableObject {
    static let shared = WindowTabs()

    struct Tab: Identifiable, Equatable {
        let id: UUID
        var name: String
        var icon: NSImage?
    }

    /// In the order the windows were opened.
    @Published var tabs: [Tab] = []
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onNew: () -> Void = {}

    /// Replaces a window's tab when its project or icon changes. A spare is not listed, so it is ignored.
    func update(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }), tabs[index] != tab else { return }
        tabs[index] = tab
    }
}

/// Holds the strip on the title bar's leading side, after the window buttons and the
/// product name, which stays put while the tabs scroll. Its width
/// is the tabs' own width, capped by the room left (see `fit`), so the empty part of the
/// title bar still drags the window. When the tabs need more, they scroll sideways; a
/// fade marks each edge with tabs past it, and a › the trailing one. The + stays outside
/// the scrolling part, so it is always in reach.
@MainActor
final class TitlebarTabs: NSTitlebarAccessoryViewController {
    private let current: UUID
    private let scroll = NSScrollView()
    private lazy var row = NSHostingView(rootView: LiveTabRow(model: WindowTabs.shared, current: current))
    private let more = NSImageView()
    private let plus = NSHostingView(rootView: NewWindowButton())
    private static let plusWidth: CGFloat = 30
    private let name = NSTextField(labelWithString: ProWindowController.defaultTitle)
    private let rule = NSBox()
    /// Where the scrolling tabs start: after the name and the hairline.
    private var tabsStart: CGFloat = 0
    private let fade = CAGradientLayer()
    private var subscription: AnyCancellable?
    /// Called when the tabs' width changes, so the window can fit the strip again.
    var onContentWidth: () -> Void = {}

    init(current: UUID) {
        self.current = current
        super.init(nibName: nil, bundle: nil)
        // Set before the window adds the accessory (see TitlebarTools).
        layoutAttribute = .leading
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
        // Regular weight, not the bold title font. Centred where the tabs are, a little above the bar's middle, like the window buttons.
        name.font = .systemFont(ofSize: 13)
        name.textColor = .labelColor
        name.sizeToFit()
        name.frame.origin = NSPoint(x: 4, y: (15.5 - name.frame.height / 2).rounded())
        container.addSubview(name)
        rule.boxType = .separator
        rule.frame = NSRect(x: name.frame.maxX + 10, y: 7.5, width: 1, height: 16)
        container.addSubview(rule)
        tabsStart = rule.frame.maxX + 8
        row.sceneBridgingOptions = []
        row.sizingOptions = []
        scroll.frame = container.bounds
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = row
        scroll.wantsLayer = true
        scroll.layer?.mask = fade
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.markEdges() } }
        container.addSubview(scroll)

        more.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "More windows")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        more.contentTintColor = .secondaryLabelColor
        more.frame = NSRect(x: 0, y: 0, width: 12, height: 28)
        container.addSubview(more)

        plus.sceneBridgingOptions = []
        plus.sizingOptions = []
        plus.frame = NSRect(x: 0, y: 0, width: Self.plusWidth, height: 28)
        container.addSubview(plus)
        view = container

        subscription = WindowTabs.shared.$tabs.sink { [weak self] _ in
            // After the publish lands, so the row has drawn the new tabs.
            DispatchQueue.main.async { self?.onContentWidth() }
        }
    }

    /// The full width of `tabs` side by side (the live row has no size of its own).
    private func width(of tabs: some Collection<WindowTabs.Tab>) -> CGFloat {
        tabs.isEmpty ? 0 : NSHostingView(rootView: TabRow(tabs: Array(tabs), current: current)).fittingSize.width
    }

    /// Sizes the strip to its tabs and the +, or to `room` when they need more; then the tabs scroll.
    func fit(room: CGFloat) {
        let full = width(of: WindowTabs.shared.tabs)
        row.frame = NSRect(x: 0, y: 0, width: full, height: 28)
        let width = max(0, min(full, room - tabsStart - Self.plusWidth)).rounded(.down)
        let total = tabsStart + width + Self.plusWidth
        if abs(view.frame.width - total) > 0.5 {
            view.frame.size = NSSize(width: total, height: 28)
        }
        scroll.frame = NSRect(x: tabsStart, y: 0, width: width, height: 28)
        more.frame.origin.x = scroll.frame.maxX - more.frame.width
        plus.frame.origin.x = scroll.frame.maxX
        showCurrent()
        markEdges()
    }

    /// Scrolls this window's own tab into view, with room for the edge fade.
    private func showCurrent() {
        let tabs = WindowTabs.shared.tabs
        guard let index = tabs.firstIndex(where: { $0.id == current }) else { return }
        let start = width(of: tabs[..<index])
        let tab = NSRect(x: start, y: 0, width: width(of: tabs[...index]) - start, height: 28)
        row.scrollToVisible(tab.insetBy(dx: -40, dy: 0))
    }

    /// Fades each edge with tabs past it; the › shows while some are past the trailing edge.
    private func markEdges() {
        let width = scroll.bounds.width
        let offset = scroll.contentView.bounds.minX
        let left = offset > 1, right = offset + width < row.frame.width - 1
        more.isHidden = !right
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = scroll.bounds
        guard width > 0 else { CATransaction.commit(); return }
        let opaque = NSColor.black.cgColor, clear = NSColor.clear.cgColor
        fade.colors = [left ? clear : opaque, opaque, opaque, right ? clear : opaque]
        fade.locations = [0, NSNumber(value: Double(18 / width)), NSNumber(value: Double(1 - 44 / width)), 1]
        CATransaction.commit()
    }
}

/// The row inside the strip, following the open windows.
private struct LiveTabRow: View {
    @ObservedObject var model: WindowTabs
    let current: UUID

    var body: some View {
        TabRow(tabs: model.tabs, current: current, onSelect: model.onSelect, onClose: model.onClose)
            .frame(maxHeight: .infinity)
            // In line with the window buttons, which sit a little above the bar's middle.
            .padding(.bottom, 3)
    }
}

/// The tabs side by side, at their full width.
struct TabRow: View {
    let tabs: [WindowTabs.Tab]
    let current: UUID
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                TabButton(tab: tab, isCurrent: tab.id == current,
                          select: { onSelect(tab.id) }, close: { onClose(tab.id) })
                    .id(tab.id)
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct TabButton: View {
    let tab: WindowTabs.Tab
    let isCurrent: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) {
                    icon
                    Text(tab.name)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .fixedSize()
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCurrent ? tab.name : "Show the \(tab.name) window")

            // Its room is kept while hidden, so the tab never changes width on hover.
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hoveringClose ? .primary : .secondary)
                    .frame(width: 15, height: 15)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(hoveringClose ? 0.1 : 0)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .disabled(!hovering)
            .onHover { hoveringClose = $0 }
            .help("Close the \(tab.name) window")
            .padding(.trailing, 5)
        }
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isCurrent ? Color(nsColor: .controlBackgroundColor)
                      : hovering ? Color.primary.opacity(0.06) : .clear)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                }
                .shadow(color: .black.opacity(isCurrent ? 0.06 : 0), radius: 1, y: 1)
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var icon: some View {
        Image(nsImage: tab.icon ?? NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 15, height: 15)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// The + after the last tab.
private struct NewWindowButton: View {
    @State private var hovering = false

    var body: some View {
        Button { WindowTabs.shared.onNew() } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New Window")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 3)
    }
}
