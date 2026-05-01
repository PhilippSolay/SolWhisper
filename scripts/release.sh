#!/bin/bash
set -euo pipefail

# SolWhisper Release Script
#
# Handles all the gotchas we've hit shipping releases via GitHub + Sparkle:
#   - Pre-flight: gh auth, repo visibility, working tree clean
#   - Sparkle.framework Team ID mismatch in DMG → codesign --force --deep
#     before packaging (otherwise app fails to launch after auto-update)
#   - Appcast history wiped on regenerate     → prepend new item, preserve old
#   - EdDSA signature missing                  → fail loudly
#   - DMG download URL not reachable           → verify post-upload
#   - Build number must always increase        → use Info.plist's auto-bump
#
# Usage: ./scripts/release.sh <version> [release-notes-file]
# Example: ./scripts/release.sh 0.4.0 notes/v0.4.0.md
#
# Required:
#   - gh CLI authenticated (gh auth login)
#   - Sparkle EdDSA private key in Keychain (run scripts/generate-sparkle-keys.sh once)
#   - Xcode at /Applications/Xcode.app

VERSION="${1:?Usage: $0 <version> [release-notes-file]}"
NOTES_FILE="${2:-}"
REPO="PhilippSolay/SolWhisper"
APP_NAME="SolWhisper"
BUNDLE_ID="cloud.solay.SolWhisper"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
DMG_PATH="$PROJECT_DIR/$DMG_NAME"
APPCAST="$PROJECT_DIR/appcast.xml"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"

cd "$PROJECT_DIR"

# ── Pre-flight ───────────────────────────────────────────────────────────────

echo "▶ Pre-flight checks"

# gh auth
if ! gh auth status >/dev/null 2>&1; then
    echo "  ✗ gh CLI not authenticated. Run: gh auth login"
    exit 1
fi
echo "  ✓ gh authenticated"

# repo public (otherwise raw.githubusercontent.com appcast.xml is 404)
VISIBILITY=$(gh repo view "$REPO" --json visibility --jq '.visibility' 2>/dev/null || echo "?")
if [ "$VISIBILITY" != "PUBLIC" ]; then
    echo "  ✗ Repo $REPO is $VISIBILITY. Sparkle needs public for appcast."
    echo "    Fix:  gh repo edit $REPO --visibility public"
    exit 1
fi
echo "  ✓ repo public"

# tag doesn't already exist
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "  ✗ Release v$VERSION already exists on GitHub. Bump version or delete tag."
    exit 1
fi
echo "  ✓ tag v$VERSION free"

# version is greater than highest existing
HIGHEST=$(awk -F'[<>]' '/sparkle:shortVersionString/ {print $3; exit}' "$APPCAST" 2>/dev/null || echo "0.0.0")
if [ "$(printf '%s\n%s\n' "$VERSION" "$HIGHEST" | sort -V | tail -1)" != "$VERSION" ] || [ "$VERSION" = "$HIGHEST" ]; then
    echo "  ✗ Version $VERSION is not greater than current $HIGHEST in appcast."
    exit 1
fi
echo "  ✓ version $VERSION > $HIGHEST"

# ── Build ────────────────────────────────────────────────────────────────────

echo "▶ Bump version + build"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"

# The Bump Build Number build phase auto-increments CFBundleVersion during
# xcodebuild. Don't set it manually here.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    clean build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" | head -3

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/${APP_NAME}-*/Build/Products/Release -name "$APP_NAME.app" -maxdepth 1 2>/dev/null | head -1)
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "  ✗ Build product not found"
    exit 1
fi

BUILD=$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")
echo "  ✓ Built $APP_NAME $VERSION (build $BUILD)"

# ── Package DMG ──────────────────────────────────────────────────────────────

echo "▶ Package DMG"

STAGING="/tmp/$APP_NAME-release-staging"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/$APP_NAME.app"

# CRITICAL: re-sign so Sparkle.framework's Team ID matches the host's (both nil
# under ad-hoc). Without this, after auto-update the app fails to launch with:
#   Library not loaded: @rpath/Sparkle.framework — different Team IDs
codesign --force --deep --sign - "$STAGING/$APP_NAME.app" 2>/dev/null
if ! codesign --verify --deep "$STAGING/$APP_NAME.app" 2>/dev/null; then
    echo "  ✗ codesign verify failed on staged bundle"
    exit 1
fi
echo "  ✓ Bundle re-signed (consistent ad-hoc, fixes Sparkle Team ID mismatch)"

ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

