// The tab strip in every window's title bar: one tab per open window, named by its
// project, with the project's icon from T3's sidebar. The window's own tab is raised,
// so the strip doubles as the title. Clicking a tab brings that window forward, its ×
// (on hover) closes it, the + after the last tab opens a new one, and dragging a tab
// reorders the windows, in every window's strip and for the next launch.
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

    /// In the order the windows were opened, or as dragged since.
    @Published var tabs: [Tab] = []
    var onSelect: (UUID) -> Void = { _ in }
    /// A tab dropped at a new index.
    var onMove: (UUID, Int) -> Void = { _, _ in }
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
    private lazy var scroller = DragScroller(scroll: scroll)
    private lazy var row = TabsHostingView(rootView: LiveTabRow(model: WindowTabs.shared, current: current, scroller: scroller))
    private let more = NSImageView()
    private let plus = TabsHostingView(rootView: NewWindowButton())
    private static let plusWidth: CGFloat = 30
    private let name = NSTextField(labelWithString: ProWindowController.defaultTitle)
    /// The fixed first tab, to the T3 Code app; nil when that app isn't installed.
    private let home: TabsHostingView<HomeTab>? = HomeTab.appURL.map { TabsHostingView(rootView: HomeTab(app: $0)) }
    /// Where the scrolling tabs start: after the name and the home tab.
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
        tabsStart = name.frame.maxX + 10
        if let home {
            home.sceneBridgingOptions = []
            home.frame = NSRect(x: tabsStart, y: 0, width: home.fittingSize.width, height: 28)
            home.sizingOptions = []
            container.addSubview(home)
            tabsStart = home.frame.maxX + 2
        }
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

        subscription = WindowTabs.shared.$tabs
            // A reorder keeps the width, and refitting would scroll away from the dropped tab.
            .removeDuplicates { Self.byID($0) == Self.byID($1) }
            .sink { [weak self] _ in
                // After the publish lands, so the row has drawn the new tabs.
                DispatchQueue.main.async { self?.onContentWidth() }
            }
    }

    private static func byID(_ tabs: [WindowTabs.Tab]) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.name) })
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
    let scroller: DragScroller

    var body: some View {
        TabRow(tabs: model.tabs, current: current, onSelect: model.onSelect, onClose: model.onClose,
               onMove: model.onMove, scroller: scroller)
            .frame(maxHeight: .infinity)
            // In line with the window buttons, which sit a little above the bar's middle.
            .padding(.bottom, 3)
    }
}

/// Host for the title bar's tabs and buttons. A drag on the title bar moves the window
/// unless the view under the pointer says otherwise: a drag on a tab reorders the tabs,
/// and a press on a button that slips a little should not carry the window off.
final class TabsHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// While a tab is dragged, scrolls the strip when the pointer nears either edge, and
/// says how far the tab has travelled along the row: the pointer's own movement plus
/// any scrolling, so the tab stays under the pointer as the row moves beneath it.
@MainActor
final class DragScroller {
    private weak var scroll: NSScrollView?
    private var startPointer: CGFloat = 0
    private var startOffset: CGFloat = 0

    init(scroll: NSScrollView) { self.scroll = scroll }

    private var offset: CGFloat { scroll?.contentView.bounds.minX ?? 0 }

    func begin() {
        startPointer = NSEvent.mouseLocation.x
        startOffset = offset
    }

