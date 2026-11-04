#!/usr/bin/env bash
# Builds Notch.app (Release) and notch-dbcheck into ./build, then signs them.
#
#   scripts/build.sh              build into ./build
#   scripts/build.sh --install    also copy Notch.app to ~/Applications (and restart it)
#
# Signing: uses NOTCH_SIGN_IDENTITY if set (name or SHA-1 from
# `security find-identity -v -p codesigning`), otherwise the first
# "Apple Development" identity (preferring one containing "theajstars"),
# otherwise ad-hoc. A stable identity keeps the Full Disk Access grant across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
DERIVED="$BUILD/DerivedData"
INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

echo "==> Generating Notch.xcodeproj"
xcodegen generate --quiet

for scheme in Notch notch-dbcheck; do
  echo "==> Building $scheme (Release)"
  xcodebuild -project Notch.xcodeproj -scheme "$scheme" -configuration Release \
    -derivedDataPath "$DERIVED" -destination "generic/platform=macOS" CODE_SIGNING_ALLOWED=NO build -quiet
done

PRODUCTS="$DERIVED/Build/Products/Release"
rm -rf "$BUILD/Notch.app" "$BUILD/notch-dbcheck"
cp -R "$PRODUCTS/Notch.app" "$BUILD/Notch.app"
cp "$PRODUCTS/notch-dbcheck" "$BUILD/notch-dbcheck"

IDENTITY="${NOTCH_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDS="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" || true)"
  LINE="$(echo "$IDS" | grep -i theajstars | head -1)"
  [[ -z "$LINE" ]] && LINE="$(echo "$IDS" | head -1)"
  IDENTITY="$(echo "$LINE" | awk '{print $2}')"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "!! No Apple Development identity found; signing ad-hoc. Full Disk Access must be re-granted after each rebuild."
fi

echo "==> Signing with identity: $IDENTITY"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
  --identifier com.theajstars.notch.dbcheck "$BUILD/notch-dbcheck"
# Nested code first: the MediaRemote helper library that /usr/bin/perl loads.
find "$BUILD/Notch.app/Contents" -name "*.dylib" -print0 | while IFS= read -r -d '' lib; do
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$lib"
done
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
  --entitlements "$ROOT/Config/Notch.entitlements" "$BUILD/Notch.app"
codesign --verify --strict --verbose=1 "$BUILD/Notch.app"
echo "    $(codesign -dvv "$BUILD/Notch.app" 2>&1 | grep -E '^Authority=' | head -1)"

echo "==> Built $BUILD/Notch.app"
echo "    $BUILD/notch-dbcheck"

if [[ $INSTALL == 1 ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x Notch 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST/Notch.app"
  cp -R "$BUILD/Notch.app" "$DEST/Notch.app"
  echo "==> Installed $DEST/Notch.app"
  open "$DEST/Notch.app"
fi
