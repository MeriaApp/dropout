#!/bin/bash
set -euo pipefail

# Configuration
APP_NAME="Dropout"
BUNDLE_ID="com.meria.dropout"
VERSION="1.0.0"
BUILD_NUMBER="1"
DEVELOPER_ID="Developer ID Application: JESSE ROBERT MERIA (36D97ZTP6J)"
TEAM_ID="36D97ZTP6J"
ENTITLEMENTS="App/Dropout-DirectDistribution.entitlements"

# Paths
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$PROJECT_ROOT"

echo "=== Building $APP_NAME v$VERSION ==="
echo ""

# Step 1: Clean and build
echo "[1/6] Building binary..."
swift build -c release 2>&1
BINARY=".build/release/dropout"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Build failed — binary not found."
    exit 1
fi
echo "  Binary: $(du -h "$BINARY" | cut -f1) — $(file "$BINARY" | grep -o 'arm64\|x86_64' | tr '\n' '+')"

# Step 2: Generate icon (if script exists and icon doesn't)
ICON_PATH="Resources/AppIcon.icns"
if [ ! -f "$ICON_PATH" ] && [ -f "Scripts/generate-icon.swift" ]; then
    echo "[2/6] Generating app icon..."
    swift Scripts/generate-icon.swift 2>&1
    if [ ! -f "$ICON_PATH" ]; then
        echo "  WARNING: Icon generation failed. Building without icon."
    else
        echo "  Icon: $ICON_PATH"
    fi
else
    echo "[2/6] App icon: $([ -f "$ICON_PATH" ] && echo "found" || echo "not found (skipping)")"
fi

# Step 3: Create .app bundle
echo "[3/6] Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"

# Copy binary
cp "$BINARY" "$MACOS/dropout"
chmod +x "$MACOS/dropout"

# Copy Info.plist with version injection
sed -e "s/<string>1.0.0</<string>$VERSION</" \
    -e "s/<string>1<\/string>/<string>$BUILD_NUMBER<\/string>/" \
    "App/Info.plist" > "$CONTENTS/Info.plist"

# Copy icon if it exists
if [ -f "$ICON_PATH" ]; then
    cp "$ICON_PATH" "$RESOURCES/AppIcon.icns"
fi

echo "  Bundle: $APP_BUNDLE"

# Step 4: Code sign with Developer ID + hardened runtime
echo "[4/6] Code signing with Developer ID..."
codesign --force --deep --options runtime \
    --sign "$DEVELOPER_ID" \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_BUNDLE" 2>&1

# Verify signature
codesign --verify --verbose "$APP_BUNDLE" 2>&1
echo "  Signed and verified."

# Step 5: Notarize
echo "[5/6] Notarizing..."
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-notarytool}"

# Create zip for notarization
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait 2>&1; then
    echo "  Notarization succeeded."

    # Step 6: Staple
    echo "[6/6] Stapling notarization ticket..."
    xcrun stapler staple "$APP_BUNDLE" 2>&1
    echo "  Stapled."
else
    echo ""
    echo "  WARNING: Notarization failed or credentials not configured."
    echo "  The app is signed but not notarized."
    echo ""
    echo "  To set up notarization credentials:"
    echo "    xcrun notarytool store-credentials notarytool \\"
    echo "      --apple-id YOUR_APPLE_ID \\"
    echo "      --team-id $TEAM_ID \\"
    echo "      --password YOUR_APP_SPECIFIC_PASSWORD"
    echo ""
    echo "  Then re-run this script."
fi

# Cleanup
rm -f "$ZIP_PATH"

echo ""
echo "=== Build complete ==="
echo "  App:     $APP_BUNDLE"
echo "  Size:    $(du -sh "$APP_BUNDLE" | cut -f1)"
echo ""
echo "Next steps:"
echo "  • Test: open \"$APP_BUNDLE\""
echo "  • Package: ./Scripts/package-dmg.sh"
echo "  • Install: cp -R \"$APP_BUNDLE\" /Applications/"
