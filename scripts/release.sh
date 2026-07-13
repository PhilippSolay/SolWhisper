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
# Notarization (Sprint 0):
#   When SW_NOTARIZE_PROFILE is set in the environment, the script signs the
#   app with Developer ID, submits to Apple's notary service, staples the
#   ticket, and packages the notarized bundle into the DMG. Without it,
#   falls back to ad-hoc signing (useful for dev iteration / pre-cert work).
#
#   To set up once:
#     xcrun notarytool store-credentials "SolWhisperNotary" \
#       --apple-id you@example.com \
#       --team-id ABCDE12345 \
#       --password <app-specific-password>
#
#   Then export before running:
#     export SW_NOTARIZE_PROFILE="SolWhisperNotary"
#     export SW_DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)"
#
# Usage: ./scripts/release.sh <version> [release-notes-file]
# Example: ./scripts/release.sh 0.4.0 notes/v0.4.0.md
#
# Optional env:
#   SW_DRY_RUN=1          build + package + sign everything, then stop before
#                         appcast/commit/push/release (Info.plist restored)
#   SW_SKIP_UNIVERSAL=1   skip the universal (arm64 + x86_64) DMG for Intel;
#                         the appcast arm64 DMG is always built
#
# Required:
#   - gh CLI authenticated (gh auth login)
#   - Sparkle EdDSA private key in Keychain (run scripts/generate-sparkle-keys.sh once)
#   - Xcode at /Applications/Xcode.app
#   - For notarization: Apple Developer account + notary keychain profile (see above)

VERSION="${1:?Usage: $0 <version> [release-notes-file]}"
NOTES_FILE="${2:-}"
REPO="PhilippSolay/SolWhisper"
APP_NAME="SolWhisper"
BUNDLE_ID="cloud.solay.SolWhisper"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
DMG_PATH="$PROJECT_DIR/$DMG_NAME"
UNIVERSAL_DMG_NAME="${APP_NAME}-v${VERSION}-universal.dmg"
UNIVERSAL_DMG_PATH="$PROJECT_DIR/$UNIVERSAL_DMG_NAME"
APPCAST="$PROJECT_DIR/appcast.xml"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
# Explicit DerivedData path for THIS checkout, so the release always packages the
# app this worktree just built — never a stale SolWhisper-<hash> DerivedData dir
# left behind by another checkout. (build/ is gitignored.)
DERIVED_DATA="$PROJECT_DIR/build"

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
#
# When SW_TEAM_ID is set, xcodebuild does Developer ID signing in-tree. The
# downstream re-sign block still re-signs the bundle in staging (so the DMG
# matches what we hand to notarytool), but having xcodebuild use the right
# team avoids "Sparkle.framework not signed by same team" warnings.
XCODEBUILD_ARGS=(
    -project "$PROJECT_DIR/$APP_NAME.xcodeproj"
    -scheme "$APP_NAME"
    -configuration Release
    -derivedDataPath "$DERIVED_DATA"
    clean build
)
if [ -n "${SW_TEAM_ID:-}" ]; then
    XCODEBUILD_ARGS+=(DEVELOPMENT_TEAM="$SW_TEAM_ID" CODE_SIGN_IDENTITY="Developer ID Application")
fi
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild "${XCODEBUILD_ARGS[@]}" 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" | head -3

# Select the product deterministically from our explicit -derivedDataPath. The
# old `find … DerivedData/SolWhisper-*` + newest-mtime heuristic could latch onto
# a stale build from another checkout — that bug once shipped a v0.5.1 binary
# inside the v0.6.0 / v0.6.1 DMGs. Pinning derivedDataPath removes the ambiguity;
# the version guard below stays as a backstop.
APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "  ✗ Build product not found at $APP_PATH"
    exit 1
fi

BUILD=$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")
# Guard against packaging a stale app: the freshly built bundle MUST carry
# the version we just stamped into the source plist. If it doesn't, we
# grabbed the wrong DerivedData and must stop before shipping old code.
APP_SHORT=$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")
if [ "$APP_SHORT" != "$VERSION" ]; then
    echo "  ✗ Built app reports version $APP_SHORT but releasing $VERSION."
    echo "    Stale build product selected: $APP_PATH"
    echo "    Aborting before a stale binary gets packaged."
    exit 1
fi
echo "  ✓ Built $APP_NAME $VERSION (build $BUILD)"

