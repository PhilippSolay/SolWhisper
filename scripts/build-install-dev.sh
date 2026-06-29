#!/usr/bin/env bash
#
# build-install-dev.sh — build SolWhisper signed with a STABLE self-signed
# identity and install it to /Applications, so macOS TCC permissions
# (Microphone, Speech, Accessibility, Screen Recording) persist across rebuilds.
#
# Background: ad-hoc signing changes the code hash every build, so macOS treats
# each build as a new app and resets every permission (~10 clicks each time).
# Signing with one stable cert keeps the designated requirement constant, so you
# grant permissions ONCE. Hardened runtime is left OFF (matches the old ad-hoc
# behavior) so the embedded Sparkle.framework loads without library-validation
# rejecting it.
#
# Prerequisite: a self-signed code-signing identity named "SolWhisper Dev" in the
# login keychain. This script creates it automatically on first run.
#
# Usage: scripts/build-install-dev.sh
set -euo pipefail

IDENTITY="SolWhisper Dev"
APP_NAME="SolWhisper"
SCHEME="SolWhisper"
PROJECT="SolWhisper.xcodeproj"
DEVELOPER_DIR_PATH="/Applications/Xcode.app/Contents/Developer"
INSTALL_PATH="/Applications/${APP_NAME}.app"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 1. Ensure the stable signing identity exists (create once if missing).
if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
  echo "▶ Creating self-signed code-signing identity '$IDENTITY' (one-time)…"
  TMP="$(mktemp -d)"
  OPENSSL="$(command -v openssl)"
  "$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
  # -legacy + sha1 MAC so Apple's `security import` can read the PKCS#12.
  "$OPENSSL" pkcs12 -export -legacy -macalg sha1 -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass:swdev -name "$IDENTITY" 2>/dev/null
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "swdev" -T /usr/bin/codesign -A
  rm -rf "$TMP"
  echo "  done. (cert is self-signed / untrusted — fine for local signing + TCC stability)"
fi

# 2. Regenerate the Xcode project so newly added source files are included.
if command -v xcodegen >/dev/null 2>&1; then
  echo "▶ xcodegen generate…"
  xcodegen generate >/dev/null
fi

# 3. Build, signed with the stable identity, hardened runtime OFF.
echo "▶ Building $APP_NAME (signed: $IDENTITY)…"
DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Debug build \
  ENABLE_DEBUG_DYLIB=NO ENABLE_HARDENED_RUNTIME=NO \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

BUILT="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Debug -showBuildSettings ENABLE_DEBUG_DYLIB=NO 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')/${APP_NAME}.app"

if [ ! -d "$BUILT" ]; then echo "✗ build product not found at $BUILT"; exit 1; fi

# 3. Install to /Applications (replaces the running copy).
echo "▶ Installing to $INSTALL_PATH…"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1
rm -rf "$INSTALL_PATH"
cp -R "$BUILT" "$INSTALL_PATH"
echo "  signed by: $(codesign -dvvv "$INSTALL_PATH" 2>&1 | grep -i 'Authority=' | head -1)"

echo "▶ Launching…"
open "$INSTALL_PATH"
echo "✓ Done. Permissions persist across rebuilds because the signing identity is stable."
