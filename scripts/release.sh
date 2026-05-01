#!/bin/bash
set -euo pipefail

# SolWhisper Release Script
# Usage: ./scripts/release.sh [version]
# Example: ./scripts/release.sh 0.2.0
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - Sparkle's generate_appcast or sign_update in PATH
#     (from DerivedData after building, or brew install sparkle)
#   - EdDSA key pair generated (run: ./scripts/generate-sparkle-keys.sh)

VERSION="${1:?Usage: $0 <version>}"
REPO="PhilippSolay/SolWhisper"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build-release"
APP_NAME="SolWhisper"
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
APPCAST="$PROJECT_DIR/appcast.xml"

echo "=== Building Release v${VERSION} ==="

# 1. Update version in Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PROJECT_DIR/Resources/Info.plist"
BUNDLE_VERSION=$(($(date +%s) / 100))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" "$PROJECT_DIR/Resources/Info.plist"

echo "Version: $VERSION (build $BUNDLE_VERSION)"

# 2. Build Release
echo "Building..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project "$PROJECT_DIR/SolWhisper.xcodeproj" \
    -scheme SolWhisper \
    -configuration Release \
    clean build \
    2>&1 | grep -E "(error:|BUILD)" | head -5

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/SolWhisper-*/Build/Products/Release -name "SolWhisper.app" -maxdepth 1 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
  echo "ERROR: Build product not found"
  exit 1
fi
echo "App: $APP_PATH"

# 3. Create DMG
echo "Creating DMG..."
STAGING="/tmp/SolWhisper-release-staging"
rm -rf "$STAGING" "$PROJECT_DIR/$DMG_NAME"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/$APP_NAME.app"

# CRITICAL: Re-sign the entire bundle ad-hoc so Sparkle.framework's Team ID
# matches the host app's Team ID (both nil). Without this, after auto-update
# the new app fails to launch with "different Team IDs" dyld error.
echo "Re-signing bundle ad-hoc (matches host signing)..."
codesign --force --deep --sign - "$STAGING/$APP_NAME.app"
codesign --verify --deep "$STAGING/$APP_NAME.app" || { echo "ERROR: signature verify failed"; exit 1; }

ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$PROJECT_DIR/$DMG_NAME"
rm -rf "$STAGING"

DMG_PATH="$PROJECT_DIR/$DMG_NAME"
DMG_SIZE=$(stat -f%z "$DMG_PATH")
echo "DMG: $DMG_PATH ($DMG_SIZE bytes)"

# 4. Sign the DMG for Sparkle (EdDSA)
echo "Signing DMG..."
SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/Sparkle*" 2>/dev/null | head -1)
if [ -z "$SIGN_TOOL" ]; then
  # Try homebrew
  SIGN_TOOL=$(which sign_update 2>/dev/null || true)
fi

SIGNATURE=""
if [ -n "$SIGN_TOOL" ]; then
  SIGNATURE=$("$SIGN_TOOL" "$DMG_PATH" 2>/dev/null || echo "")
  echo "Signature: $SIGNATURE"
else
  echo "WARNING: sign_update not found — appcast will lack signature"
  echo "  Build the project in Xcode first, then re-run this script"
fi

# 5. Generate appcast.xml
echo "Generating appcast.xml..."
DMG_URL="https://github.com/$REPO/releases/download/v${VERSION}/${DMG_NAME}"
PUB_DATE=$(date -R)

# Parse edSignature and length from sign_update output
ED_SIG=""
ED_LEN=""
if [ -n "$SIGNATURE" ]; then
  ED_SIG=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2 || true)
  ED_LEN=$(echo "$SIGNATURE" | grep -o 'length="[^"]*"' | cut -d'"' -f2 || true)
fi

cat > "$APPCAST" << APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>SolWhisper Updates</title>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="${DMG_URL}"
                 type="application/octet-stream"
                 ${ED_SIG:+sparkle:edSignature=\"$ED_SIG\"}
                 length="${ED_LEN:-$DMG_SIZE}" />
    </item>
  </channel>
</rss>
APPCAST_EOF

echo "Appcast written to $APPCAST"

# 6. Commit + push appcast
echo "Committing appcast..."
cd "$PROJECT_DIR"
git add appcast.xml Resources/Info.plist
git commit -m "Release v${VERSION}" || true
git push origin main

# 7. Create GitHub release
echo "Creating GitHub release v${VERSION}..."
gh release create "v${VERSION}" \
  --repo "$REPO" \
  --title "SolWhisper v${VERSION}" \
  --notes "SolWhisper v${VERSION}" \
  "$DMG_PATH"

echo ""
echo "=== Release v${VERSION} published ==="
echo "  GitHub: https://github.com/$REPO/releases/tag/v${VERSION}"
echo "  Appcast: https://raw.githubusercontent.com/$REPO/main/appcast.xml"
echo ""
echo "Users will see the update next time they check (or via Check for Updates)."
