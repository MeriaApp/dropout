# Changelog

## 1.0.0 — 2026-03-26

Initial release.

- Event-driven WiFi monitoring via CoreWLAN (zero polling)
- Instant disconnect/reconnect notifications with downtime duration
- Signal degradation warnings (-75 dBm threshold with hysteresis)
- SSID change detection
- Dead network auto-disconnect (leaves without forgetting the network)
- "Connected but no internet" detection via NWPathMonitor
- Manual disconnect from menu bar (Cmd+D)
- Notification throttling to prevent spam during WiFi flapping
- Event hooks — run custom scripts on any WiFi event
- SQLite event log with CSV export
- Menu bar status icon with daily stats
- Location Services support for SSID access on macOS 14+
- Developer ID signed and notarized by Apple
- Launch at login via SMAppService
