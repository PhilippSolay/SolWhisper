#!/bin/bash
set -euo pipefail

# Deploy latest build to /Applications and launch
# Usage: ./scripts/deploy-local.sh [debug|release]

CONFIG="${1:-debug}"
CONFIG_CAP="$(echo "$CONFIG" | sed 's/./\U&/')"

APP=$(find ~/Library/Developer/Xcode/DerivedData/SolWhisper-*/Build/Products/"$CONFIG_CAP" -name "SolWhisper.app" -maxdepth 1 2>/dev/null | head -1)

if [ -z "$APP" ]; then
    echo "ERROR: No $CONFIG_CAP build found. Run xcodebuild first."
    exit 1
fi

echo "Deploying $CONFIG_CAP build..."
echo "  Version: $(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
echo "  Build:   $(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"

pkill -x SolWhisper 2>/dev/null || true
sleep 0.3

rm -rf /Applications/SolWhisper.app
cp -R "$APP" /Applications/SolWhisper.app

# Re-sign to fix Sparkle framework Team ID mismatch
codesign --force --deep --sign - /Applications/SolWhisper.app

echo "Deployed and signed. Launching..."
open /Applications/SolWhisper.app