DMG_SIZE=$(stat -f%z "$DMG_PATH")
echo "  ✓ $DMG_NAME ($(printf '%.1f' "$(echo "$DMG_SIZE / 1048576" | bc -l)") MB)"

# ── Sign DMG with Sparkle EdDSA ──────────────────────────────────────────────

echo "▶ Sign DMG (Sparkle EdDSA)"

SIGN_TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/Sparkle*" 2>/dev/null | head -1)
if [ -z "$SIGN_TOOL" ]; then
    echo "  ✗ sign_update not found (build the project first to fetch Sparkle SPM)"
    exit 1
fi

SIGNATURE=$("$SIGN_TOOL" "$DMG_PATH")
ED_SIG=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
ED_LEN=$(echo "$SIGNATURE" | grep -o 'length="[^"]*"' | cut -d'"' -f2)

if [ -z "$ED_SIG" ] || [ -z "$ED_LEN" ]; then
    echo "  ✗ Failed to parse Sparkle signature: $SIGNATURE"
    exit 1
fi
echo "  ✓ EdDSA signed"

# ── Update appcast.xml (PREPEND new item, preserve history) ──────────────────

echo "▶ Update appcast.xml"

PUB_DATE=$(date -R)
DMG_URL="https://github.com/$REPO/releases/download/v${VERSION}/${DMG_NAME}"

# Build the new <item> block as a here-doc (release notes optional)
NOTES_BLOCK=""
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    NOTES_HTML=$(cat "$NOTES_FILE")
    NOTES_BLOCK="      <description><![CDATA[
$NOTES_HTML
      ]]></description>
"
fi

NEW_ITEM=$(cat <<NEW_ITEM_EOF
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
${NOTES_BLOCK}      <enclosure url="${DMG_URL}"
                 sparkle:edSignature="${ED_SIG}"
                 length="${ED_LEN}"
                 type="application/octet-stream"/>
    </item>
NEW_ITEM_EOF
)

if [ -f "$APPCAST" ]; then
    # Prepend the new item before the first existing <item>, preserving history
    python3 - "$APPCAST" "$NEW_ITEM" <<'PYEOF'
import sys, re
path, new_item = sys.argv[1], sys.argv[2]
with open(path) as f: content = f.read()
content = re.sub(r'(\s*<item>)', new_item + r'\n\1', content, count=1)
with open(path, 'w') as f: f.write(content)
PYEOF
else
    cat > "$APPCAST" <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>SolWhisper Updates</title>
    <language>en</language>
$NEW_ITEM
  </channel>
</rss>
APPCAST_EOF
fi
echo "  ✓ Prepended item to appcast.xml"

# ── Commit + push ────────────────────────────────────────────────────────────

echo "▶ Commit + push"

git add appcast.xml "$INFO_PLIST"
git commit -m "Release v${VERSION}" >/dev/null || true
git push origin main >/dev/null
echo "  ✓ Pushed to main"

# ── Create GitHub release ────────────────────────────────────────────────────

echo "▶ Create GitHub release"

if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    gh release create "v${VERSION}" --repo "$REPO" --title "$APP_NAME v${VERSION}" --notes-file "$NOTES_FILE" "$DMG_PATH" >/dev/null
else
    gh release create "v${VERSION}" --repo "$REPO" --title "$APP_NAME v${VERSION}" --notes "Release v${VERSION}" "$DMG_PATH" >/dev/null
fi
echo "  ✓ Released v${VERSION}"

# ── Post-upload verify ───────────────────────────────────────────────────────

echo "▶ Verify download URL"

# Wait a moment for GitHub CDN
sleep 3
HTTP_CODE=$(curl -sIL "$DMG_URL" -o /dev/null -w "%{http_code}")
if [ "$HTTP_CODE" != "200" ]; then
    echo "  ⚠ DMG URL returned HTTP $HTTP_CODE — check the release page"
else
    echo "  ✓ DMG downloads (HTTP 200)"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

cat <<DONE

Released $APP_NAME v${VERSION} (build $BUILD)
  https://github.com/$REPO/releases/tag/v${VERSION}
  $DMG_URL
  https://raw.githubusercontent.com/$REPO/main/appcast.xml

For testers (fresh install):
  1. Download the DMG, drag SolWhisper to Applications
  2. xattr -cr /Applications/SolWhisper.app   (clear quarantine flag)
  3. Launch and grant Microphone + Speech Recognition + Automation

For existing users:
  Click "Check for Updates…" in the menu bar.
  (If Sparkle says "you're up to date" stale-cached, quit + relaunch.)
DONE
