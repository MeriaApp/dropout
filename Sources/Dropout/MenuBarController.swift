import AppKit
import ServiceManagement

final class MenuBarController {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    // Menu item references
    private var statusMenuItem: NSMenuItem!
    private var signalMenuItem: NSMenuItem!
    private var internetMenuItem: NSMenuItem!
    private var qualityMenuItem: NSMenuItem!
    private var recentHeaderItem: NSMenuItem!
    private var statsMenuItem: NSMenuItem!
    private var reliabilityHeaderItem: NSMenuItem!
    private var soundToggle: NSMenuItem!
    private var signalWarningToggle: NSMenuItem!
    private var loginToggle: NSMenuItem!
    private var recentEventItems: [NSMenuItem] = []
    private var reliabilityItems: [NSMenuItem] = []

    #if !APPSTORE
    private var disconnectButton: NSMenuItem!
    private var autoDisconnectToggle: NSMenuItem!
    #endif

    // Callbacks
    var onExportLog: (() -> Void)?
    var onExportReport: (() -> Void)?
    var onShowAbout: (() -> Void)?
    var onQuit: (() -> Void)?

    #if !APPSTORE
    var onOpenHooksFolder: (() -> Void)?
    var onDisconnect: (() -> Void)?
    #else
    var onOpenWiFiSettings: (() -> Void)?
    #endif

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "wifi",
                accessibilityDescription: "Dropout — WiFi Monitor"
            )
        }

        menu = NSMenu()
        menu.autoenablesItems = false

        // ── Status Section ──
        statusMenuItem = NSMenuItem(title: "Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        signalMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        signalMenuItem.isEnabled = false
        menu.addItem(signalMenuItem)

        internetMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        internetMenuItem.isEnabled = false
        menu.addItem(internetMenuItem)

        qualityMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        qualityMenuItem.isEnabled = false
        menu.addItem(qualityMenuItem)

        #if !APPSTORE
        disconnectButton = NSMenuItem(
            title: "Disconnect from This Network",
            action: #selector(disconnectAction(_:)),
            keyEquivalent: "d"
        )
        disconnectButton.keyEquivalentModifierMask = .command
        disconnectButton.target = self
        menu.addItem(disconnectButton)
        #else
        let wifiSettingsBtn = NSMenuItem(
            title: "Open WiFi Settings...",
            action: #selector(openWiFiSettingsAction(_:)),
            keyEquivalent: "d"
        )
        wifiSettingsBtn.keyEquivalentModifierMask = .command
        wifiSettingsBtn.target = self
        menu.addItem(wifiSettingsBtn)
        #endif

        menu.addItem(NSMenuItem.separator())

        // ── Recent Events ──
        recentHeaderItem = sectionHeader("RECENT EVENTS")
        menu.addItem(recentHeaderItem)

        menu.addItem(NSMenuItem.separator())

        // ── Stats ──
        statsMenuItem = NSMenuItem(title: "No data yet", action: nil, keyEquivalent: "")
        statsMenuItem.isEnabled = false
        menu.addItem(statsMenuItem)

        menu.addItem(NSMenuItem.separator())

        // ── Network Reliability ──
        reliabilityHeaderItem = sectionHeader("NETWORK RELIABILITY")
        reliabilityHeaderItem.isHidden = true
        menu.addItem(reliabilityHeaderItem)

        menu.addItem(NSMenuItem.separator())

        // ── Preferences ──
        soundToggle = NSMenuItem(
            title: "Sound Alerts",
            action: #selector(toggleSound(_:)),
            keyEquivalent: ""
        )
        soundToggle.target = self
        soundToggle.state = UserDefaults.standard.bool(forKey: "soundEnabled") ? .on : .off
        menu.addItem(soundToggle)

        signalWarningToggle = NSMenuItem(
            title: "Signal Warnings",
            action: #selector(toggleSignalWarnings(_:)),
            keyEquivalent: ""
        )
        signalWarningToggle.target = self
        signalWarningToggle.state = UserDefaults.standard.bool(forKey: "signalWarningsEnabled") ? .on : .off
        menu.addItem(signalWarningToggle)

        #if !APPSTORE
        autoDisconnectToggle = NSMenuItem(
            title: "Auto-Leave Dead Networks",
            action: #selector(toggleAutoDisconnect(_:)),
            keyEquivalent: ""
        )
        autoDisconnectToggle.target = self
        autoDisconnectToggle.state = UserDefaults.standard.bool(forKey: "autoDisconnectDeadNetworks") ? .on : .off
        menu.addItem(autoDisconnectToggle)
        #endif

        loginToggle = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginToggle.target = self
        loginToggle.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(loginToggle)

        menu.addItem(NSMenuItem.separator())

        // ── Export ──
        let exportItem = NSMenuItem(
            title: "Export Log (CSV)...",
            action: #selector(exportLog(_:)),
            keyEquivalent: "e"
        )
        exportItem.keyEquivalentModifierMask = .command
        exportItem.target = self
        menu.addItem(exportItem)

        let reportItem = NSMenuItem(
            title: "Generate ISP Report...",
            action: #selector(exportReport(_:)),
            keyEquivalent: "r"
        )
        reportItem.keyEquivalentModifierMask = .command
        reportItem.target = self
        menu.addItem(reportItem)

        #if !APPSTORE
        let hooksItem = NSMenuItem(
            title: "Event Hooks...",
            action: #selector(openHooksFolderAction(_:)),
            keyEquivalent: ""
        )
        hooksItem.target = self
        menu.addItem(hooksItem)
        #endif

        menu.addItem(NSMenuItem.separator())

        // ── Footer ──
        let aboutItem = NSMenuItem(
            title: "About Dropout",
            action: #selector(showAboutAction(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "Quit Dropout",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - State Updates

    func updateWiFiState(_ state: WiFiState) {
        if state.isConnected, let ssid = state.ssid {
            statusMenuItem.title = "Connected to \(ssid)"
            signalMenuItem.title = "Signal: \(state.signalQuality.rawValue) (\(state.rssi) dBm)"
            signalMenuItem.isHidden = false

            let iconName: String
            switch state.signalQuality {
            case .excellent, .good: iconName = "wifi"
            case .fair: iconName = "wifi"
            case .weak: iconName = "wifi.exclamationmark"
            case .none: iconName = "wifi.slash"
            }
            statusItem.button?.image = NSImage(
                systemSymbolName: iconName,
                accessibilityDescription: "WiFi: \(state.signalQuality.rawValue)"
            )
        } else if !state.isPoweredOn {
            statusMenuItem.title = "WiFi Off"
            signalMenuItem.isHidden = true
            statusItem.button?.image = NSImage(
                systemSymbolName: "wifi.slash",
                accessibilityDescription: "WiFi Off"
            )
        } else {
            statusMenuItem.title = "Disconnected"
            signalMenuItem.isHidden = true
            statusItem.button?.image = NSImage(
                systemSymbolName: "wifi.slash",
                accessibilityDescription: "WiFi Disconnected"
            )
        }
    }

    func updateInternetStatus(reachable: Bool) {
        internetMenuItem.title = reachable ? "Internet: Reachable" : "Internet: Unreachable"
        internetMenuItem.isHidden = false
    }

    func updateConnectionQuality(_ report: ConnectionQuality.Report) {
        qualityMenuItem.title = report.summaryLine
        qualityMenuItem.isHidden = false
    }

    func updateRecentEvents(_ events: [WiFiEvent]) {
        for item in recentEventItems { menu.removeItem(item) }
        recentEventItems.removeAll()

        let headerIndex = menu.index(of: recentHeaderItem)
        guard headerIndex >= 0 else { return }
        var insertIndex = headerIndex + 1

        if events.isEmpty {
            let item = styledMenuItem("  No events yet", color: .tertiaryLabelColor)
            menu.insertItem(item, at: insertIndex)
            recentEventItems.append(item)
        } else {
            for event in events.prefix(8) {
                let dot = event.isNegative ? "\u{25CF}" : "\u{25CB}"
                let title = "  \(event.timeString)  \(dot) \(event.displayString)"
                let color: NSColor = event.isNegative ? .systemRed : .secondaryLabelColor
                let item = styledMenuItem(title, color: color, mono: true)
                menu.insertItem(item, at: insertIndex)
                recentEventItems.append(item)
                insertIndex += 1
            }
        }
    }

    func updateStats(disconnects: Int, downtime: TimeInterval) {
        if disconnects == 0 {
            statsMenuItem.title = "Today: No disconnects"
        } else {
            let dtStr = formatDowntime(downtime)
            statsMenuItem.title = "Today: \(disconnects) drop\(disconnects == 1 ? "" : "s"), \(dtStr) downtime"
        }
    }

    func updateNetworkReliability(_ networks: [(ssid: String, uptime: Double, disconnects: Int)]) {
        for item in reliabilityItems { menu.removeItem(item) }
        reliabilityItems.removeAll()

        let relevant = networks.filter { $0.disconnects > 0 }
        reliabilityHeaderItem.isHidden = relevant.isEmpty

        guard !relevant.isEmpty else { return }

        let headerIndex = menu.index(of: reliabilityHeaderItem)
        guard headerIndex >= 0 else { return }
        var insertIndex = headerIndex + 1

        for net in relevant.prefix(5) {
            let uptimeStr = String(format: "%.1f%%", net.uptime)
            let title = "  \(net.ssid) — \(uptimeStr) uptime, \(net.disconnects) drops"
            let item = styledMenuItem(title, color: .secondaryLabelColor, mono: false)
            menu.insertItem(item, at: insertIndex)
            reliabilityItems.append(item)
            insertIndex += 1
        }
    }

    // MARK: - Actions

    @objc private func toggleSound(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        sender.state = enabled ? .on : .off
        UserDefaults.standard.set(enabled, forKey: "soundEnabled")
    }

    @objc private func toggleSignalWarnings(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        sender.state = enabled ? .on : .off
        UserDefaults.standard.set(enabled, forKey: "signalWarningsEnabled")
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let enable = sender.state != .on
        setLoginItemEnabled(enable)
        sender.state = enable ? .on : .off
    }

    #if !APPSTORE
    @objc private func toggleAutoDisconnect(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        sender.state = enabled ? .on : .off
        UserDefaults.standard.set(enabled, forKey: "autoDisconnectDeadNetworks")
    }

    @objc private func disconnectAction(_ sender: NSMenuItem) {
        onDisconnect?()
    }

    @objc private func openHooksFolderAction(_ sender: NSMenuItem) {
        onOpenHooksFolder?()
    }
    #else
    @objc private func openWiFiSettingsAction(_ sender: NSMenuItem) {
        onOpenWiFiSettings?()
    }
    #endif

    @objc private func exportLog(_ sender: NSMenuItem) {
        onExportLog?()
    }

    @objc private func exportReport(_ sender: NSMenuItem) {
        onExportReport?()
    }

    @objc private func showAboutAction(_ sender: NSMenuItem) {
        onShowAbout?()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        onQuit?()
    }

    // MARK: - Login Item

    private func isLoginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func setLoginItemEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("dropout: login item toggle failed: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }

    private func styledMenuItem(_ title: String, color: NSColor, mono: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 12)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: color]
        )
        return item
    }

    private func formatDowntime(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else if seconds < 3600 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return secs > 0 ? "\(mins)m \(secs)s" : "\(mins)m"
        } else {
            let hours = Int(seconds) / 3600
            let mins = (Int(seconds) % 3600) / 60
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        }
    }
}
