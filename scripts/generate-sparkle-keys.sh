#!/bin/bash
set -euo pipefail

# Generate EdDSA key pair for Sparkle update signing.
# Run this ONCE. The private key goes in your Keychain.
# The public key goes in Info.plist as SUPublicEDKey.

echo "Looking for Sparkle's generate_keys tool..."

TOOL=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -path "*/Sparkle*" 2>/dev/null | head -1)
if [ -z "$TOOL" ]; then
  TOOL=$(which generate_keys 2>/dev/null || true)
fi

if [ -z "$TOOL" ]; then
  echo "ERROR: generate_keys not found."
  echo "Build the project in Xcode first (so Sparkle is downloaded),"
  echo "then run this script again."
  echo ""
  echo "The tool will be at:"
  echo "  ~/Library/Developer/Xcode/DerivedData/SolWhisper-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
  exit 1
fi

echo "Using: $TOOL"
echo ""
echo "This will store the private key in your Keychain and print the public key."
echo "Copy the public key into Info.plist → SUPublicEDKey"
echo ""

"$TOOL"
