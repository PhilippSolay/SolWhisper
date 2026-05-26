#!/bin/bash
set -euo pipefail

# Deploy latest build to /Applications and launch.
#
# Handles all the gotchas we've hit:
#   - Sparkle.framework Team ID mismatch        → codesign --force --deep
#   - Quarantine flag on iCloud/Dropbox copies  → xattr -cr
#   - Stale Sparkle URL cache stops updates     → clear caches
#   - Stale TCC permission entry                → user-facing reminder
#
# Usage: ./scripts/deploy-local.sh [debug|release]

CONFIG="${1:-debug}"
CONFIG_CAP="$(echo "$CONFIG" | tr '[:lower:]' '[:upper:]' | cut -c1)$(echo "$CONFIG" | cut -c2-)"
APP_NAME="SolWhisper"
BUNDLE_ID="cloud.solay.SolWhisper"

# Pick the most recently modified candidate when multiple DerivedData
# directories exist (Xcode keeps stale ones around indefinitely; the
# default `find ... | head -1` picks an alphabetical first match which
# can deploy a build from months ago). `stat -f "%m %N"` prints epoch
# mtime + path; `sort -nr` puts the newest first.
APP=$(find ~/Library/Developer/Xcode/DerivedData/${APP_NAME}-*/Build/Products/"$CONFIG_CAP" -name "$APP_NAME.app" -maxdepth 1 2>/dev/null \
        | xargs -I{} stat -f "%m {}" 2>/dev/null \
        | sort -nr \
        | head -1 \
        | cut -d' ' -f2-)

if [ -z "$APP" ]; then
    echo "✗ No $CONFIG_CAP build found. Run xcodebuild first."
    exit 1
fi

VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")

echo "Deploying $CONFIG_CAP build $APP_NAME $VERSION ($BUILD)"
echo "  Source: $APP"

# 1. Quit running instance
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3

# 2. Replace
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" "/Applications/$APP_NAME.app"

# 3. Strip quarantine (in case Dropbox/iCloud added it)
xattr -cr "/Applications/$APP_NAME.app"

# 4. Re-sign deeply ad-hoc so Sparkle.framework Team ID matches the host's (nil)
#    Without this the app fails to launch:
#      Library not loaded: @rpath/Sparkle.framework ... different Team IDs
codesign --force --deep --sign - "/Applications/$APP_NAME.app"

# 5. Verify signature is consistent (early failure if not)
if ! codesign --verify --deep "/Applications/$APP_NAME.app" 2>/dev/null; then
    echo "✗ codesign verify failed"
    exit 1
fi

# 6. Clear Sparkle's URL cache so the next "Check for Updates" gets a fresh
#    appcast (we've hit the stale-cache issue when shipping back-to-back releases).
rm -rf "$HOME/Library/Caches/$BUNDLE_ID" 2>/dev/null || true

# 7. Launch
echo "  Launching $APP_NAME..."
open "/Applications/$APP_NAME.app"

# 8. TCC reminder — every CDHash change revokes Microphone, Speech Recognition,
#    Accessibility, and Automation permissions. Until we have a Developer ID,
#    this happens on every deploy.
cat <<'TIP'

  Note: TCC permissions reset on every build. If recording / paste fails:
    System Settings → Privacy & Security → Microphone        → toggle SolWhisper
    System Settings → Privacy & Security → Speech Recognition → toggle SolWhisper
    System Settings → Privacy & Security → Accessibility     → remove + re-add
    System Settings → Privacy & Security → Automation        → SolWhisper → System Events ✓
TIP
