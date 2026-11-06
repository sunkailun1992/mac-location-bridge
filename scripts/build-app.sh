#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIRECTORY="${1:-$PROJECT_ROOT/dist}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "CONFIGURATION must be debug or release" >&2; exit 2 ;;
esac

swift build --package-path "$PROJECT_ROOT" --configuration "$CONFIGURATION"
BIN_DIRECTORY="$(swift build --package-path "$PROJECT_ROOT" --configuration "$CONFIGURATION" --show-bin-path)"
mkdir -p "$OUTPUT_DIRECTORY"
OUTPUT_DIRECTORY="$(cd "$OUTPUT_DIRECTORY" && pwd)"
STAGING_DIRECTORY="$(mktemp -d "$OUTPUT_DIRECTORY/.locationbridge-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
STAGED_APP="$STAGING_DIRECTORY/LocationBridge.app"
APP="$OUTPUT_DIRECTORY/LocationBridge.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources/Licenses"
install -m 755 "$BIN_DIRECTORY/LocationBridge" "$STAGED_APP/Contents/MacOS/LocationBridge"
install -m 755 "$BIN_DIRECTORY/location-bridge" "$STAGED_APP/Contents/MacOS/location-bridge"
clang -fobjc-arc -framework Foundation -framework Security \
    "$PROJECT_ROOT/tools/TrustExperiment/helper.m" -o "$STAGED_APP/Contents/MacOS/locationbridge-trust"
chmod 755 "$STAGED_APP/Contents/MacOS/locationbridge-trust"
install -m 644 "$PROJECT_ROOT/scripts/Info.plist" "$STAGED_APP/Contents/Info.plist"
install -m 644 "$PROJECT_ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
install -m 644 "$PROJECT_ROOT/LICENSE" "$STAGED_APP/Contents/Resources/Licenses/LocationBridge-MIT.txt"
install -m 644 "$PROJECT_ROOT/ThirdParty/WLoc/LICENSE" "$STAGED_APP/Contents/Resources/Licenses/WLoc-MIT.txt"
install -m 644 "$PROJECT_ROOT/ThirdParty/SwiftProtobuf/LICENSE.txt" "$STAGED_APP/Contents/Resources/Licenses/SwiftProtobuf-Apache-2.0.txt"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$STAGED_APP/Contents/MacOS/location-bridge"
/usr/bin/codesign --force --sign - "$STAGED_APP/Contents/MacOS/locationbridge-trust"
/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --strict --verbose=2 "$STAGED_APP"

if [[ -e "$APP" ]]; then
    EXISTING_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EXISTING_IDENTIFIER" != "com.kellen.locationbridge" ]]; then
        echo "Refusing to replace an unrelated app at $APP" >&2
        exit 2
    fi
    # Preserve the old generated bundle instead of deleting an existing artifact.
    BACKUP_DIRECTORY="$(mktemp -d "$OUTPUT_DIRECTORY/.locationbridge-previous.XXXXXX")"
    mv "$APP" "$BACKUP_DIRECTORY/LocationBridge.app"
fi
mv "$STAGED_APP" "$APP"
echo "$APP"
