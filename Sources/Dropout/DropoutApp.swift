import AppKit

final class DropoutApp: NSObject, NSApplicationDelegate {
    private let wifiMonitor = WiFiMonitor()
    private let networkMonitor = NetworkMonitor()
    private let notificationService = NotificationService()
    private let eventLog = EventLog()
    private let menuBar = MenuBarController()
    private let locationManager = LocationManager()
    private lazy var connectionQuality = ConnectionQuality(eventLog: eventLog)
    private lazy var ispReport = ISPReport(eventLog: eventLog, connectionQuality: connectionQuality)

    #if !APPSTORE
    private let webhookService = WebhookService()
    #endif

    private var refreshTimer: Timer?

    #if !APPSTORE
    private var deadNetworkTimer: Timer?
    private var deadNetworkSSID: String?
    private let deadNetworkTimeout: TimeInterval = 15
    #endif

    // Throttling: prevent notification spam during WiFi flapping
    private var lastNotificationTime: [WiFiEventType: Date] = [:]
    private let throttleIntervals: [WiFiEventType: TimeInterval] = [
        .disconnected: 5,
        .connected: 5,
        .signalDegraded: 30,
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

        // First launch onboarding
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if isFirstLaunch {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            showWelcome()
        }

        // Location Services (required for SSID on macOS 14+)
        locationManager.onAuthorizationChanged = { [weak self] authorized in
            if authorized {
                let state = self?.wifiMonitor.currentState()
                if let state { self?.menuBar.updateWiFiState(state) }
            }
        }
        locationManager.requestAuthorization()

        // Menu bar
        menuBar.setup()
        menuBar.onExportLog = { [weak self] in self?.exportLog() }
        menuBar.onExportReport = { [weak self] in self?.ispReport.saveReport() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onShowAbout = { [weak self] in self?.showAbout() }

        #if !APPSTORE
        menuBar.onOpenHooksFolder = { [weak self] in self?.openHooksFolder() }
        menuBar.onDisconnect = { [weak self] in self?.disconnectFromDeadNetwork() }
        #else
        menuBar.onOpenWiFiSettings = { self.openWiFiSettings() }
        #endif

        // WiFi monitor
        wifiMonitor.onEvent = { [weak self] event in self?.handleEvent(event) }
        wifiMonitor.onStateChanged = { [weak self] state in
            self?.menuBar.updateWiFiState(state)
        }

        // Network monitor
        networkMonitor.onInternetStatusChanged = { [weak self] reachable in
            guard let self else { return }
            self.menuBar.updateInternetStatus(reachable: reachable)

            if !reachable {
                let currentSSID = self.wifiMonitor.currentState().ssid

                #if !APPSTORE
                self.deadNetworkSSID = currentSSID
                self.startDeadNetworkTimer()
                #endif

                let event = WiFiEvent(type: .internetLost, ssid: currentSSID)
                self.handleEvent(event)
            } else {
                #if !APPSTORE
                self.cancelDeadNetworkTimer()
                #endif

                let event = WiFiEvent(type: .internetRestored, ssid: self.wifiMonitor.currentState().ssid)
                self.handleEvent(event)
            }
        }

        // Start
        wifiMonitor.start()
        networkMonitor.start()

        // Initial state
        menuBar.updateInternetStatus(reachable: networkMonitor.isInternetReachable)
        refreshUI()

        // Periodic refresh (30s for stats, events, and connection quality)
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
        eventLog.log(event)

        #if !APPSTORE
        webhookService.fire(event: event)
        #endif

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

    // MARK: - Dead Network (Direct distribution only)

    #if !APPSTORE
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
        wifiMonitor.cycleConnection()

        notificationService.send(
            title: "Dead Network — Switching",
            body: "\(ssid) has no internet. Disconnected to find a better network.",
            sound: UserDefaults.standard.bool(forKey: "soundEnabled"),
            critical: false
        )
        deadNetworkSSID = nil
    }

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

    private func openHooksFolder() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let hooksDir = appSupport.appendingPathComponent("Dropout/hooks")
        NSWorkspace.shared.open(hooksDir)
    }
    #endif

    // MARK: - WiFi Settings (App Store builds — can't auto-disconnect, open settings instead)

    private func openWiFiSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.network?Wi-Fi") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - UI Refresh

    private func refreshUI() {
        let events = eventLog.recentEvents(limit: 8)
        menuBar.updateRecentEvents(events)

        let stats = eventLog.todayStats()
        menuBar.updateStats(disconnects: stats.disconnects, downtime: stats.totalDowntime)

        // Connection quality grade
        let report = connectionQuality.currentReport()
        menuBar.updateConnectionQuality(report)

        // Network reliability for known networks
        let networks = eventLog.knownNetworks()
        var reliability: [(ssid: String, uptime: Double, disconnects: Int)] = []
        for ssid in networks.prefix(5) {
            let stats = connectionQuality.networkReliability(ssid: ssid)
            reliability.append((ssid: ssid, uptime: stats.uptime, disconnects: stats.disconnects))
        }
        menuBar.updateNetworkReliability(reliability)
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

    // MARK: - About

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Dropout"
        alert.informativeText = """
            Version 1.0.0

            Event-driven WiFi disconnect notifier for macOS.
            Uses CoreWLAN — zero polling, zero battery impact.

            \u{00A9} 2026 Jesse Meria
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

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

            \u{2022} Notifications — so Dropout can alert you
            \u{2022} Location — required by macOS to read WiFi network names \
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