    func travel() -> CGFloat {
        let pointer = NSEvent.mouseLocation
        if let scroll, let window = scroll.window, let document = scroll.documentView {
            let x = scroll.convert(window.convertPoint(fromScreen: pointer), from: nil).x
            let edge: CGFloat = 32, width = scroll.bounds.width
            let step = x < edge ? -(edge - x) / 2 : x > width - edge ? (x - (width - edge)) / 2 : 0
            if step != 0 {
                let limit = max(0, document.frame.width - width)
                scroll.contentView.scroll(to: NSPoint(x: min(max(0, offset + step), limit), y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        return (pointer.x - startPointer) + (offset - startOffset)
    }
}

/// The tabs side by side, at their full width. With `onMove`, a tab can be dragged:
/// it lifts and follows the pointer, the others slide aside to open a gap, and on
/// release it settles into the gap before the order changes.
struct TabRow: View {
    let tabs: [WindowTabs.Tab]
    let current: UUID
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onMove: ((UUID, Int) -> Void)? = nil
    var scroller: DragScroller? = nil

    private static let spacing: CGFloat = 2
    private static let slide = Animation.spring(response: 0.24, dampingFraction: 0.86)
    @State private var widths: [UUID: CGFloat] = [:]
    @State private var dragged: UUID?
    @State private var dragX: CGFloat = 0
    /// Where the dragged tab would land if dropped now.
    @State private var gap = 0
    /// True from a drag's release until the order changes, so the release is not also a click.
    @State private var settling = false

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                TabButton(tab: tab, isCurrent: tab.id == current, isLifted: dragged == tab.id,
                          select: { if dragged == nil, !settling { onSelect(tab.id) } },
                          close: { onClose(tab.id) })
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[tab.id] = $0 }
                    .offset(x: shift(of: index, tab.id))
                    .zIndex(dragged == tab.id ? 1 : 0)
                    .simultaneousGesture(drag(tab.id, from: index), including: onMove == nil ? .subviews : .all)
                    .id(tab.id)
            }
        }
        .padding(.horizontal, 2)
    }

    private func width(_ index: Int) -> CGFloat { widths[tabs[index].id] ?? 0 }

    /// The left edge of the tab at `index` in the current order.
    private func start(_ index: Int) -> CGFloat {
        (0..<index).reduce(0) { $0 + width($1) + Self.spacing }
    }

    private func shift(of index: Int, _ id: UUID) -> CGFloat {
        guard let dragged, let from = tabs.firstIndex(where: { $0.id == dragged }) else { return 0 }
        if id == dragged { return dragX }
        let room = width(from) + Self.spacing
        if from < gap, index > from, index <= gap { return -room }
        if from > gap, index < from, index >= gap { return room }
        return 0
    }

    private func drag(_ id: UUID, from index: Int) -> some Gesture {
        // A press that doesn't move is a click on the tab.
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragged == nil {
                    scroller?.begin()
                    dragged = id
                    gap = index
                }
                guard dragged == id else { return }
                let travel = scroller?.travel() ?? value.translation.width
                let total = start(tabs.count - 1) + width(tabs.count - 1)
                dragX = min(max(travel, -start(index)), total - start(index) - width(index))
                // Lands after every other tab whose middle the dragged tab's middle has passed.
                let middle = start(index) + width(index) / 2 + dragX
                let landing = tabs.indices.filter { $0 != index && start($0) + width($0) / 2 < middle }.count
                if landing != gap { withAnimation(Self.slide) { gap = landing } }
            }
            .onEnded { _ in
                guard dragged == id else { return }
                let to = gap
                settling = true
                // Settle into the gap first, then change the order with nothing left to move.
                let landed = to > index ? start(to) + width(to) - start(index) - width(index)
                    : to < index ? start(to) - start(index) : 0
                withAnimation(Self.slide) { dragX = landed }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) {
                        dragged = nil
                        dragX = 0
                        if to != index { onMove?(id, to) }
                    }
                    settling = false
                }
            }
    }
}

private struct TabButton: View {
    let tab: WindowTabs.Tab
    let isCurrent: Bool
    var isLifted = false
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
            .opacity(hovering && !isLifted ? 1 : 0)
            .disabled(!hovering || isLifted)
            .onHover { hoveringClose = $0 }
            .help("Close the \(tab.name) window")
            .padding(.trailing, 5)
        }
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isCurrent || isLifted ? Color(nsColor: .controlBackgroundColor)
                      : hovering ? Color.primary.opacity(0.06) : .clear)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                }
                // Lifted while dragged: a deeper shadow, so it reads as held above the row.
                .shadow(color: .black.opacity(isLifted ? 0.18 : isCurrent ? 0.06 : 0),
                        radius: isLifted ? 6 : 1, y: isLifted ? 3 : 1)
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

/// The fixed first tab: brings the T3 Code app forward, opening it if needed. The ↗
/// says it leaves this app; it is never the current tab and has no ×.
private struct HomeTab: View {
    static let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: T3Server.desktopBundleID)
    let app: URL
    @State private var hovering = false

    var body: some View {
        Button { _ = T3Server.openDesktopApp() } label: {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                Text("T3 Code")
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .fixedSize()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open T3 Code")
        .frame(maxHeight: .infinity)
        .padding(.bottom, 3)
    }
}
