import AppKit

/// Shared helpers that keep windows inside the visible screen area and bound
/// them to a sensible default size, so no window can exceed the screen or grow
/// unbounded.
enum WindowSizing {

    /// Visible frame (excludes menu bar and Dock) of `screen`, falling back to
    /// `NSScreen.main`, then a generous default if no screen is available.
    static func visibleFrame(of screen: NSScreen? = nil) -> NSRect {
        (screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    /// The screen's visible frame (excludes menu bar and Dock). Falls back to a
    /// generous default if no screen is available (e.g. headless).
    static var visibleFrame: NSRect {
        visibleFrame(of: nil)
    }

    /// Bounds `size` to the visible frame so a window never exceeds ~90% of the
    /// screen, while never going below `minSize`.
    static func clamped(size: NSSize, minSize: NSSize, on screen: NSScreen? = nil) -> NSSize {
        let visible = visibleFrame(of: screen)
        let maxWidth = min(size.width, visible.width * 0.9)
        let maxHeight = min(size.height, visible.height * 0.9)
        return NSSize(
            width: max(minSize.width, maxWidth),
            height: max(minSize.height, maxHeight)
        )
    }

    /// Applies default + max size constraints to a resizable window so it can't
    /// be dragged larger than the screen. `preferred` is the desired default
    /// content size; `minSize` is the minimum content size.
    static func constrain(_ window: NSWindow, preferred: NSSize, minSize: NSSize, on screen: NSScreen? = nil) {
        let clamped = clamped(size: preferred, minSize: minSize, on: screen)

        window.minSize = minSize
        // maxSize is in window-frame coordinates; use a value safely above the
        // content size so it can still resize but never escapes the screen.
        let visible = visibleFrame(of: screen)
        window.maxSize = NSSize(
            width: min(visible.width, max(clamped.width, minSize.width)),
            height: min(visible.height, max(clamped.height, minSize.height))
        )

        window.setContentSize(clamped)
    }

    /// Origin that centers `size` on `screen`'s visible frame.
    static func centeredOrigin(for size: NSSize, on screen: NSScreen?) -> NSPoint {
        let visible = visibleFrame(of: screen)
        return NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
    }

    /// Clamps a candidate origin so the given window size stays fully on
    /// `screen`. Falls back to `NSScreen.main` when `screen` is nil.
    static func clampedOrigin(for size: NSSize, near point: NSPoint, on screen: NSScreen? = nil) -> NSPoint {
        let visible = visibleFrame(of: screen)
        let x = max(visible.minX, min(point.x, visible.maxX - size.width))
        let y = max(visible.minY, min(point.y, visible.maxY - size.height))
        return NSPoint(x: x, y: y)
    }

    /// Centers `window` on `screen`. When `reapply` is true, reapplies on the
    /// next run-loop turn so an accessory→regular activation cannot relocate it.
    static func center(_ window: NSWindow, on screen: NSScreen?, reapply: Bool = false) {
        window.setFrameOrigin(centeredOrigin(for: window.frame.size, on: screen))
        guard reapply else { return }
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            window.setFrameOrigin(centeredOrigin(for: window.frame.size, on: screen))
        }
    }
}
