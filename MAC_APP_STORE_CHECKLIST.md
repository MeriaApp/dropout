# SignalDrop -- Mac App Store Submission Checklist

Research date: March 2026. Based on current Apple requirements and developer experience.

---

## CRITICAL BLOCKERS (Read First)

Before doing anything else, understand that SignalDrop has three features that **will not work in the Mac App Store sandbox**:

| Feature | Why It Breaks | Fix |
|---------|---------------|-----|
| `CWInterface.disassociate()` | Sandbox prohibits modifying network configuration | Remove or disable. Read-only WiFi monitoring is allowed. |
| `WebhookService` (Process/bash) | Sandbox prohibits launching arbitrary processes | Replace with `NSUserUnixTask` using `~/Library/Application Scripts/com.meria.dropout/` directory, or remove entirely |
| `com.apple.security.automation.apple-events` | Scrutinized heavily by App Review; current code doesn't appear to use it | Remove from entitlements |

**CoreWLAN reading (SSID, RSSI, BSSID, event monitoring) DOES work in sandbox.** Multiple WiFi monitoring apps are live on the Mac App Store (WiFi Signal, Wifiry, NetSpot). Since WWDC 2018, CoreWLAN was officially allowed in the sandbox for read operations via `CWWiFiClient.shared().interface()`.

---

## Phase 1: Code Changes for Sandbox Compatibility

### 1.1 Remove Network Modification APIs

**Files:** `WiFiMonitor.swift:113-129`

```swift
// REMOVE or #if DEBUG-gate these methods:
func disconnectFromCurrentNetwork()  // calls disassociate()
func cycleConnection()               // calls disassociate()
```

**File:** `SignalDropApp.swift:235-266`
- Remove `disconnectFromDeadNetwork()`
- Remove or rework `handleDeadNetwork()` to only notify (no auto-disconnect)
- Remove `menuBar.onDisconnect` wiring

**File:** `MenuBarController.swift:53-61`
- Remove or hide the "Disconnect from This Network" menu item

### 1.2 Fix WebhookService for Sandbox

**File:** `WebhookService.swift`

Option A (recommended for v1): **Remove WebhookService entirely.** Ship without hooks for the Mac App Store version. Keep it for the direct-download/Homebrew version via `#if APPSTORE` compilation flag.

Option B: Replace `Process()` with `NSUserUnixTask`. Scripts must live in `~/Library/Application Scripts/com.meria.dropout/`. The app can read from but NOT write to this directory. The user must place scripts there manually or via Finder.

**Important:** App Review scrutinizes `NSUserUnixTask` usage heavily. They want it used as a genuine user-facing scripting feature, not as a sandbox escape.

### 1.3 Fix Entitlements

**File:** `App/SignalDrop.entitlements` -- replace contents with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- REQUIRED: App Sandbox (mandatory for Mac App Store) -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- Location: required for SSID/BSSID access on macOS 14+ -->
    <key>com.apple.security.personal-information.location</key>
    <true/>

    <!-- Network client: required for NWPathMonitor internet reachability checks -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- File access: read/write to app's container (for SQLite event log) -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

**Entitlements explained:**
- `com.apple.security.app-sandbox` -- mandatory for all Mac App Store apps (since 2012)
- `com.apple.security.personal-information.location` -- you already have this; needed for SSID/BSSID
- `com.apple.security.network.client` -- NWPathMonitor needs outgoing network access to check reachability
- `com.apple.security.files.user-selected.read-write` -- for the CSV export via NSSavePanel (user-selected file access)

**Entitlements NOT needed:**
- `com.apple.developer.networking.wifi-info` -- this is an iOS entitlement for `CNCopyCurrentNetworkInfo`. Not used on macOS. CoreWLAN on macOS uses Location Services instead.
- `com.apple.wifi.events` -- this is a private/system entitlement. Despite forum posts mentioning it, you do NOT request it. CoreWLAN event monitoring works without it in modern macOS when using `CWWiFiClient.shared()`.
- `com.apple.security.automation.apple-events` -- remove. Your code doesn't use AppleEvents.

### 1.4 Update Info.plist

**File:** `App/Info.plist` -- add these keys:

```xml
<!-- Privacy manifest requirement (macOS 14+) -->
<key>NSPrivacyTracking</key>
<false/>
<key>NSPrivacyTrackingDomains</key>
<array/>
<key>NSPrivacyCollectedDataTypes</key>
<array/>
<key>NSPrivacyAccessedAPITypes</key>
<array>
    <!-- UserDefaults -->
    <dict>
        <key>NSPrivacyAccessedAPIType</key>
        <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
        <key>NSPrivacyAccessedAPITypeReasons</key>
        <array>
            <string>CA92.1</string>
        </array>
    </dict>
</array>
```

