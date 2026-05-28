#!/bin/bash
set -euo pipefail

# SolWhisper — shareable beta DMG builder
#
# Produces a standalone, polished DMG you can hand to beta testers over
# AirDrop / Dropbox / email — no GitHub, git, or Sparkle involved.
#
# The DMG presents a single "Install SolWhisper" helper. Double-clicking it
# copies the app to /Applications, strips the Gatekeeper quarantine flag,
# re-signs ad-hoc, and launches it. Because there's no Apple Developer ID,
# testers approve the *installer* once (System Settings → Privacy & Security
# → Open Anyway); after that the app itself launches cleanly.
#
# Usage:
#   ./scripts/make-beta-dmg.sh [version]
#
# Env:
#   SKIP_BUILD=1   reuse the most recent Release build in DerivedData
#                  instead of doing a clean build (faster iteration)
#
# Requires: Xcode at /Applications/Xcode.app, create-dmg (brew install
# create-dmg), python3 with Pillow.

APP_NAME="SolWhisper"
INSTALLER_NAME="Install SolWhisper"
INSTALLER_BUNDLE_ID="cloud.solay.SolWhisperBetaInstaller"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BETA_DIR="$PROJECT_DIR/scripts/beta-dmg"
DIST_DIR="$PROJECT_DIR/dist"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
ICNS="$PROJECT_DIR/Resources/AppIcon.icns"
LOGO="$PROJECT_DIR/design/SolWhisper_Logo.png"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$INFO_PLIST")}"
SKIP_BUILD="${SKIP_BUILD:-0}"

DMG_OUT="$DIST_DIR/${APP_NAME}-beta-v${VERSION}.dmg"

cd "$PROJECT_DIR"

# ── Pre-flight ────────────────────────────────────────────────────────────
echo "▶ Pre-flight"
for tool in create-dmg osacompile codesign hdiutil python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "  ✗ missing: $tool"; exit 1; }
done
python3 -c "import PIL" 2>/dev/null || { echo "  ✗ python3 Pillow not installed (pip3 install Pillow)"; exit 1; }
[ -f "$ICNS" ] || { echo "  ✗ missing app icon: $ICNS"; exit 1; }
echo "  ✓ tooling present"

# ── Build (or reuse) the app ──────────────────────────────────────────────
if [ "$SKIP_BUILD" != "1" ]; then
    echo "▶ Build Release"
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
                 -scheme "$APP_NAME" -configuration Release \
                 clean build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" | head -5
else
    echo "▶ Reusing most recent Release build (SKIP_BUILD=1)"
fi

# Pick the newest Release product across DerivedData dirs (mtime-sorted).
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/${APP_NAME}-*/Build/Products/Release \
             -name "$APP_NAME.app" -maxdepth 1 2>/dev/null \
           | xargs -I{} stat -f "%m {}" 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "  ✗ Release build of $APP_NAME.app not found. Run without SKIP_BUILD=1."
    exit 1
fi
BUILD=$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")
echo "  ✓ Using $APP_PATH (v$VERSION build $BUILD)"

# ── Workspace ─────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGED_APP="$WORK/$APP_NAME.app"
INSTALLER_APP="$WORK/$INSTALLER_NAME.app"
DMG_ROOT="$WORK/dmgroot"
mkdir -p "$DMG_ROOT"

# ── Stage + ad-hoc sign the app ───────────────────────────────────────────
echo "▶ Stage app"
cp -R "$APP_PATH" "$STAGED_APP"
xattr -cr "$STAGED_APP" 2>/dev/null || true
# --force --deep ad-hoc so Sparkle.framework's Team ID matches the host's
# (nil); otherwise the app fails to launch after copy.
codesign --force --deep --sign - "$STAGED_APP"
codesign --verify --deep "$STAGED_APP" 2>/dev/null || { echo "  ✗ app codesign verify failed"; exit 1; }
echo "  ✓ app staged + ad-hoc signed"

