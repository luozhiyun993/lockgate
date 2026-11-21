#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
ARM_SCRATCH="$PROJECT_DIR/.build/lockgate-arm64"
INTEL_SCRATCH="$PROJECT_DIR/.build/lockgate-x86_64"
swift build -c release --disable-sandbox --disable-index-store --triple arm64-apple-macosx --scratch-path "$ARM_SCRATCH"
swift build -c release --disable-sandbox --disable-index-store --triple x86_64-apple-macosx --scratch-path "$INTEL_SCRATCH"
ARM_DIR="$ARM_SCRATCH/out/Products/Release"
INTEL_DIR="$INTEL_SCRATCH/out/Products/Release"
APP_DIR="$PROJECT_DIR/dist/Lockgate.app"
mkdir -p "$PROJECT_DIR/dist"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/dist/.lockgate-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/Lockgate.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
lipo -create "$ARM_DIR/Lockgate" "$INTEL_DIR/Lockgate" -output "$STAGED_APP/Contents/MacOS/Lockgate"
cp packaging/Info.plist "$STAGED_APP/Contents/Info.plist"
swiftc scripts/make-icon.swift -o "$PROJECT_DIR/.build/lockgate-icon-builder"
"$PROJECT_DIR/.build/lockgate-icon-builder" "$PROJECT_DIR/.build/Lockgate.iconset"
iconutil -c icns "$PROJECT_DIR/.build/Lockgate.iconset" -o "$STAGED_APP/Contents/Resources/LockgateSafe.icns"
cp "$PROJECT_DIR/.build/Lockgate.iconset/icon_256x256@2x.png" "$STAGED_APP/Contents/Resources/LockgateMascot.png"
cp "$PROJECT_DIR/.build/Lockgate.iconset/icon_512x512@2x.png" "$PROJECT_DIR/dist/lockgate-icon-preview.png"
chmod 755 "$STAGED_APP/Contents/MacOS/Lockgate"
bash scripts/fetch-core.sh
mkdir -p "$STAGED_APP/Contents/Resources/core/geo"
cp "$PROJECT_DIR/.build/core/mihomo" "$STAGED_APP/Contents/Resources/core/mihomo"
cp "$PROJECT_DIR/.build/core/geo/"* "$STAGED_APP/Contents/Resources/core/geo/"
cp packaging/THIRD-PARTY.md "$STAGED_APP/Contents/Resources/core/THIRD-PARTY.md"
codesign --force --sign "${LOCKGATE_SIGN_IDENTITY:--}" "$STAGED_APP/Contents/Resources/core/mihomo"
if [ "${LOCKGATE_WITH_FILTER:-0}" = "1" ]; then
    python3 scripts/package-filter.py "$STAGED_APP"
else
    codesign --force --deep --sign - "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"
if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$STAGING_DIR/previous.app"
fi
if ! mv "$STAGED_APP" "$APP_DIR"; then
    if [ -e "$STAGING_DIR/previous.app" ]; then
        mv "$STAGING_DIR/previous.app" "$APP_DIR"
    fi
    exit 1
fi
printf 'Built: %s\n' "$APP_DIR"
