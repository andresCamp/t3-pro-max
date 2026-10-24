// Tells the app when Mission Control (or App Exposé) opens and closes, so each window
// can show which folder it holds. macOS has no public notification for this. While
// Mission Control is open the Dock puts up full-screen windows at layers 18 and 20,
// and window owners and layers are readable without Screen Recording permission,
// so a light poll of the window list is enough.

import AppKit
import CoreGraphics

@MainActor
final class MissionControlWatcher {
    private var timer: Timer?
    private(set) var isActive = false
    var onChange: (Bool) -> Void = { _ in }

    func start() {
        // Four checks a second: Mission Control's opening animation hides the delay.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        let active = Self.dockOverlayVisible()
        guard active != isActive else { return }
        isActive = active
        onChange(active)
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
