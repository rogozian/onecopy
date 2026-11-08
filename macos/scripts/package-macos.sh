#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo 'ONECOPY .app/.dmg can only be built on macOS.' >&2
  exit 1
fi
cd "$(dirname "$0")/.."
for command in swift xcrun lipo codesign hdiutil sips iconutil; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing Apple build tool: $command" >&2
    exit 1
  fi
done
swift test
# Build each target architecture independently and assemble one universal executable.
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch" --product OneCopy
  binpath="$(swift build -c release --arch "$arch" --show-bin-path)"
  test -x "$binpath/OneCopy"
  mkdir -p "dist/arch/$arch"
  cp "$binpath/OneCopy" "dist/arch/$arch/OneCopy"
done
OUT="$PWD/dist"
APP="$OUT/ONECOPY.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/lipo -create "$OUT/arch/arm64/OneCopy" "$OUT/arch/x86_64/OneCopy" -output "$APP/Contents/MacOS/OneCopy"
ARCHES="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/OneCopy")"
[[ " $ARCHES " == *" arm64 "* && " $ARCHES " == *" x86_64 "* ]] || { echo "Not a universal binary: $ARCHES" >&2; exit 1; }
cp resources/Info.plist "$APP/Contents/Info.plist"
ICONSET="$OUT/ONECOPY.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  /usr/bin/sips -s format png -z "$size" "$size" resources/ONECOPY-icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  dbl=$((size*2))
  /usr/bin/sips -s format png -z "$dbl" "$dbl" resources/ONECOPY-icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns "$ICONSET" --output "$APP/Contents/Resources/ONECOPY.icns"
# Ad-hoc signature is for test builds, not a Developer ID signature.
/usr/bin/codesign --force --options runtime --sign - "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/ONECOPY.app"
ln -s /Applications "$STAGE/Applications"
cp resources/INSTALL.txt "$STAGE/README-INSTALL.txt"
(
  cd "$OUT"
  rm -f ONECOPY-macOS-universal-QA.zip
  /usr/bin/zip -qry ONECOPY-macOS-universal-QA.zip ONECOPY.app
)
/usr/bin/hdiutil create -volname 'ONECOPY Test Build' -srcfolder "$STAGE" -ov -format UDZO "$OUT/ONECOPY-macOS-universal-unsigned-QA.dmg"
shasum -a 256 "$OUT/ONECOPY-macOS-universal-QA.zip" "$OUT/ONECOPY-macOS-universal-unsigned-QA.dmg" > "$OUT/SHA256SUMS.txt"
printf '\nApp: %s\nArchitectures: %s\nDisk image: %s\n' "$APP" "$ARCHES" "$OUT/ONECOPY-macOS-universal-unsigned-QA.dmg"
