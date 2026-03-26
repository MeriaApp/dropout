import Foundation
import CoreWLAN

// MARK: - WiFi State

struct WiFiState {
    let ssid: String?
    let bssid: String?
    let rssi: Int
    let transmitRate: Double
    let isConnected: Bool
    let isPoweredOn: Bool

    var signalQuality: SignalQuality {
        SignalQuality.from(rssi: rssi)
    }

    static let disconnected = WiFiState(
        ssid: nil, bssid: nil, rssi: 0, transmitRate: 0,
        isConnected: false, isPoweredOn: true
    )
}

enum SignalQuality: String {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case weak = "Weak"
    case none = "No Signal"

    static func from(rssi: Int) -> SignalQuality {
        switch rssi {
        case _ where rssi >= -50: return .excellent
        case -65 ..< -50: return .good
        case -75 ..< -65: return .fair
        case _ where rssi < -75 && rssi > -100: return .weak
        default: return .none
        }
    }
}

// MARK: - WiFi Monitor

final class WiFiMonitor: NSObject {
    private let client = CWWiFiClient.shared()
    private var previousSSID: String?
    private var previousRSSI: Int = 0
    private var wasConnected = false
    private var disconnectTime: Date?

    private let signalWarningThreshold = -75  // dBm
    private let signalRecoveryThreshold = -65 // dBm — hysteresis to avoid flapping
    private var signalDegraded = false

    // Callbacks
    var onEvent: ((WiFiEvent) -> Void)?
    var onStateChanged: ((WiFiState) -> Void)?

    // MARK: - Lifecycle

    func start() {
        client.delegate = self

        let events: [CWEventType] = [
            .linkDidChange,
            .ssidDidChange,
            .bssidDidChange,
            .linkQualityDidChange,
            .powerDidChange,
        ]

        for event in events {
            do {
                try client.startMonitoringEvent(with: event)
            } catch {
                print("dropout: failed to monitor \(event): \(error)")
            }
        }

        // Capture initial state
        let state = currentState()
        wasConnected = state.isConnected
        previousSSID = state.ssid
        previousRSSI = state.rssi
        onStateChanged?(state)
    }

    func stop() {
        do {
            try client.stopMonitoringAllEvents()
        } catch {
            print("dropout: failed to stop monitoring: \(error)")
        }
    }

    func currentState() -> WiFiState {
        guard let iface = client.interface() else {
            return .disconnected
        }

        return WiFiState(
            ssid: iface.ssid(),
            bssid: iface.bssid(),
            rssi: iface.rssiValue(),
            transmitRate: iface.transmitRate(),
            isConnected: iface.ssid() != nil,
            isPoweredOn: iface.powerOn()
        )
    }

    /// Disconnect from the current network without removing it from saved networks.
    /// macOS will then auto-join the next preferred saved network.
    func disconnectFromCurrentNetwork() {
        guard let iface = client.interface() else { return }
        iface.disassociate()
    }

    /// Cycle the WiFi interface: disconnect, brief pause, then macOS reconnects
    /// to the best available saved network automatically.
    func cycleConnection() {
        guard let iface = client.interface() else { return }
        let ssid = iface.ssid()
        iface.disassociate()

        // macOS auto-reconnects to preferred networks after disassociate.
        // If it picks the same dead network, we'll catch it again via
        // the dead network detection flow.
        print("dropout: disconnected from \(ssid ?? "unknown") — waiting for auto-rejoin")
    }
}

// MARK: - CWEventDelegate

extension WiFiMonitor: CWEventDelegate {
    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        let state = currentState()
        let isConnected = state.isConnected

        if isConnected && !wasConnected {
            // Reconnected
            var details: String?
            if let disc = disconnectTime {
                let duration = Date().timeIntervalSince(disc)
                details = formatDuration(duration)
            }
            disconnectTime = nil

            let event = WiFiEvent(
                type: .connected,
                ssid: state.ssid,
                bssid: state.bssid,
                rssi: state.rssi,
                transmitRate: state.transmitRate,
                details: details
            )
            emit(event)
        } else if !isConnected && wasConnected {
            // Disconnected
            disconnectTime = Date()
            let event = WiFiEvent(
                type: .disconnected,
                ssid: previousSSID,
                bssid: state.bssid
            )
            emit(event)
        }

        wasConnected = isConnected
        previousSSID = state.ssid
        onStateChanged?(state)
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        let state = currentState()
        guard let newSSID = state.ssid else { return }

        // Only emit SSID change if we were already connected (not a fresh connect)
        if wasConnected, let oldSSID = previousSSID, oldSSID != newSSID {
            let event = WiFiEvent(
                type: .ssidChanged,
                ssid: newSSID,
                details: "from \(oldSSID)"
            )
            emit(event)
        }

        previousSSID = newSSID
        onStateChanged?(state)
    }

    func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        // BSSID changes (roaming) — update state silently
        let state = currentState()
        onStateChanged?(state)
    }

    func linkQualityDidChangeForWiFiInterface(
        withName interfaceName: String, rssi: Int, transmitRate: Double
    ) {
        let state = currentState()

        // Signal degradation warning (with hysteresis)
        if !signalDegraded && rssi <= signalWarningThreshold {
            signalDegraded = true
            let event = WiFiEvent(
                type: .signalDegraded,
                ssid: state.ssid,
                rssi: rssi,
                transmitRate: transmitRate
            )
            emit(event)
        } else if signalDegraded && rssi >= signalRecoveryThreshold {
            signalDegraded = false
            let event = WiFiEvent(
                type: .signalRecovered,
                ssid: state.ssid,
                rssi: rssi,
                transmitRate: transmitRate
            )
            emit(event)
        }

        previousRSSI = rssi
        onStateChanged?(state)
    }

    // MARK: - Helpers

    private func emit(_ event: WiFiEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s offline"
        } else if seconds < 3600 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return secs > 0 ? "\(mins)m \(secs)s offline" : "\(mins)m offline"
        } else {
            let hours = Int(seconds) / 3600
            let mins = (Int(seconds) % 3600) / 60
            return mins > 0 ? "\(hours)h \(mins)m offline" : "\(hours)h offline"
        }
    }
}

// Separate extension to silence "nearly matches" warning for modeDidChange
extension WiFiMonitor {
    func powerDidChangeForWiFiInterface(withName interfaceName: String) {
        let state = currentState()
        let event = WiFiEvent(
            type: state.isPoweredOn ? .powerOn : .powerOff
        )
        emit(event)
        onStateChanged?(state)
    }
}