# ── Build the installer helper app ────────────────────────────────────────
echo "▶ Build installer helper"
osacompile -o "$INSTALLER_APP" "$BETA_DIR/installer.applescript"

# Embed the real app inside the installer's Resources.
cp -R "$STAGED_APP" "$INSTALLER_APP/Contents/Resources/$APP_NAME.app"

# Use the SolWhisper icon for the installer (osacompile names it applet.icns).
cp "$ICNS" "$INSTALLER_APP/Contents/Resources/applet.icns"

# Patch the installer's Info.plist: names, identifier, and run as an
# accessory (no Dock icon flashing during the brief install).
IPLIST="$INSTALLER_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $INSTALLER_NAME" "$IPLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $INSTALLER_NAME" "$IPLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $INSTALLER_NAME" "$IPLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $INSTALLER_NAME" "$IPLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $INSTALLER_BUNDLE_ID" "$IPLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $INSTALLER_BUNDLE_ID" "$IPLIST"

# Ad-hoc sign the whole installer (covers the embedded app too).
codesign --force --deep --sign - "$INSTALLER_APP"
echo "  ✓ installer built ($(du -sh "$INSTALLER_APP" | cut -f1))"

# ── Render branded background → HiDPI tiff ────────────────────────────────
echo "▶ Render background"
BG_1X="$WORK/background.png"
BG_2X="$WORK/background@2x.png"
BG_TIFF="$WORK/background.tiff"
python3 "$BETA_DIR/make-background.py" "$LOGO" "$BG_1X" "$BG_2X" "$VERSION"
# Fold 1x + 2x into a multi-representation HiDPI tiff so it's crisp on
# Retina (Finder does not scale DMG backgrounds).
tiffutil -cathidpicheck "$BG_1X" "$BG_2X" -out "$BG_TIFF" >/dev/null
echo "  ✓ background.tiff"

# ── Assemble DMG ──────────────────────────────────────────────────────────
echo "▶ Build DMG"
cp -R "$INSTALLER_APP" "$DMG_ROOT/$INSTALLER_NAME.app"
mkdir -p "$DIST_DIR"
rm -f "$DMG_OUT"

create-dmg \
  --volname "$APP_NAME Beta" \
  --volicon "$ICNS" \
  --background "$BG_TIFF" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --text-size 13 \
  --icon "$INSTALLER_NAME.app" 475 165 \
  --no-internet-enable \
  "$DMG_OUT" \
  "$DMG_ROOT" \
  || true   # create-dmg returns nonzero if it can't set the volume icon; the DMG is still produced.

[ -f "$DMG_OUT" ] || { echo "  ✗ DMG not produced"; exit 1; }
DMG_MB=$(echo "scale=1; $(stat -f%z "$DMG_OUT") / 1048576" | bc)
echo "  ✓ $(basename "$DMG_OUT") (${DMG_MB} MB)"

# ── Tester instructions (paste into your beta invite) ─────────────────────
cat <<DONE

────────────────────────────────────────────────────────────────────
  Beta DMG ready:  $DMG_OUT
────────────────────────────────────────────────────────────────────

Share this with testers:

  1. Download and open SolWhisper-beta-v${VERSION}.dmg.
  2. Double-click "Install SolWhisper".
  3. If macOS says it "cannot be opened" / "can't verify the developer":
       System Settings → Privacy & Security → scroll down →
       "Open Anyway" next to Install SolWhisper, then double-click again.
  4. Enter your password when the installer asks.
  5. On first launch, grant Microphone, Speech Recognition, Accessibility
     and Automation in System Settings → Privacy & Security so dictation
     and paste work.

Note: this is an unsigned beta (no Apple Developer ID yet), which is why
the one-time approval is needed. Once you have a Developer ID, switch to
scripts/release.sh with SW_DEVELOPER_ID + SW_NOTARIZE_PROFILE set and the
approval step disappears.
DONE
