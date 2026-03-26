import AppKit

final class DropoutApp: NSObject, NSApplicationDelegate {
    private let wifiMonitor = WiFiMonitor()
    private let networkMonitor = NetworkMonitor()
    private let notificationService = NotificationService()
    private let eventLog = EventLog()
    private let menuBar = MenuBarController()
    private let locationManager = LocationManager()
    private let webhookService = WebhookService()

    private var refreshTimer: Timer?
    private var deadNetworkTimer: Timer?
    private var deadNetworkSSID: String?

    // Dead network detection: how long to wait with no internet before cycling
    private let deadNetworkTimeout: TimeInterval = 15

    // Throttling: prevent notification spam during WiFi flapping
    private var lastNotificationTime: [WiFiEventType: Date] = [:]
    private let throttleIntervals: [WiFiEventType: TimeInterval] = [
        .disconnected: 5,       // Max one disconnect notification per 5s
        .connected: 5,          // Max one reconnect notification per 5s
        .signalDegraded: 30,    // Max one signal warning per 30s
        .signalRecovered: 30,
        .internetLost: 10,
        .internetRestored: 10,
        .ssidChanged: 5,
        .powerOn: 5,
        .powerOff: 5,
    ]

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerDefaults()

        // First launch: show welcome dialog BEFORE requesting permissions
        // This brings the app to the foreground (dock presence) so system
        // prompts for Location Services appear reliably
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if isFirstLaunch {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            showWelcome()
        }

        // Request location permission (required for SSID access on macOS 14+)
        // On first launch, the app has dock presence from the welcome dialog,
        // so the system Location Services prompt will appear in front
        locationManager.onAuthorizationChanged = { [weak self] authorized in
            if authorized {
                let state = self?.wifiMonitor.currentState()
                if let state { self?.menuBar.updateWiFiState(state) }
            }
        }
        locationManager.requestAuthorization()

        // Setup menu bar
        menuBar.setup()
        menuBar.onExportLog = { [weak self] in self?.exportLog() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onOpenHooksFolder = { [weak self] in self?.openHooksFolder() }
        menuBar.onShowAbout = { [weak self] in self?.showAbout() }
        menuBar.onDisconnect = { [weak self] in self?.disconnectFromDeadNetwork() }

        // Wire up WiFi monitor
        wifiMonitor.onEvent = { [weak self] event in self?.handleEvent(event) }
        wifiMonitor.onStateChanged = { [weak self] state in
            self?.menuBar.updateWiFiState(state)
        }

        // Wire up network monitor with dead network detection
        networkMonitor.onInternetStatusChanged = { [weak self] reachable in
            guard let self else { return }
            self.menuBar.updateInternetStatus(reachable: reachable)

            if !reachable {
                // Start dead network timer — if internet doesn't come back
                // within the timeout, auto-disconnect from this network
                let currentSSID = self.wifiMonitor.currentState().ssid
                self.deadNetworkSSID = currentSSID
                self.startDeadNetworkTimer()

                let event = WiFiEvent(type: .internetLost, ssid: currentSSID)
                self.handleEvent(event)
            } else {
                // Internet is back — cancel dead network timer
                self.cancelDeadNetworkTimer()

                let event = WiFiEvent(type: .internetRestored, ssid: self.wifiMonitor.currentState().ssid)
                self.handleEvent(event)
            }
        }

        // Start monitoring
        wifiMonitor.start()
        networkMonitor.start()

        // Initial UI state
        menuBar.updateInternetStatus(reachable: networkMonitor.isInternetReachable)
        refreshUI()

        // Periodic refresh (stats + recent events)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wifiMonitor.stop()
        networkMonitor.stop()
        refreshTimer?.invalidate()
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: WiFiEvent) {
        // Always log
        eventLog.log(event)

        // Always fire webhooks (user controls which hooks exist)
        webhookService.fire(event: event)

        // Throttle notifications
        guard shouldNotify(for: event.type) else {
            refreshUI()
            return
        }
        lastNotificationTime[event.type] = Date()

        let soundEnabled = UserDefaults.standard.bool(forKey: "soundEnabled")
        let signalWarningsEnabled = UserDefaults.standard.bool(forKey: "signalWarningsEnabled")

        switch event.type {
        case .disconnected:
            notificationService.send(
                title: "WiFi Disconnected",
                body: event.ssid.map { "Lost connection to \($0)" } ?? "WiFi connection lost",
                sound: soundEnabled,
                critical: true
            )

        case .connected:
            let body: String
            if let details = event.details {
                body = "Back on \(event.ssid ?? "WiFi") — \(details)"
            } else {
                body = "Connected to \(event.ssid ?? "WiFi")"
            }
            notificationService.send(title: "WiFi Connected", body: body, sound: soundEnabled)

        case .ssidChanged:
            let body: String
            if let details = event.details {
                body = "Now on \(event.ssid ?? "Unknown") (\(details))"
            } else {
                body = "Switched to \(event.ssid ?? "Unknown")"
            }
            notificationService.send(title: "Network Changed", body: body, sound: soundEnabled)

        case .signalDegraded:
            guard signalWarningsEnabled else { break }
            notificationService.send(
                title: "WiFi Signal Weak",
                body: "Signal at \(event.rssi ?? 0) dBm — connection may drop",
                sound: soundEnabled
            )

        case .signalRecovered:
            guard signalWarningsEnabled else { break }
            notificationService.send(
                title: "WiFi Signal Recovered",
                body: "Signal improved to \(event.rssi ?? 0) dBm",
                sound: false
            )

        case .internetLost:
            notificationService.send(
                title: "Internet Unreachable",
                body: "WiFi connected but no internet access",
                sound: soundEnabled
            )

        case .internetRestored:
            notificationService.send(
                title: "Internet Restored",
                body: "Back online",
                sound: false
            )

        case .powerOff:
            notificationService.send(
                title: "WiFi Turned Off",
                body: "WiFi radio has been disabled",
                sound: soundEnabled
            )

        case .powerOn:
            notificationService.send(
                title: "WiFi Turned On",
                body: "WiFi radio enabled — searching for networks",
                sound: false
            )
        }

        refreshUI()
    }

