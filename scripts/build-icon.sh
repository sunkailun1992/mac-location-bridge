#!/bin/sh
# Package the generated PNG into standard macOS icon representations.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE="$ROOT/Resources/AppIcon.png"
OUTPUT="$ROOT/Resources/AppIcon.icns"
ICON_TMP_BASE=${TMPDIR:-/tmp}
WORK=$(mktemp -d "${ICON_TMP_BASE%/}/locationbridge-icon.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
ICONSET="$WORK/AppIcon.iconset"
RECOVERED="$WORK/Recovered.iconset"
mkdir "$ICONSET"
width=$(/usr/bin/sips -g pixelWidth "$SOURCE" | awk '/pixelWidth:/ {print $2}')
height=$(/usr/bin/sips -g pixelHeight "$SOURCE" | awk '/pixelHeight:/ {print $2}')
if [ "$width" != 1024 ] || [ "$height" != 1024 ]; then
    printf 'AppIcon.png must be the canonical 1024 by 1024 master.\n' >&2
    exit 1
fi
while read -r name size; do
    /usr/bin/sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/$name.png" >/dev/null
done <<'SIZES'
icon_16x16 16
icon_16x16@2x 32
icon_32x32 32
icon_32x32@2x 64
icon_128x128 128
icon_128x128@2x 256
icon_256x256 256
icon_256x256@2x 512
icon_512x512 512
icon_512x512@2x 1024
SIZES
/usr/bin/iconutil --convert icns "$ICONSET" --output "$WORK/AppIcon.icns"
/usr/bin/iconutil --convert iconset "$WORK/AppIcon.icns" --output "$RECOVERED"
while read -r name size; do
    file="$RECOVERED/$name.png"
    test -f "$file"
    actual_width=$(/usr/bin/sips -g pixelWidth "$file" | awk '/pixelWidth:/ {print $2}')
    actual_height=$(/usr/bin/sips -g pixelHeight "$file" | awk '/pixelHeight:/ {print $2}')
    if [ "$actual_width" != "$size" ] || [ "$actual_height" != "$size" ]; then
        printf 'Invalid recovered representation: %s\n' "$name" >&2
        exit 1
    fi
done <<'SIZES'
icon_16x16 16
icon_16x16@2x 32
icon_32x32 32
icon_32x32@2x 64
icon_128x128 128
icon_128x128@2x 256
icon_256x256 256
icon_256x256@2x 512
icon_512x512 512
icon_512x512@2x 1024
SIZES
mv "$WORK/AppIcon.icns" "$OUTPUT"
printf 'Packaged and verified all 10 icon representations: %s\n' "$OUTPUT"
