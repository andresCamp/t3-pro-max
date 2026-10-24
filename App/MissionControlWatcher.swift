// Tells the app when Mission Control (or App Exposé) opens and closes, so each window
// can show which folder it holds. macOS has no public notification for this. While
// Mission Control is open the Dock puts up full-screen windows at layers 18 and 20,
// and window owners and layers are readable without Screen Recording permission,
// so a light poll of the window list finds it.
//
// Closing is the part users notice: the Dock keeps those windows up for its ~280 ms
// closing animation. So the watcher also ends on the first sign the user chose
// something (any app activating, which is what picking a window does) and polls
// every 30 ms while open, and it ends at once on a key or click that closes Mission
// Control. One window-list check costs about 0.4 ms.

import AppKit
import CoreGraphics

@MainActor
final class MissionControlWatcher {
    private var timer: Timer?
    private(set) var isActive = false
    /// Set when an activation ended it early, so the Dock's closing animation is not
    /// read as Mission Control opening again. Cleared once the Dock windows are gone.
    private var endedEarly = false
    var onChange: (Bool) -> Void = { _ in }

    func start() {
        schedule(interval: 0.25)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endEarly() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endEarly() }
        }
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = interval / 5
    }

    private func endEarly() {
        guard isActive else { return }
        endedEarly = true
        set(false)
    }

    private func check() {
        if isActive, closeInputStarted() { return endEarly() }
        let visible = Self.dockOverlayVisible()
        if endedEarly {
            if !visible { endedEarly = false; schedule(interval: 0.25) }
            return
        }
        set(visible)
    }

    private func set(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { heldAtOpen = Self.closeInputsDown() }
        // Poll fast while open (or while waiting out the closing animation).
        schedule(interval: active || endedEarly ? 0.03 : 0.25)
        onChange(active)
    }

    // MARK: Inputs that close Mission Control

    /// Esc, F3, the Mission Control key, Up arrow (with Control) and the mouse buttons.
    /// Key and button state are readable without Input Monitoring permission.
    private static let closeKeys: [CGKeyCode] = [53, 99, 160, 126]
    private static let closeButtons: [CGMouseButton] = [.left, .right, .center]

    /// What was already held when Mission Control opened (the key or click that opened it),
    /// so only a press that starts afterwards counts.
    private var heldAtOpen: Set<String> = []

    private static func closeInputsDown() -> Set<String> {
        var down = Set<String>()
        for key in closeKeys where CGEventSource.keyState(.combinedSessionState, key: key) { down.insert("k\(key)") }
        for button in closeButtons where CGEventSource.buttonState(.combinedSessionState, button: button) {
            down.insert("b\(button.rawValue)")
        }
        return down
    }

    /// True when a closing key or click began after Mission Control opened.
    private func closeInputStarted() -> Bool {
        let down = Self.closeInputsDown()
        // Released inputs stop being "held at open", so pressing them again counts.
        heldAtOpen.formIntersection(down)
        return !down.subtracting(heldAtOpen).isEmpty
    }

    private static func dockOverlayVisible() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard window[kCGWindowOwnerName as String] as? String == "Dock",
                  let layer = window[kCGWindowLayer as String] as? Int else { return false }
            // The Dock's own bar and the wallpaper sit at other layers; 18 and 20 appear only
            // while Mission Control or App Exposé is showing.
            return layer == 18 || layer == 20
        }
    }
}