Also change the copyright line (MIT License is fine for open source but unusual for a paid app):
```xml
<key>NSHumanReadableCopyright</key>
<string>Copyright 2026 Jesse Meria. All rights reserved.</string>
```

### 1.5 Verify Minimum Deployment Target

Current: macOS 13 (Ventura). This is fine. Apple has not announced a macOS minimum SDK version requirement for Mac App Store in 2026 the way they have for iOS. Build with the latest Xcode (currently 16.x) and the macOS 15 SDK. Your deployment target of 13.0 can stay.

---

## Phase 2: Create Xcode Project

**You cannot submit an SPM-only project to the Mac App Store.** The `swift build` toolchain does not produce a properly signed, sandboxed, archivable bundle. You need an Xcode project.

### 2.1 Generate Xcode Project

Option A (recommended): Create a new Xcode project from scratch.

```
Xcode > File > New > Project > macOS > App
- Product Name: SignalDrop
- Team: JESSE ROBERT MERIA (36D97ZTP6J)
- Organization Identifier: com.meria
- Bundle Identifier: com.meria.dropout
- Interface: AppKit (not SwiftUI -- your code uses NSApplication directly)
- Language: Swift
- Uncheck: Include Tests, Core Data, CloudKit
```

Then:
1. Delete the auto-generated template files (AppDelegate.swift, main.swift from template, etc.)
2. Add all files from `Sources/SignalDrop/` to the Xcode target
3. Add framework dependencies: CoreWLAN, CoreLocation, Network, ServiceManagement, SystemConfiguration
4. Copy your existing `App/Info.plist` values into the Xcode-managed Info.plist
5. Copy your entitlements into the Xcode-managed entitlements file
6. Set `LSUIElement = YES` in Info.plist (Xcode: "Application is agent (UIElement)" = YES)

Option B: Generate from SPM with `swift package generate-xcodeproj` (deprecated but works). You'll still need to manually configure signing, entitlements, and capabilities.

### 2.2 Configure Signing & Capabilities in Xcode

1. Select the SignalDrop target > Signing & Capabilities
2. Team: **JESSE ROBERT MERIA (36D97ZTP6J)**
3. Signing Certificate: **Apple Distribution: JESSE ROBERT MERIA (36D97ZTP6J)** (you have this)
4. Enable **App Sandbox** capability -- this adds the sandbox entitlement
5. Under App Sandbox, check:
   - Outgoing Connections (Client) -- adds `com.apple.security.network.client`
   - Location -- adds `com.apple.security.personal-information.location`
   - User Selected File (Read/Write) -- for CSV export
6. Enable **Hardened Runtime** (already required for notarization, also required for MAS)

### 2.3 Build & Test in Sandbox

```bash
# Build for release
xcodebuild -project SignalDrop.xcodeproj -scheme SignalDrop -configuration Release build

# Run the sandboxed app and verify:
# - WiFi SSID appears in menu bar (requires Location permission)
# - RSSI updates work
# - Event monitoring fires on connect/disconnect
# - NWPathMonitor detects internet status changes
# - SQLite database writes to ~/Library/Containers/com.meria.dropout/
# - CSV export works via NSSavePanel
# - Launch at Login works (SMAppService)
# - UserDefaults persist correctly
```

**Important sandbox behavior change:** With sandbox enabled, `~/Library/Application Support/SignalDrop/` moves to `~/Library/Containers/com.meria.dropout/Data/Library/Application Support/SignalDrop/`. The code uses `FileManager.default.urls(for:in:)` which handles this automatically.

---

## Phase 3: App Store Connect Setup

### 3.1 Register App ID

1. Go to https://developer.apple.com/account/resources/identifiers
2. Click "+" to register a new App ID
3. Select "App IDs" > "App"
4. Description: "SignalDrop"
5. Bundle ID: Explicit > `com.meria.dropout`
6. Capabilities: check only what you need (no special capabilities needed beyond defaults)
7. Register

### 3.2 Create Provisioning Profile

1. Go to https://developer.apple.com/account/resources/profiles
2. Click "+" > Mac App Store
3. Select App ID: `com.meria.dropout`
4. Select Certificate: **Apple Distribution: JESSE ROBERT MERIA (36D97ZTP6J)**
5. Name it: "SignalDrop Mac App Store"
6. Download and double-click to install

**Note:** If you use Automatic Signing in Xcode (recommended), Xcode manages provisioning profiles automatically.

### 3.3 Create App in App Store Connect

