
import AppKit
import SwiftUI

@MainActor
final class CleanupWindowController: NSWindowController, NSWindowDelegate {
    private let state = CleanupState()
    private let service = CleanupService()
    var onClose: (() -> Void)?

    private var aiQueryWindows: [AIQueryWindowController] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Disk Cleanup"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        // Bound the window to the screen so it can't exceed the display, and
        // ensure a sane default + minimum size. Content already scrolls.
        WindowSizing.constrain(window,
                               preferred: NSSize(width: 700, height: 540),
                               minSize: NSSize(width: 680, height: 500))
        self.init(window: window)
        window.delegate = self
    }

    func showFocused(on screen: NSScreen?) {
        // Wire up content lazily so `self` is fully initialised before the closure captures it.
        if window?.contentViewController == nil {
            let controller = self
            let content = CleanupView(state: state, service: service) { req in
                controller.openAIQuery(req)
            }
            window?.contentViewController = NSHostingController(rootView: content)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window { WindowSizing.center(window, on: screen) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let window { WindowSizing.center(window, on: screen, reapply: true) }
    }

    // MARK: - AI Query windows

    private func openAIQuery(_ request: AIQueryRequest) {
        let wc = AIQueryWindowController(request: request)
        aiQueryWindows.append(wc)
        wc.onClose = { [weak self, weak wc] in
            guard let wc else { return }
            self?.aiQueryWindows.removeAll { $0 === wc }
        }
        wc.show(centeredIn: window)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }
}