    private func shouldNotify(for type: WiFiEventType) -> Bool {
        guard let lastTime = lastNotificationTime[type],
              let interval = throttleIntervals[type] else {
            return true
        }
        return Date().timeIntervalSince(lastTime) >= interval
    }

    // MARK: - Dead Network Detection

    private func startDeadNetworkTimer() {
        cancelDeadNetworkTimer()
        let autoDisconnect = UserDefaults.standard.bool(forKey: "autoDisconnectDeadNetworks")
        guard autoDisconnect else { return }

        deadNetworkTimer = Timer.scheduledTimer(withTimeInterval: deadNetworkTimeout, repeats: false) { [weak self] _ in
            self?.handleDeadNetwork()
        }
    }

    private func cancelDeadNetworkTimer() {
        deadNetworkTimer?.invalidate()
        deadNetworkTimer = nil
        deadNetworkSSID = nil
    }

    private func handleDeadNetwork() {
        let state = wifiMonitor.currentState()
        guard state.isConnected, !networkMonitor.isInternetReachable else { return }

        let ssid = state.ssid ?? "current network"
        print("dropout: dead network detected (\(ssid)) — disconnecting to find a better network")

        // Disconnect — macOS will auto-join the next preferred saved network
        wifiMonitor.cycleConnection()

        notificationService.send(
            title: "Dead Network — Switching",
            body: "\(ssid) has no internet. Disconnected to find a better network.",
            sound: UserDefaults.standard.bool(forKey: "soundEnabled"),
            critical: false
        )

        deadNetworkSSID = nil
    }

    /// Manual disconnect triggered from menu bar
    private func disconnectFromDeadNetwork() {
        let state = wifiMonitor.currentState()
        let ssid = state.ssid ?? "current network"
        wifiMonitor.disconnectFromCurrentNetwork()

        notificationService.send(
            title: "Disconnected",
            body: "Left \(ssid) — macOS will join the next available network.",
            sound: false
        )
    }

    // MARK: - UI Refresh

    private func refreshUI() {
        let events = eventLog.recentEvents(limit: 8)
        menuBar.updateRecentEvents(events)

        let stats = eventLog.todayStats()
        menuBar.updateStats(disconnects: stats.disconnects, downtime: stats.totalDowntime)
    }

    // MARK: - Export

    private func exportLog() {
        let csv = eventLog.exportCSV()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "dropout-log.csv"
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Hooks Folder

    private func openHooksFolder() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let hooksDir = appSupport.appendingPathComponent("Dropout/hooks")
        NSWorkspace.shared.open(hooksDir)
    }

    // MARK: - About

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Dropout"
        alert.informativeText = """
            Version 1.0.0

            Event-driven WiFi disconnect notifier for macOS.
            Uses CoreWLAN — zero polling, zero battery impact.

            © 2026 Jesse Meria
            MIT License

            github.com/jessemeria/dropout
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        // Bring app to front for the alert
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Welcome

    private func showWelcome() {
        let alert = NSAlert()
        alert.messageText = "Welcome to Dropout"
        alert.informativeText = """
            Dropout monitors your WiFi and notifies you the instant \
            your connection drops — something macOS should do but doesn't.

            You'll be asked to grant two permissions:

            • Notifications — so Dropout can alert you
            • Location — required by macOS to read WiFi network names \
            (your location is never stored or sent anywhere)

            Look for the WiFi icon in your menu bar.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Get Started")

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Defaults

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "soundEnabled": true,
            "signalWarningsEnabled": true,
            "autoDisconnectDeadNetworks": true,
        ])
    }
}
