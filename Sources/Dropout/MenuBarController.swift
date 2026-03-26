import AppKit
import ServiceManagement

final class MenuBarController {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    // Menu item references for updates
    private var statusMenuItem: NSMenuItem!
    private var signalMenuItem: NSMenuItem!
    private var internetMenuItem: NSMenuItem!
    private var separatorAfterStatus: NSMenuItem!
    private var recentHeaderItem: NSMenuItem!
    private var statsMenuItem: NSMenuItem!
    private var disconnectButton: NSMenuItem!
    private var soundToggle: NSMenuItem!
    private var signalWarningToggle: NSMenuItem!
    private var autoDisconnectToggle: NSMenuItem!
    private var loginToggle: NSMenuItem!
    private var recentEventItems: [NSMenuItem] = []

    var onExportLog: (() -> Void)?
    var onOpenHooksFolder: (() -> Void)?
    var onShowAbout: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onQuit: (() -> Void)?

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

        // Status section
        statusMenuItem = NSMenuItem(title: "Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        signalMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        signalMenuItem.isEnabled = false
        menu.addItem(signalMenuItem)

        internetMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        internetMenuItem.isEnabled = false
        menu.addItem(internetMenuItem)

        disconnectButton = NSMenuItem(
            title: "Disconnect from This Network",
            action: #selector(disconnectAction(_:)),
            keyEquivalent: "d"
        )
        disconnectButton.keyEquivalentModifierMask = .command
        disconnectButton.target = self
        disconnectButton.isHidden = false
        menu.addItem(disconnectButton)

        separatorAfterStatus = NSMenuItem.separator()
        menu.addItem(separatorAfterStatus)

        // Recent events header
        recentHeaderItem = NSMenuItem(title: "Recent Events", action: nil, keyEquivalent: "")
        recentHeaderItem.isEnabled = false
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        recentHeaderItem.attributedTitle = NSAttributedString(
            string: "RECENT EVENTS",
            attributes: [
                .font: headerFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        menu.addItem(recentHeaderItem)

        // Placeholder for recent events (populated dynamically)
        menu.addItem(NSMenuItem.separator())

        // Stats
        statsMenuItem = NSMenuItem(title: "No data yet", action: nil, keyEquivalent: "")
        statsMenuItem.isEnabled = false
        menu.addItem(statsMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences
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

        autoDisconnectToggle = NSMenuItem(
            title: "Auto-Leave Dead Networks",
            action: #selector(toggleAutoDisconnect(_:)),
            keyEquivalent: ""
        )
        autoDisconnectToggle.target = self
        autoDisconnectToggle.state = UserDefaults.standard.bool(forKey: "autoDisconnectDeadNetworks") ? .on : .off
        menu.addItem(autoDisconnectToggle)

        loginToggle = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        loginToggle.target = self
        loginToggle.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(loginToggle)

        menu.addItem(NSMenuItem.separator())

        let exportItem = NSMenuItem(
            title: "Export Log...",
            action: #selector(exportLog(_:)),
            keyEquivalent: "e"
        )
        exportItem.keyEquivalentModifierMask = .command
        exportItem.target = self
        menu.addItem(exportItem)

        let hooksItem = NSMenuItem(
            title: "Event Hooks...",
            action: #selector(openHooksFolder(_:)),
            keyEquivalent: ""
        )
        hooksItem.target = self
        menu.addItem(hooksItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(
            title: "About Dropout",
            action: #selector(showAbout(_:)),
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

            // Update menu bar icon
            let iconName: String
            switch state.signalQuality {
            case .excellent, .good:
                iconName = "wifi"
            case .fair:
                iconName = "wifi"
            case .weak:
                iconName = "wifi.exclamationmark"
            case .none:
                iconName = "wifi.slash"
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

    func updateRecentEvents(_ events: [WiFiEvent]) {
        // Remove old event items
        for item in recentEventItems {
            menu.removeItem(item)
        }
        recentEventItems.removeAll()

        // Find insertion point (after recent header)
        let headerIndex = menu.index(of: recentHeaderItem)
        guard headerIndex >= 0 else { return }
        var insertIndex = headerIndex + 1

        if events.isEmpty {
            let noEvents = NSMenuItem(title: "  No events yet", action: nil, keyEquivalent: "")
            noEvents.isEnabled = false
            noEvents.attributedTitle = NSAttributedString(
                string: "  No events yet",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            )
            menu.insertItem(noEvents, at: insertIndex)
            recentEventItems.append(noEvents)
        } else {
            for event in events.prefix(8) {
                let dot = event.isNegative ? "\u{25CF}" : "\u{25CB}"  // filled/hollow circle
                let title = "  \(event.timeString)  \(dot) \(event.displayString)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false

                let color: NSColor = event.isNegative ? .systemRed : .secondaryLabelColor
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                        .foregroundColor: color,
                    ]
                )

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

    @objc private func toggleAutoDisconnect(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        sender.state = enabled ? .on : .off
        UserDefaults.standard.set(enabled, forKey: "autoDisconnectDeadNetworks")
    }

    @objc private func disconnectAction(_ sender: NSMenuItem) {
        onDisconnect?()
    }

    @objc private func exportLog(_ sender: NSMenuItem) {
        onExportLog?()
    }

    @objc private func openHooksFolder(_ sender: NSMenuItem) {
        onOpenHooksFolder?()
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        onShowAbout?()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        onQuit?()
    }

    // MARK: - Login Item (SMAppService for macOS 13+)

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
