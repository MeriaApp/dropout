# Contributing to SignalDrop

SignalDrop is open source and contributions are welcome.

## Getting Started

```bash
git clone https://github.com/MeriaApp/signaldrop.git
cd signaldrop
swift build
```

Requires macOS 13+ and Swift 5.9+. No external dependencies.

## Development

The project uses Swift Package Manager. No Xcode project needed — `swift build` compiles everything.

```bash
swift build              # Debug build
swift build -c release   # Release build
.build/debug/signaldrop     # Run debug build
```

## Project Structure

| File | Purpose |
|------|---------|
| `main.swift` | App entry point, NSApplication setup |
| `SignalDropApp.swift` | App delegate, coordinates all components |
| `WiFiMonitor.swift` | CoreWLAN event-driven WiFi monitoring |
| `NetworkMonitor.swift` | NWPathMonitor for internet reachability |
| `NotificationService.swift` | macOS notification delivery |
| `MenuBarController.swift` | Menu bar icon and dropdown |
| `EventLog.swift` | SQLite event storage |
| `WebhookService.swift` | Event hook script execution |
| `LocationManager.swift` | CoreLocation for SSID access |
| `WiFiEvent.swift` | Event model |

## Pull Requests

- Keep changes focused — one feature or fix per PR
- Test on your Mac before submitting
- Match the existing code style (no linter configured, just be consistent)
- Update the README if you add user-facing features

## Reporting Bugs

Use the [bug report template](https://github.com/MeriaApp/signaldrop/issues/new?template=bug_report.md). Include your macOS version and an event log export if relevant.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
