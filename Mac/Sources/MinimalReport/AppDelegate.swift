import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()
    private var pollingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var cleanupWindowController: CleanupWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var memoryCleanupWindowController: MemoryCleanupWindowController?

    // Clipboard history
    private let clipboardHistory = ClipboardHistoryManager()
    private var hotkeyManager: GlobalHotkeyManager?
    private var clipboardPanel: ClipboardHistoryPanel?

    /// How often IP + system stats are auto-refreshed.
    private static let pollInterval: UInt64 = 10_000_000_000 // 10s in nanoseconds

    // Menu bar metrics (network speed + CPU/memory)
    private var prevCounters: NetCounters = .zero
    private var prevCounterTime: Date = Date()
    private var downSamples: [Double] = Array(repeating: 0, count: 5)
    private var upSamples: [Double]   = Array(repeating: 0, count: 5)
    private var prevCPUSample: CPUSample?
    private var cpuSamples: [Double] = Array(repeating: 0, count: 5)
    private var memSamples: [Double] = Array(repeating: 0, count: 5)
    private var lastDownBps: Double = 0
    private var lastUpBps: Double = 0
    private var menuBarTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        observeState()
        startMenuBarMonitor()
        setupClipboardHistory()
        Task { await performRefresh() }
        startPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarTimer?.invalidate()
        clipboardHistory.stop()
        hotkeyManager?.unregister()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🏳 Fetching..."
            button.imagePosition = .imageLeft
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 475)
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                appState: appState,
                onRefresh: { [weak self] in Task { await self?.performRefresh() } },
                onOpenCleanup: { [weak self] in Task { @MainActor in self?.openCleanup() } },
                onOpenMemoryCleanup: { [weak self] in Task { @MainActor in self?.openMemoryCleanup() } },
                onOpenSettings: { [weak self] in Task { @MainActor in self?.openSettings() } }
            )
        )
    }

    private func observeState() {
        appState.$ipAddress
            .combineLatest(appState.$countryFlag)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateMenuTitle() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuTitle),
            name: NSNotification.Name("minimalReport.ipSettingChanged"),
            object: nil
        )
    }

    @objc private func updateMenuTitle() {
        let ip = appState.ipAddress
        let flag = appState.countryFlag
        let showIp = UserDefaults.standard.object(forKey: Self.showIpKey) as? Bool ?? true
        let showFlag = UserDefaults.standard.object(forKey: Self.showIpFlagKey) as? Bool ?? true

        var parts: [String] = []
        if showFlag { parts.append(flag) }
        if showIp { parts.append(ip) }
        statusItem.button?.title = parts.joined(separator: " ")
    }

    // MARK: - Menu bar metrics

    private static let networkSpeedKey = "minimalReport.showNetworkSpeed"
    private static let cpuMemoryKey = "minimalReport.showCPUMemoryInMenuBar"
    private static let menuBarWaveformsKey = "minimalReport.showMenuBarWaveforms"
    private static let menuBarColorsKey = "minimalReport.showMenuBarColors"
    private static let showIpKey = "minimalReport.showIpInMenuBar"
    private static let showIpFlagKey = "minimalReport.showIpFlagInMenuBar"
    private static let clipboardHistoryEnabledKey = "minimalReport.clipboardHistoryEnabled"
    private static let clipboardHistorySizeKey = "minimalReport.clipboardHistorySizeMB"

    private var networkSpeedEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.networkSpeedKey) as? Bool ?? true
    }

    private var cpuMemoryEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.cpuMemoryKey) as? Bool ?? true
    }

    private var menuBarWaveformsEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.menuBarWaveformsKey) as? Bool ?? true
    }

    private var menuBarColorsEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.menuBarColorsKey) as? Bool ?? true
    }

    private func startMenuBarMonitor() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyMenuBarVisibility),
            name: NSNotification.Name("minimalReport.networkSpeedSettingChanged"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyMenuBarVisibility),
            name: NSNotification.Name("minimalReport.cpuMemorySettingChanged"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyMenuBarVisibility),
            name: NSNotification.Name("minimalReport.menuBarWaveformsSettingChanged"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyMenuBarVisibility),
            name: NSNotification.Name("minimalReport.menuBarColorsSettingChanged"),
            object: nil
        )
        prevCounters = NetworkSpeedService.readCounters()
        prevCounterTime = Date()
        prevCPUSample = CPUMemoryService.readCPUSample()
        menuBarTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(tickMenuBarMetrics),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(menuBarTimer!, forMode: .common)
    }

    @objc private func applyMenuBarVisibility() {
        refreshMenuBarImage()
    }

    @objc private func tickMenuBarMetrics() {
        let now = Date()
        let counters = NetworkSpeedService.readCounters()
        let dt = now.timeIntervalSince(prevCounterTime)

        if dt > 0.5 && dt < 5 {
            let downBytes = counters.bytesIn >= prevCounters.bytesIn
                ? Double(counters.bytesIn - prevCounters.bytesIn) : 0
            let upBytes = counters.bytesOut >= prevCounters.bytesOut
                ? Double(counters.bytesOut - prevCounters.bytesOut) : 0

            lastDownBps = downBytes / dt
            lastUpBps   = upBytes   / dt

            downSamples.removeFirst(); downSamples.append(Self.normalizeSpeed(lastDownBps))
            upSamples.removeFirst();   upSamples.append(Self.normalizeSpeed(lastUpBps))

            appState.updateNetworkSpeed(download: lastDownBps, upload: lastUpBps)
        }

        if let currentCPU = CPUMemoryService.readCPUSample() {
            if let previousCPU = prevCPUSample {
                let cpuPercent = CPUMemoryService.cpuUsagePercent(
                    previous: previousCPU, current: currentCPU)
                cpuSamples.removeFirst(); cpuSamples.append(cpuPercent / 100.0)
                let memPercent = CPUMemoryService.memoryUsagePercent()
                memSamples.removeFirst(); memSamples.append(memPercent / 100.0)
                appState.updateCPUMemory(cpu: cpuPercent, memory: memPercent)
            }
            prevCPUSample = currentCPU
        } else {
            let memPercent = CPUMemoryService.memoryUsagePercent()
            memSamples.removeFirst(); memSamples.append(memPercent / 100.0)
            appState.updateCPUMemory(cpu: appState.cpuUsagePercent, memory: memPercent)
        }

        refreshMenuBarImage()

        prevCounters = counters
        prevCounterTime = now
    }

    private func refreshMenuBarImage() {
        var parts: [NSImage] = []

        if cpuMemoryEnabled {
            parts.append(Self.makeCPUMemoryImage(
                cpuPercent: appState.cpuUsagePercent,
                memoryPercent: appState.memoryUsagePercent,
                cpuSamples: cpuSamples,
                memSamples: memSamples,
                showBars: menuBarWaveformsEnabled,
                colored: menuBarColorsEnabled))
        }

        if networkSpeedEnabled {
            parts.append(Self.makeNetworkImage(
                downBps: lastDownBps, upBps: lastUpBps,
                downSamples: downSamples, upSamples: upSamples,
                showBars: menuBarWaveformsEnabled,
                colored: menuBarColorsEnabled))
        }

        statusItem.button?.image = parts.isEmpty
            ? nil
            : Self.compositeHorizontally(parts, gap: 6, template: !menuBarColorsEnabled)
    }

    private static let menuBarFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)

    private static let cpuMemTextColumnW: CGFloat = {
        let attrs: [NSAttributedString.Key: Any] = [.font: menuBarFont]
        return ceil(("100%" as NSString).size(withAttributes: attrs).width)
    }()

    private static let networkTextColumnW: CGFloat = {
        let attrs: [NSAttributedString.Key: Any] = [.font: menuBarFont]
        return ceil(("999.9 MB/s" as NSString).size(withAttributes: attrs).width)
    }()

    private static func normalizeSpeed(_ bps: Double) -> Double {
        guard bps > 0 else { return 0 }
        // Log scale: 0 at 0 bps, 1.0 at ~100 MB/s
        return min(1.0, log10(1.0 + bps / 1000.0) / 5.0)
    }

    private static func formatSpeedShort(_ bps: Double) -> String {
        if bps < 1_048_576 {
            return String(format: "%6.1f KB/s", max(0, bps) / 1024)
        }
        return String(format: "%6.1f MB/s", bps / 1_048_576)
    }

    private static func formatPercentShort(_ percent: Double) -> String {
        String(format: "%3.0f%%", min(100, max(0, percent)))
    }

    private static func drawRightAlignedText(
        _ text: NSString,
        attrs: [NSAttributedString.Key: Any],
        columnW: CGFloat,
        rowOriginY: CGFloat,
        rowH: CGFloat
    ) {
        let sz = text.size(withAttributes: attrs)
        let x = columnW - sz.width
        let y = rowOriginY + (rowH - sz.height) / 2
        text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    private static func compositeHorizontally(_ images: [NSImage], gap: CGFloat, template: Bool) -> NSImage {
        guard !images.isEmpty else { return NSImage() }
        if images.count == 1 {
            images[0].isTemplate = template
            return images[0]
        }

        let totalW = images.reduce(CGFloat(0)) { $0 + $1.size.width }
                  + gap * CGFloat(images.count - 1)
        let maxH = images.map(\.size.height).max() ?? 0

        let composite = NSImage(size: NSSize(width: totalW, height: maxH), flipped: false) { _ in
            var x: CGFloat = 0
            for image in images {
                image.draw(at: NSPoint(x: x, y: (maxH - image.size.height) / 2),
                           from: NSRect(origin: .zero, size: image.size),
                           operation: .sourceOver, fraction: 1.0)
                x += image.size.width + gap
            }
            return true
        }
        composite.isTemplate = template
        return composite
    }

    private static func menuBarInkColor(colored: Bool, accent: NSColor) -> NSColor {
        colored ? accent : .black
    }

    private static func makeCPUMemoryImage(
        cpuPercent: Double, memoryPercent: Double,
        cpuSamples: [Double], memSamples: [Double],
        showBars: Bool,
        colored: Bool
    ) -> NSImage {
        let rowH: CGFloat  = 11
        let imgH: CGFloat  = rowH * 2
        let barW: CGFloat  = 3
        let barGap: CGFloat = 1
        let n = 5
        let barsW = CGFloat(n) * barW + CGFloat(n - 1) * barGap
        let textGap: CGFloat = 4

        let cpuColor = menuBarInkColor(colored: colored,
                                       accent: NSColor(red: 0.25, green: 0.75, blue: 1.0, alpha: 1.0))
        let memColor = menuBarInkColor(colored: colored,
                                       accent: NSColor(red: 0.75, green: 0.45, blue: 1.0, alpha: 1.0))

        let cpuText = formatPercentShort(cpuPercent) as NSString
        let memText = formatPercentShort(memoryPercent) as NSString

        let cpuAttrs: [NSAttributedString.Key: Any] = [.font: menuBarFont, .foregroundColor: cpuColor]
        let memAttrs: [NSAttributedString.Key: Any] = [.font: menuBarFont, .foregroundColor: memColor]

        let textColumnW = cpuMemTextColumnW
        let imgW = textColumnW + (showBars ? textGap + barsW : 0)

        let image = NSImage(size: NSSize(width: imgW, height: imgH), flipped: false) { _ in
            drawRightAlignedText(cpuText, attrs: cpuAttrs, columnW: textColumnW,
                                 rowOriginY: rowH, rowH: rowH)

            if showBars {
                let barX = textColumnW + textGap
                cpuColor.setFill()
                for i in 0..<n {
                    let norm = CGFloat(i < cpuSamples.count ? cpuSamples[i] : 0)
                    let h = max(1.5, norm * (rowH - 1))
                    let x = barX + CGFloat(i) * (barW + barGap)
                    NSBezierPath(roundedRect: NSRect(x: x, y: rowH + (rowH - h) / 2,
                                                      width: barW, height: h),
                                 xRadius: 0.5, yRadius: 0.5).fill()
                }
            }

            drawRightAlignedText(memText, attrs: memAttrs, columnW: textColumnW,
                                 rowOriginY: 0, rowH: rowH)

            if showBars {
                let barX = textColumnW + textGap
                memColor.setFill()
                for i in 0..<n {
                    let norm = CGFloat(i < memSamples.count ? memSamples[i] : 0)
                    let h = max(1.5, norm * (rowH - 1))
                    let x = barX + CGFloat(i) * (barW + barGap)
                    NSBezierPath(roundedRect: NSRect(x: x, y: (rowH - h) / 2,
                                                      width: barW, height: h),
                                 xRadius: 0.5, yRadius: 0.5).fill()
                }
            }

            return true
        }
        image.isTemplate = !colored
        return image
    }

    private static func makeNetworkImage(
        downBps: Double, upBps: Double,
        downSamples: [Double], upSamples: [Double],
        showBars: Bool,
        colored: Bool
    ) -> NSImage {
        let rowH: CGFloat  = 11      // height of each speed row
        let imgH: CGFloat  = rowH * 2
        let barW: CGFloat  = 3
        let barGap: CGFloat = 1
        let n = 5
        let barsW = CGFloat(n) * barW + CGFloat(n - 1) * barGap   // 19pt
        let textGap: CGFloat = 4

        let greenColor  = menuBarInkColor(colored: colored,
                                          accent: NSColor(red: 0.2, green: 0.85, blue: 0.45, alpha: 1.0))
        let yellowColor = menuBarInkColor(colored: colored,
                                          accent: NSColor(red: 1.0, green: 0.80, blue: 0.1, alpha: 1.0))

        let downText = formatSpeedShort(downBps) as NSString
        let upText   = formatSpeedShort(upBps)   as NSString

        let downAttrs: [NSAttributedString.Key: Any] = [.font: menuBarFont, .foregroundColor: greenColor]
        let upAttrs:   [NSAttributedString.Key: Any] = [.font: menuBarFont, .foregroundColor: yellowColor]

        let textColumnW = networkTextColumnW
        let imgW = textColumnW + (showBars ? textGap + barsW : 0)

        let image = NSImage(size: NSSize(width: imgW, height: imgH), flipped: false) { _ in
            drawRightAlignedText(downText, attrs: downAttrs, columnW: textColumnW,
                                 rowOriginY: rowH, rowH: rowH)

            if showBars {
                let barX = textColumnW + textGap
                greenColor.setFill()
                for i in 0..<n {
                    let norm = CGFloat(i < downSamples.count ? downSamples[i] : 0)
                    let h = max(1.5, norm * (rowH - 1))
                    let x = barX + CGFloat(i) * (barW + barGap)
                    NSBezierPath(roundedRect: NSRect(x: x, y: rowH + (rowH - h) / 2,
                                                      width: barW, height: h),
                                 xRadius: 0.5, yRadius: 0.5).fill()
                }
            }

            drawRightAlignedText(upText, attrs: upAttrs, columnW: textColumnW,
                                 rowOriginY: 0, rowH: rowH)

            if showBars {
                let barX = textColumnW + textGap
                yellowColor.setFill()
                for i in 0..<n {
                    let norm = CGFloat(i < upSamples.count ? upSamples[i] : 0)
                    let h = max(1.5, norm * (rowH - 1))
                    let x = barX + CGFloat(i) * (barW + barGap)
                    NSBezierPath(roundedRect: NSRect(x: x, y: (rowH - h) / 2,
                                                      width: barW, height: h),
                                 xRadius: 0.5, yRadius: 0.5).fill()
                }
            }

            return true
        }
        image.isTemplate = !colored
        return image
    }

    // MARK: - Clipboard history

    private func setupClipboardHistory() {
        // Re-apply enable/size whenever Settings changes the toggles.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applyClipboardHistorySetting),
            name: NSNotification.Name("minimalReport.clipboardHistorySettingChanged"),
            object: nil
        )
        applyClipboardHistorySetting()
    }

    @objc private func applyClipboardHistorySetting() {
        let enabled = clipboardHistoryEnabled

        if enabled {
            clipboardHistory.start()
            if hotkeyManager == nil {
                let mgr = GlobalHotkeyManager(keyCode: UInt32(kVK_ANSI_V),
                                              modifiers: UInt32(cmdKey | optionKey))
                mgr.onTrigger = { [weak self] in
                    Task { @MainActor in self?.openClipboardHistory() }
                }
                mgr.register()
                hotkeyManager = mgr
            }
        } else {
            clipboardHistory.stop()
            hotkeyManager?.unregister()
            hotkeyManager = nil
        }
    }

    private var clipboardHistoryEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.clipboardHistoryEnabledKey) as? Bool ?? true
    }

    @MainActor
    private func openClipboardHistory() {
        if clipboardPanel == nil {
            clipboardPanel = ClipboardHistoryPanel(history: clipboardHistory)
        }
        clipboardPanel?.showNearCursor()
    }

    // MARK: - Refresh
    private func startPolling() {
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                guard !Task.isCancelled else { break }
                await performRefresh()
            }
        }
    }

    private func performRefresh() async {
        await MainActor.run { appState.isRefreshing = true }

        async let ipFetch = IPService.fetch()
        async let statsFetch = Task.detached(priority: .userInitiated) {
            SystemStatsService.fetch()
        }.value

        let (ip, stats) = await (ipFetch, statsFetch)

        await MainActor.run {
            if let r = ip {
                self.appState.updateIP(address: r.ip, countryCode: r.countryCode)
            }
            self.appState.updateSystemStats(
                diskTotal: stats.diskTotal,
                diskAvailable: stats.diskAvailable,
                ramTotal: stats.ramTotal,
                ramAvailable: stats.ramAvailable
            )
            self.appState.isRefreshing = false
        }
    }

    /// Screen the popover (or its status-item anchor) is on. Read before
    /// closing the popover so the window is not already gone.
    private var popoverScreen: NSScreen? {
        popover.contentViewController?.view.window?.screen
            ?? statusItem.button?.window?.screen
    }

    // MARK: - Disk Cleanup window

    @MainActor
    private func openCleanup() {
        let screen = popoverScreen
        popover.performClose(nil)
        if cleanupWindowController == nil {
            let wc = CleanupWindowController()
            wc.onClose = { [weak self] in self?.cleanupWindowController = nil }
            cleanupWindowController = wc
        }
        cleanupWindowController?.showFocused(on: screen)
    }

    // MARK: - Memory Cleanup window

    @MainActor
    private func openMemoryCleanup() {
        let screen = popoverScreen
        popover.performClose(nil)
        if memoryCleanupWindowController == nil {
            let wc = MemoryCleanupWindowController()
            wc.onClose = { [weak self] in self?.memoryCleanupWindowController = nil }
            memoryCleanupWindowController = wc
        }
        memoryCleanupWindowController?.showFocused(on: screen)
    }

    // MARK: - Settings window

    @MainActor
    private func openSettings() {
        let screen = popoverScreen
        popover.performClose(nil)
        if settingsWindowController == nil {
            let wc = SettingsWindowController()
            wc.onClose = { [weak self] in self?.settingsWindowController = nil }
            settingsWindowController = wc
        }
        settingsWindowController?.showFocused(on: screen)
    }

    // MARK: - Popover toggle

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            let anchor = button.superview ?? button
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            snapPopoverToStatusItem()
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            checkForUpdates()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        snapPopoverToStatusItem()
    }

    func popoverDidShow(_ notification: Notification) {
        snapPopoverToStatusItem()
    }

    /// NSPopover clamps to the desktop below the menu bar; `relativeTo:` cannot
    /// close that gap. Move the popover window so its top sits on the status
    /// item. Animation and the arrow stay enabled.
    private func snapPopoverToStatusItem() {
        guard let button = statusItem.button,
              let statusWindow = button.window,
              let popoverWindow = popover.contentViewController?.view.window
        else { return }

        popoverWindow.animationBehavior = .none
        var frame = popoverWindow.frame
        frame.origin.y = statusWindow.frame.minY - frame.height
        popoverWindow.setFrame(frame, display: true)
    }

    // MARK: - Update check

    private func checkForUpdates() {
        Task { @MainActor in
            if case .checking = appState.updateStatus { return }
            appState.updateStatus = .checking
            let status = await UpdateChecker.check()
            appState.updateStatus = status
        }
    }
}
