#!/usr/bin/env bash
# Build an unsigned Ketamine .ipa (for sideload tools that re-sign).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "FOUT: volledige Xcode is vereist (niet alleen Command Line Tools)." >&2
  echo "  1. Installeer Xcode uit de App Store" >&2
  echo "  2. sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  echo "  3. sudo xcodebuild -license accept" >&2
  echo "  4. bash scripts/build-unsigned-ipa.sh" >&2
  exit 1
fi

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

DERIVED="$ROOT/build/DerivedData"
ARCHIVE_DIR="$ROOT/build/unsigned"
APP_DIR="$ARCHIVE_DIR/Payload"
IPA="$ROOT/build/Ketamine-unsigned.ipa"
SDK="${IOS_SDK:-iphoneos}"

rm -rf "$DERIVED" "$ARCHIVE_DIR" "$IPA"
mkdir -p "$APP_DIR"

echo "==> Building (unsigned, $SDK)"
xcodebuild \
  -project Ketamine.xcodeproj \
  -scheme Ketamine \
  -configuration Release \
  -sdk "$SDK" \
  -derivedDataPath "$DERIVED" \
  -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  build

APP="$(find "$DERIVED/Build/Products" -name 'Ketamine.app' -type d | head -1)"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "FOUT: Ketamine.app niet gevonden na build" >&2
  find "$DERIVED/Build/Products" -maxdepth 3 -type d 2>/dev/null || true
  exit 1
fi

echo "==> Packaging IPA from: $APP"
cp -a "$APP" "$APP_DIR/"
(
  cd "$ARCHIVE_DIR"
  zip -qr "$IPA" Payload
)

echo ""
echo "OK: $IPA"
ls -lh "$IPA"
echo "Sideload met TrollStore / Sideloadly / etc. (zij moeten opnieuw signen of installeren)."
