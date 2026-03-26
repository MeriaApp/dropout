import Foundation

/// Runs user-configured scripts on WiFi events.
/// Scripts are stored in ~/Library/Application Support/SignalDrop/hooks/
/// Named by event type: on-disconnect.sh, on-connect.sh, on-signal-weak.sh, etc.
final class WebhookService {
    private let hooksDir: URL
    private let queue = DispatchQueue(label: "com.signaldrop.hooks", qos: .utility)

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        hooksDir = appSupport.appendingPathComponent("SignalDrop/hooks")
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        seedReadme()
    }

    func fire(event: WiFiEvent) {
        let scriptName = scriptName(for: event.type)
        let scriptURL = hooksDir.appendingPathComponent(scriptName)

        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else { return }

        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
            process.environment = [
                "SIGNALDROP_EVENT": event.type.rawValue,
                "SIGNALDROP_SSID": event.ssid ?? "",
                "SIGNALDROP_BSSID": event.bssid ?? "",
                "SIGNALDROP_RSSI": event.rssi.map(String.init) ?? "",
                "SIGNALDROP_DETAILS": event.details ?? "",
                "SIGNALDROP_TIMESTAMP": ISO8601DateFormatter().string(from: event.timestamp),
            ]

            // Redirect output to log
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            let logPath = appSupport.appendingPathComponent("SignalDrop/hooks.log")
            let logHandle = FileHandle(forWritingAtPath: logPath.path)
                ?? { FileManager.default.createFile(atPath: logPath.path, contents: nil); return FileHandle(forWritingAtPath: logPath.path)! }()
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError = logHandle

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                print("signaldrop: hook failed (\(scriptName)): \(error)")
            }
        }
    }

    private func scriptName(for type: WiFiEventType) -> String {
        switch type {
        case .disconnected: return "on-disconnect.sh"
        case .connected: return "on-connect.sh"
        case .ssidChanged: return "on-ssid-change.sh"
        case .signalDegraded: return "on-signal-weak.sh"
        case .signalRecovered: return "on-signal-recovered.sh"
        case .internetLost: return "on-internet-lost.sh"
        case .internetRestored: return "on-internet-restored.sh"
        case .powerOn: return "on-power-on.sh"
        case .powerOff: return "on-power-off.sh"
        }
    }

    /// Create a README in the hooks directory so users know what to do
    private func seedReadme() {
        let readme = hooksDir.appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: readme.path) else { return }

        let content = """
            Dropout Hooks
            =============

            Place executable shell scripts here to run on WiFi events.
            Scripts receive event data via environment variables.

            Available hooks:
              on-disconnect.sh      — WiFi disconnected
              on-connect.sh         — WiFi reconnected
              on-ssid-change.sh     — Switched to different network
              on-signal-weak.sh     — Signal dropped below -75 dBm
              on-signal-recovered.sh — Signal recovered above -65 dBm
              on-internet-lost.sh   — WiFi up but no internet
              on-internet-restored.sh — Internet back
              on-power-on.sh        — WiFi radio turned on
              on-power-off.sh       — WiFi radio turned off

            Environment variables passed to each script:
              SIGNALDROP_EVENT      — Event type (e.g., "disconnected")
              SIGNALDROP_SSID       — Network name (if available)
              SIGNALDROP_BSSID      — Access point MAC address
              SIGNALDROP_RSSI       — Signal strength in dBm
              SIGNALDROP_DETAILS    — Additional details
              SIGNALDROP_TIMESTAMP  — ISO 8601 timestamp

            Example (on-disconnect.sh):
              #!/bin/bash
              curl -X POST "https://hooks.slack.com/your/webhook" \\
                -d "{\\"text\\":\\"WiFi dropped from $SIGNALDROP_SSID\\"}"

            Make scripts executable: chmod +x on-disconnect.sh
            Hook output is logged to: ~/Library/Application Support/SignalDrop/hooks.log
            """
        try? content.write(to: readme, atomically: true, encoding: .utf8)
    }
}
