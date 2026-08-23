import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true

        self.init(window: window)
        window.delegate = self

        let content = SettingsView(onDone: { [weak self] in
            self?.close()
        })
        window.contentViewController = NSHostingController(rootView: content)
    }

    func showFocused(on screen: NSScreen?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window { WindowSizing.center(window, on: screen) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let window { WindowSizing.center(window, on: screen, reapply: true) }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }
}