# ── Package DMG ──────────────────────────────────────────────────────────────

echo "▶ Package DMG"

# mktemp -d avoids a predictable /tmp path a co-tenant could pre-create or
# symlink-race on a shared host.
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-release-staging.XXXXXX")
[ -n "$STAGING" ] && [ -d "$STAGING" ] || { echo "  ✗ staging mktemp failed"; exit 1; }
rm -f "$DMG_PATH"
cp -R "$APP_PATH" "$STAGING/$APP_NAME.app"

# CRITICAL: re-sign so Sparkle.framework's Team ID matches the host's
# (otherwise the app fails to launch after auto-update with:
#   "Library not loaded: @rpath/Sparkle.framework — different Team IDs")
#
# Two paths:
#   1. SW_DEVELOPER_ID set + SW_NOTARIZE_PROFILE set → Developer ID + notarize.
#      TCC permissions persist across versions, no quarantine prompt for users.
#   2. Neither set → ad-hoc. Local dev iteration; users will hit Gatekeeper +
#      get TCC reset on every install.
ENTITLEMENTS="$PROJECT_DIR/Resources/SolWhisper.entitlements"

# Signs a staged bundle. Developer ID + notarize + staple when both
# SW_DEVELOPER_ID and SW_NOTARIZE_PROFILE are set, ad-hoc otherwise.
# Shared by the arm64 and universal packaging paths.
sign_and_notarize() {
    local app="$1"
    if [ -n "${SW_DEVELOPER_ID:-}" ] && [ -n "${SW_NOTARIZE_PROFILE:-}" ]; then
        echo "  ▸ Developer ID signing: $SW_DEVELOPER_ID"
        codesign --force --deep --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" \
            --sign "$SW_DEVELOPER_ID" "$app"
        if ! codesign --verify --deep --strict --verbose=2 "$app" 2>/dev/null; then
            echo "  ✗ codesign verify failed on Developer ID-signed bundle"
            exit 1
        fi
        echo "  ✓ Bundle signed with Developer ID + hardened runtime"

        # Notarize: zip the bundle, submit, wait for ticket, staple it back to
        # the bundle. Stapling is what lets the app launch offline without
        # contacting Apple every time.
        echo "▶ Notarize (this can take 1–10 minutes)"
        local notary_dir
        notary_dir=$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-notarize.XXXXXX")
        [ -n "$notary_dir" ] && [ -d "$notary_dir" ] || { echo "  ✗ notarize mktemp failed"; exit 1; }
        local notary_zip="$notary_dir/$APP_NAME.zip"
        /usr/bin/ditto -c -k --keepParent "$app" "$notary_zip"
        if ! xcrun notarytool submit "$notary_zip" \
                --keychain-profile "$SW_NOTARIZE_PROFILE" \
                --wait; then
            echo "  ✗ notarytool submission failed — check output above"
            rm -rf "$notary_dir"
            exit 1
        fi
        rm -rf "$notary_dir"
        xcrun stapler staple "$app"
        if ! xcrun stapler validate "$app" >/dev/null 2>&1; then
            echo "  ✗ stapler validate failed"
            exit 1
        fi
        echo "  ✓ Notarized + stapled"
    else
        if [ -n "${SW_DEVELOPER_ID:-}" ] || [ -n "${SW_NOTARIZE_PROFILE:-}" ]; then
            echo "  ⚠ Both SW_DEVELOPER_ID and SW_NOTARIZE_PROFILE must be set together."
            echo "    Falling back to ad-hoc."
        fi
        codesign --force --deep --sign - "$app" 2>/dev/null
        if ! codesign --verify --deep "$app" 2>/dev/null; then
            echo "  ✗ codesign verify failed on staged bundle"
            exit 1
        fi
        echo "  ✓ Bundle re-signed ad-hoc (no notarization — testers will see Gatekeeper)"
    fi
}

sign_and_notarize "$STAGING/$APP_NAME.app"

ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

DMG_SIZE=$(stat -f%z "$DMG_PATH")
echo "  ✓ $DMG_NAME ($(printf '%.1f' "$(echo "$DMG_SIZE / 1048576" | bc -l)") MB)"

# ── Sign DMG with Sparkle EdDSA ──────────────────────────────────────────────

echo "▶ Sign DMG (Sparkle EdDSA)"