1. Go to https://appstoreconnect.apple.com
2. My Apps > "+" > New App
3. Platform: **macOS**
4. Name: **SignalDrop**
5. Primary Language: English (U.S.)
6. Bundle ID: com.meria.dropout
7. SKU: `dropout-mac` (any unique string)
8. User Access: Full Access

### 3.4 Set Price

For a one-time paid app at $3.99:

1. In App Store Connect > SignalDrop > Pricing and Availability
2. Price Schedule > Add Base Price
3. Base country: United States
4. Price: $3.99 (Price Tier -- select from the ~800 price points; $3.99 is available)
5. Apple auto-generates equivalent prices for 174 other storefronts
6. No IAP needed. A paid upfront app with no in-app purchases is the simplest model.

**Apple takes 30% (or 15% if you qualify for the Small Business Program -- under $1M annual revenue).** You keep ~$2.79 per sale at the standard rate, or ~$3.39 with Small Business.

### 3.5 Tax & Banking

1. App Store Connect > Agreements, Tax, and Banking
2. Accept the **Paid Apps Agreement** (required to sell paid apps)
3. Add bank account information
4. Fill out tax forms (W-9 for US individuals)
5. This must be completed before your app can go on sale

---

## Phase 4: App Store Listing

### 4.1 Screenshots

Required: at least one screenshot. Recommended: 3-5 showing key features.

- Show the menu bar dropdown with WiFi status
- Show a notification alert
- Show the event log / recent events

**Accepted sizes for Mac App Store:**
- 1280x800, 1440x900, 2560x1600, or 2880x1800 pixels

### 4.2 App Description

