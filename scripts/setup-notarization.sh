#!/bin/bash
set -euo pipefail

# scripts/setup-notarization.sh — one-time setup helper for notarized releases.
#
# Run this AFTER:
#   1. Activating an Apple Developer account ($99/year)
#   2. Creating + downloading a "Developer ID Application" certificate from
#      https://developer.apple.com/account/resources/certificates/list
#   3. Importing the .cer into Keychain Access (double-click)
#   4. Generating an app-specific password at https://appleid.apple.com
#      → Sign-In and Security → App-Specific Passwords
#
# What it does:
#   - Verifies your Developer ID cert is in the Keychain
#   - Stores the notarization credentials in a Keychain "profile" so
#     `xcrun notarytool` can submit without asking for a password each release
#   - Prints the env vars to add to your shell (or .envrc) so release.sh
#     picks them up automatically
#
# Usage:
#   ./scripts/setup-notarization.sh
# (interactive; prompts for Apple ID + Team ID + app-specific password)

PROFILE_NAME="SolWhisperNotary"

echo "▶ Looking for Developer ID Application cert in Keychain"
CERT=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
if [ -z "$CERT" ]; then
    echo "  ✗ No Developer ID Application certificate found in Keychain."
    echo "    Visit https://developer.apple.com/account/resources/certificates/list"
    echo "    to create + download one, then double-click the .cer to import."
    exit 1
fi
echo "  ✓ $CERT"

# Pull the cert name + Team ID out of the security output.
CERT_NAME=$(echo "$CERT" | sed -E 's/.*"([^"]+)".*/\1/')
TEAM_ID=$(echo "$CERT_NAME" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
echo "  Cert name: $CERT_NAME"
echo "  Team ID:   $TEAM_ID"

echo ""
read -rp "Apple ID (email): " APPLE_ID
read -srp "App-specific password (https://appleid.apple.com): " APP_PASSWORD
echo ""

echo ""
echo "▶ Storing notarization profile in Keychain as \"$PROFILE_NAME\""
xcrun notarytool store-credentials "$PROFILE_NAME" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD"

echo ""
echo "▶ Done. Add these to your shell rc (or .envrc) to use the profile on every release:"
echo ""
echo "  export SW_DEVELOPER_ID=\"$CERT_NAME\""
echo "  export SW_NOTARIZE_PROFILE=\"$PROFILE_NAME\""
echo "  export SW_TEAM_ID=\"$TEAM_ID\""
echo ""
echo "Then ./scripts/release.sh <version> will sign + notarize + staple automatically."