# Prefer the sign_update vended into our explicit derivedDataPath (that's where
# the build above put Sparkle's SPM artifacts); fall back to the default
# DerivedData location for any cached copy.
SIGN_TOOL=$(find "$DERIVED_DATA" ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/Sparkle*" 2>/dev/null | head -1)
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

# ── Universal DMG (arm64 + x86_64) ───────────────────────────────────────────
#
# Extra release asset for Intel Macs. The appcast keeps pointing at the thin
# arm64 DMG above — existing Sparkle users are Apple Silicon and shouldn't
# pull 2× the bytes. Runs BEFORE the appcast/commit step because the bump
# phase re-bumps CFBundleVersion: committing after this build keeps the
# committed plist monotonic and the tree clean. (The universal bundle carries
# a build number one tick above the arm64 one — harmless, it's not in the
# appcast.) Skip with SW_SKIP_UNIVERSAL=1.

if [ -z "${SW_SKIP_UNIVERSAL:-}" ]; then
    echo "▶ Build universal (arm64 + x86_64)"

    # No `clean`: the arm64 objects from the build above are reused; only the
    # x86_64 slices compile fresh. The plain-build default picks the concrete
    # "My Mac (arm64)" destination, so ARCHS/ONLY_ACTIVE_ARCH must be forced.
    XCODEBUILD_UNIVERSAL_ARGS=(
        -project "$PROJECT_DIR/$APP_NAME.xcodeproj"
        -scheme "$APP_NAME"
        -configuration Release
        -derivedDataPath "$DERIVED_DATA"
        build
        ARCHS="arm64 x86_64"
        ONLY_ACTIVE_ARCH=NO
    )
    if [ -n "${SW_TEAM_ID:-}" ]; then
        XCODEBUILD_UNIVERSAL_ARGS+=(DEVELOPMENT_TEAM="$SW_TEAM_ID" CODE_SIGN_IDENTITY="Developer ID Application")
    fi
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      xcodebuild "${XCODEBUILD_UNIVERSAL_ARGS[@]}" 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" | head -3

    # Same explicit-derivedDataPath selection + version guard as the arm64 build.
    # The universal build reuses $DERIVED_DATA (arm64 objects are already there)
    # and overwrites the Release product in place with the fat binary — the arm64
    # DMG was already packaged + EdDSA-signed above, so overwriting is safe.
    UAPP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
    if [ ! -d "$UAPP_PATH" ]; then
        echo "  ✗ Universal build product not found at $UAPP_PATH"
        exit 1
    fi
    UAPP_SHORT=$(plutil -extract CFBundleShortVersionString raw "$UAPP_PATH/Contents/Info.plist")
    if [ "$UAPP_SHORT" != "$VERSION" ]; then
        echo "  ✗ Universal app reports version $UAPP_SHORT but releasing $VERSION."
        echo "    Stale build product selected: $UAPP_PATH"
        exit 1
    fi
    LIPO_OUT=$(lipo -info "$UAPP_PATH/Contents/MacOS/$APP_NAME")
    if ! echo "$LIPO_OUT" | grep -q "x86_64" || ! echo "$LIPO_OUT" | grep -q "arm64"; then
        echo "  ✗ Universal binary is missing an architecture:"
        echo "    $LIPO_OUT"
        exit 1
    fi
    echo "  ✓ Universal binary verified (x86_64 + arm64)"

    echo "▶ Package universal DMG"
    USTAGING=$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-release-staging-universal.XXXXXX")
    [ -n "$USTAGING" ] && [ -d "$USTAGING" ] || { echo "  ✗ universal staging mktemp failed"; exit 1; }
    rm -f "$UNIVERSAL_DMG_PATH"
    cp -R "$UAPP_PATH" "$USTAGING/$APP_NAME.app"
    sign_and_notarize "$USTAGING/$APP_NAME.app"
    ln -s /Applications "$USTAGING/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$USTAGING" -ov -format UDZO "$UNIVERSAL_DMG_PATH" >/dev/null
    rm -rf "$USTAGING"
    UDMG_SIZE=$(stat -f%z "$UNIVERSAL_DMG_PATH")
    echo "  ✓ $UNIVERSAL_DMG_NAME ($(printf '%.1f' "$(echo "$UDMG_SIZE / 1048576" | bc -l)") MB)"
fi

# ── Dry run stops here ───────────────────────────────────────────────────────

if [ -n "${SW_DRY_RUN:-}" ]; then
    echo "▶ Dry run — stopping before appcast/commit/release"
    git checkout -- "$INFO_PLIST"
    echo "  ✓ Built $DMG_NAME"
    if [ -f "$UNIVERSAL_DMG_PATH" ]; then
        echo "  ✓ Built $UNIVERSAL_DMG_NAME"
    fi
    echo "  ✓ $INFO_PLIST restored (git checkout)"
    echo "  Skipped: appcast update, whats-new, git commit/push, gh release, URL verify."
    exit 0
fi

# ── Ad-hoc release guard ─────────────────────────────────────────────────────
#
# Everything below PUBLISHES (GitHub release + appcast push to main). When
# neither SW_DEVELOPER_ID nor SW_NOTARIZE_PROFILE is set the bundle was only
# ad-hoc signed — not notarized — so real users hit Gatekeeper and lose their
# granted permissions (TCC reset) on every install. Refuse to publish one unless
# it's an explicit, intentional ad-hoc / test release. SW_DRY_RUN already exited
# above, so dry-run builds never need the override.
if [ -z "${SW_DEVELOPER_ID:-}" ] || [ -z "${SW_NOTARIZE_PROFILE:-}" ]; then
    if [ -z "${SW_ALLOW_ADHOC_RELEASE:-}" ]; then
        echo "  ✗ Refusing to publish an ad-hoc-signed (non-notarized) build to real users."
        echo "    SW_DEVELOPER_ID and/or SW_NOTARIZE_PROFILE are unset, so the DMG is only"
        echo "    ad-hoc signed. Shipping it means Gatekeeper warnings and a TCC permission"
        echo "    reset for every user on every install."
        echo ""
        echo "    Ship a proper notarized release — enroll in the Apple Developer Program, then:"
        echo "      export SW_DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\""
        echo "      export SW_NOTARIZE_PROFILE=\"SolWhisperNotary\"   # xcrun notarytool store-credentials"
        echo ""
        echo "    …or, for an intentional ad-hoc / internal test release, re-run with the override:"
        echo "      SW_ALLOW_ADHOC_RELEASE=1 $0 $VERSION${NOTES_FILE:+ $NOTES_FILE}"
        echo ""
        echo "    …or build + package without publishing:  SW_DRY_RUN=1 $0 $VERSION"
        exit 1
    fi
    echo "  ⚠ SW_ALLOW_ADHOC_RELEASE=1 — publishing an AD-HOC-signed (non-notarized) build."
    echo "    Users will see Gatekeeper warnings and TCC permission resets on install."
fi

# Release-asset download URLs — defined before the release is created so the
# post-upload verify and the final summary can both reference them.
DMG_URL="https://github.com/$REPO/releases/download/v${VERSION}/${DMG_NAME}"
UNIVERSAL_DMG_URL="https://github.com/$REPO/releases/download/v${VERSION}/${UNIVERSAL_DMG_NAME}"

# ── Create GitHub release (upload DMG assets) ────────────────────────────────
#
# ORDER OF OPERATIONS: the release is created, the DMG assets uploaded, and the
# arm64 download URL verified reachable (HTTP 200) BEFORE the appcast.xml change
# is committed/pushed to main. If the upload or the 200-check fails we exit
# non-zero here — the appcast is never pushed, so Sparkle clients can't be sent
# to a DMG URL that 404s.

echo "▶ Create GitHub release"

RELEASE_ASSETS=("$DMG_PATH")
if [ -f "$UNIVERSAL_DMG_PATH" ]; then
    RELEASE_ASSETS+=("$UNIVERSAL_DMG_PATH")
fi
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    gh release create "v${VERSION}" --repo "$REPO" --title "$APP_NAME v${VERSION}" --notes-file "$NOTES_FILE" "${RELEASE_ASSETS[@]}" >/dev/null
else
    gh release create "v${VERSION}" --repo "$REPO" --title "$APP_NAME v${VERSION}" --notes "Release v${VERSION}" "${RELEASE_ASSETS[@]}" >/dev/null
fi
echo "  ✓ Released v${VERSION} (${#RELEASE_ASSETS[@]} DMG asset(s))"

# ── Verify download URL (before the appcast is pushed) ───────────────────────

echo "▶ Verify download URL"

# Wait a moment for GitHub CDN
sleep 3
HTTP_CODE=$(curl -sIL "$DMG_URL" -o /dev/null -w "%{http_code}")
if [ "$HTTP_CODE" != "200" ]; then
    echo "  ✗ DMG URL returned HTTP $HTTP_CODE — the uploaded asset is not reachable:"
    echo "    $DMG_URL"
    echo "    Aborting BEFORE the appcast is pushed, so Sparkle is never pointed at a 404."
    echo "    The GitHub release exists; fix the asset (or delete the release) and re-run."
    exit 1
fi
echo "  ✓ DMG downloads (HTTP 200)"

if [ -f "$UNIVERSAL_DMG_PATH" ]; then
    HTTP_CODE_U=$(curl -sIL "$UNIVERSAL_DMG_URL" -o /dev/null -w "%{http_code}")
    if [ "$HTTP_CODE_U" != "200" ]; then
        echo "  ⚠ Universal DMG URL returned HTTP $HTTP_CODE_U — check the release page"
        echo "    (the appcast points at the arm64 DMG only, so this does not block the release)"
    else
        echo "  ✓ Universal DMG downloads (HTTP 200)"
    fi
fi

# ── Update appcast.xml (PREPEND new item, preserve history) ──────────────────
#
# Reached only after the DMG upload is verified reachable above, so the pushed
# appcast always references a live asset.

echo "▶ Update appcast.xml"

PUB_DATE=$(date -R)

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
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
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

# ── Update Resources/whats-new.json (prepend release entry) ─────────────────
#
# When SW_WHATSNEW_TITLE / SW_WHATSNEW_BODY are set in the env, the release
# script prepends a fresh "What's new?" item to the bundled feed so testers
# see the marketing copy on Settings → Home. Without those vars, the file
# is left alone — keeping the existing entries.
WHATSNEW="$PROJECT_DIR/Resources/whats-new.json"
if [ -n "${SW_WHATSNEW_TITLE:-}" ] && [ -n "${SW_WHATSNEW_BODY:-}" ] && [ -f "$WHATSNEW" ]; then
    DATE=$(date -u +%Y-%m-%d)
    python3 - "$WHATSNEW" "$DATE" "$VERSION" "$SW_WHATSNEW_TITLE" "$SW_WHATSNEW_BODY" <<'PYEOF'
import json, sys
path, date, version, title, body = sys.argv[1:6]
with open(path) as f: data = json.load(f)
items = data.get("items", [])
items.insert(0, {"date": date, "version": version, "title": title, "body": body})
data["items"] = items
with open(path, "w") as f: json.dump(data, f, indent=2)
PYEOF
    echo "  ✓ Prepended What's-new entry: $SW_WHATSNEW_TITLE"
fi

git add appcast.xml "$INFO_PLIST" "$WHATSNEW"
git commit -m "Release v${VERSION}" >/dev/null || true
git push origin main >/dev/null
echo "  ✓ Pushed to main"

# ── Done ─────────────────────────────────────────────────────────────────────

if [ -n "${SW_NOTARIZE_PROFILE:-}" ]; then
    INSTALL_NOTE="Download the DMG, drag SolWhisper to Applications, launch.
  No xattr / Gatekeeper hoops — bundle is notarized + stapled.
  Permissions granted previously will persist."
else
    INSTALL_NOTE="Download the DMG, drag SolWhisper to Applications.
  xattr -cr /Applications/SolWhisper.app   (ad-hoc build, clears quarantine)
  Launch and grant Microphone + Speech Recognition + Accessibility + Automation.
  TCC permissions reset because CDHash changed."
fi

UNIVERSAL_LINE=""
if [ -f "$UNIVERSAL_DMG_PATH" ]; then
    UNIVERSAL_LINE="  $UNIVERSAL_DMG_URL   (universal — Intel + Apple Silicon)
"
fi

cat <<DONE

Released $APP_NAME v${VERSION} (build $BUILD)
  https://github.com/$REPO/releases/tag/v${VERSION}
  $DMG_URL
${UNIVERSAL_LINE}  https://raw.githubusercontent.com/$REPO/main/appcast.xml

For testers (fresh install):
  $INSTALL_NOTE

For existing users:
  Click "Check for Updates…" in the menu bar.
  (If Sparkle says "you're up to date" stale-cached, quit + relaunch.)
DONE