Write compelling copy. Key points:
- What it does (instant WiFi disconnect notifications)
- Why macOS needs it (macOS doesn't notify you when WiFi drops)
- Zero polling, event-driven, zero battery impact
- Privacy-first (no data collected, location used only for SSID display)

### 4.3 Keywords

100 characters max, comma-separated. Examples:
`wifi,disconnect,network,monitor,signal,notification,menu bar,strength,wireless,connectivity`

### 4.4 Privacy Policy URL

**Required for all apps**, even apps that collect no data.

Host a simple privacy policy page. It should state:
- SignalDrop does not collect, store, or transmit any personal data
- WiFi event data is stored locally on your Mac only
- Location permission is used solely to display your WiFi network name (Apple requires this for SSID access)
- No analytics, no tracking, no third-party services
- Contact email for privacy questions

Host at: `https://jessemeria.com/signaldrop/privacy` or similar.

### 4.5 Privacy Nutrition Labels

In App Store Connect > App Privacy:
1. Click "Get Started"
2. "Do you or your third-party partners collect data from this app?" > **No**
3. Save

This gives the app the "Data Not Collected" label.

### 4.6 App Category

`public.app-category.utilities` -- already set in Info.plist.

### 4.7 Support URL

Required. Can be the GitHub repo URL or a page on your website.

---

## Phase 5: Archive & Upload

### 5.1 Create Archive

In Xcode:
```
Product > Archive
```

Or via command line:
```bash
xcodebuild -project SignalDrop.xcodeproj \
  -scheme SignalDrop \
  -configuration Release \
  -archivePath ~/Desktop/SignalDrop.xcarchive \
  archive
```

### 5.2 Upload to App Store Connect

**Option A: Xcode Organizer (recommended for first submission)**
1. Window > Organizer
2. Select the archive
3. Click "Distribute App"
4. Select "App Store Connect"
5. Select "Upload"
6. Xcode validates, signs with your Apple Distribution certificate, and uploads

**Option B: Command line**
```bash
# Create ExportOptions.plist
cat > /tmp/ExportOptions.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>36D97ZTP6J</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF

# Export
xcodebuild -exportArchive \
  -archivePath ~/Desktop/SignalDrop.xcarchive \
  -exportPath ~/Desktop/SignalDropExport \
  -exportOptionsPlist /tmp/ExportOptions.plist

# Upload (xcrun altool or Transporter app)
xcrun altool --upload-app \
  -f ~/Desktop/SignalDropExport/SignalDrop.pkg \
  -t macos \
  -u YOUR_APPLE_ID \
  -p YOUR_APP_SPECIFIC_PASSWORD
```

### 5.3 Submit for Review

1. In App Store Connect, select the uploaded build
2. Fill in "What's New" (for v1.0: leave blank or write initial release notes)
3. Answer the export compliance question (SignalDrop uses no encryption beyond standard HTTPS = select "No")
4. Click "Submit for Review"

---

## Phase 6: App Review

### 6.1 Expected Timeline

- **Mac App Store reviews currently take 5-10 days** (as of early 2026, notably slower than iOS)
- First submissions often take longer and receive more scrutiny
- Expedited review is available for urgent cases

### 6.2 Common Rejection Risks for SignalDrop

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| **Sandbox violation** from `disassociate()` or `Process()` | HIGH if not removed | Remove all network modification and process launching code |
| **Insufficient functionality** (menu bar apps sometimes flagged) | MEDIUM | Ensure the menu shows rich status, event history, stats, preferences |
| **Missing privacy explanation** for Location | LOW | Already have `NSLocationUsageDescription` in Info.plist |
| **Guideline 2.4.5** -- menu bar apps must have a way to quit | LOW | Already have Quit menu item |
| **Guideline 4.0** -- Design: app must feel complete | LOW | App is polished and functional |

### 6.3 Rejection Response

If rejected, Apple gives specific reasons. You can:
1. Fix the issue and resubmit
2. Reply in the Resolution Center to clarify/appeal
3. Request a phone call with App Review

---

## Phase 7: Ongoing

### 7.1 Dual Distribution Strategy

Maintain two distribution channels:
- **Mac App Store** -- sandboxed, no hooks, no auto-disconnect (paid, discoverable)
- **Direct download** (current DMG) -- full features, Developer ID signed + notarized (free/donation)

Use a compilation flag to gate features:
```swift
#if APPSTORE
// Sandboxed: no disassociate, no webhook hooks
#else
// Direct: full feature set
#endif
```

### 7.2 Updates

- Updates go through the same Archive > Upload > Submit flow
- Update reviews are typically faster (1-3 days)
- Increment `CFBundleVersion` for every upload
- Increment `CFBundleShortVersionString` for user-visible versions

---

## Quick Reference: Certificates

| Certificate | Use |
|-------------|-----|
| Apple Distribution: JESSE ROBERT MERIA (36D97ZTP6J) | Mac App Store signing |
| Developer ID Application: JESSE ROBERT MERIA (36D97ZTP6J) | Direct download (notarized DMG) |
| Apple Development: JESSE ROBERT MERIA (6KQW73VUKS) | Development/testing |

You need the **Apple Distribution** certificate for Mac App Store. You already have it.

---

## Checklist Summary

- [ ] Remove `disassociate()` / `cycleConnection()` / `disconnectFromCurrentNetwork()`
- [ ] Remove or sandbox-proof `WebhookService` (recommend: remove for MAS version)
- [ ] Update entitlements (add sandbox, network.client; remove automation.apple-events)
- [ ] Add Privacy Manifest keys to Info.plist
- [ ] Create Xcode project with proper signing
- [ ] Test in sandbox (Location, CoreWLAN reads, NWPathMonitor, SQLite, NSSavePanel, SMAppService)
- [ ] Register App ID on developer portal
- [ ] Create app listing in App Store Connect
- [ ] Set price ($3.99)
- [ ] Complete Paid Apps Agreement + tax/banking
- [ ] Write and host privacy policy
- [ ] Fill out privacy nutrition labels ("Data Not Collected")
- [ ] Take screenshots (at least 1, recommend 3-5)
- [ ] Write app description and keywords
- [ ] Archive and upload via Xcode
- [ ] Submit for review
- [ ] Wait 5-10 days

---

Sources:
- [CWWiFiClient Documentation](https://developer.apple.com/documentation/corewlan/cwwificlient)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [App Sandbox Documentation](https://developer.apple.com/documentation/security/app-sandbox)
- [Access Wi-Fi Information Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.wifi-info)
- [startMonitoringEvent(with:)](https://developer.apple.com/documentation/corewlan/cwwificlient/startmonitoringevent(with:))
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [Set a Price - App Store Connect](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price/)
- [Upload Builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/)
- [SDK Minimum Requirements](https://developer.apple.com/news/upcoming-requirements/?id=02212025a)
- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Scripting from a Sandbox (objc.io)](https://www.objc.io/issues/14-mac/sandbox-scripting/)
- [NSUserUnixTask Documentation](https://developer.apple.com/documentation/foundation/nsuserunixtask)
- [WiFi Signal: Strength Analyzer (Mac App Store proof)](https://apps.apple.com/us/app/wifi-signal-strength-analyzer/id525912054?mt=12)
- [WiFi Signal Strength: Wifiry (Mac App Store proof)](https://apps.apple.com/us/app/wifi-signal-strength-wifiry/id1177934624?mt=12)
- [Manage App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [CoreWLAN Sandbox Forum Discussion](https://developer.apple.com/forums/thread/11307)
- [com.apple.wifi.events Forum Discussion](https://developer.apple.com/forums/thread/44807)
- [Mac App Store Review Times Increasing (2026)](https://mjtsai.com/blog/2026/03/02/mac-app-store-review-times-increasing/)
