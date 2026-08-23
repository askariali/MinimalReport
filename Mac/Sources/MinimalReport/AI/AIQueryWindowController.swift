import AppKit
import SwiftUI

@MainActor
final class AIQueryWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    convenience init(request: AIQueryRequest) {
        let title = request.type == .deletionSafety
            ? "Deletion Safety — \(request.item.displayName)"
            : "Find Cache — \(request.item.displayName)"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Keep the window inside the screen with a sensible default + min size.
        // The response area already scrolls.
        WindowSizing.constrain(window,
                               preferred: NSSize(width: 640, height: 500),
                               minSize: NSSize(width: 540, height: 400))

        self.init(window: window)
        window.delegate = self

        let content = AIQueryView(request: request, onClose: { [weak window] in
            window?.close()
        })
        window.contentViewController = NSHostingController(rootView: content)
    }

    func show(centeredIn parent: NSWindow? = nil) {
        showWindow(nil)
        let ww = window?.frame.size ?? NSSize(width: 640, height: 500)
        if let parent {
            let pw = parent.frame
            let candidate = NSPoint(
                x: pw.minX + (pw.width - ww.width) / 2,
                y: pw.minY + (pw.height - ww.height) / 2
            )
            // Clamp so the window can never open partially off-screen.
            window?.setFrameOrigin(WindowSizing.clampedOrigin(for: ww, near: candidate, on: parent.screen))
        } else if let window {
            WindowSizing.center(window, on: window.screen)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
