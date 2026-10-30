#!/bin/bash
# Builds zapret.app (SwiftUI, Intel and Apple Silicon, macOS 14+), its archive and the disk image of a
# release. The app carries a copy of the project: from it the app installs zapret without the Terminal.
# Run: build/app.sh [output folder, dist by default]

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "${1:-dist}" && cd "${1:-dist}" && pwd)
VERSION=$(cat "$ROOT/src/VERSION")
# shellcheck source=build/sdk.sh
. "$ROOT/build/sdk.sh"
SDK=$(app_sdk)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
APP="$OUT/zapret.app"

# the strings of the code go to $TMP/strings: every Russian one must have an English translation
mkdir -p "$TMP/strings"
for arch in arm64 x86_64; do
	xcrun swiftc -O -parse-as-library -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos14.0" \
		-emit-localized-strings -emit-localized-strings-path "$TMP/strings" \
		"$ROOT"/app/Sources/*.swift -o "$TMP/zapret-$arch"
	xcrun swiftc -O -parse-as-library -application-extension -swift-version 5 -sdk "$SDK" -target "$arch-apple-macos14.0" \
		-emit-localized-strings -emit-localized-strings-path "$TMP/strings" \
		"$ROOT"/app/Widget/*.swift -o "$TMP/widget-$arch"
done
python3 -I "$ROOT/build/l10n.py" --check "$TMP/strings"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$TMP/zapret-arm64" "$TMP/zapret-x86_64" -output "$APP/Contents/MacOS/zapret"
sed "s/@VERSION@/$VERSION/g" "$ROOT/app/Info.plist" > "$APP/Contents/Info.plist"
python3 -I "$ROOT/build/l10n.py" "$APP/Contents/Resources"
# the keys the releases are signed with, for the integrity check (Integrity.swift)
sed -n 's/^RELEASE_KEY\(_BACKUP\)\{0,1\}="\(.*\)"$/zapret \2/p' "$ROOT/src/zapret.sh" > "$APP/Contents/Resources/release-keys"
[ "$(wc -l < "$APP/Contents/Resources/release-keys")" -ge 1 ]

# the widget: an extension inside the app, sandboxed as WidgetKit requires
WIDGET="$APP/Contents/PlugIns/ZapretWidget.appex"
mkdir -p "$WIDGET/Contents/MacOS"
lipo -create "$TMP/widget-arm64" "$TMP/widget-x86_64" -output "$WIDGET/Contents/MacOS/ZapretWidget"
sed "s/@VERSION@/$VERSION/g" "$ROOT/app/Widget/Info.plist" > "$WIDGET/Contents/Info.plist"
mkdir -p "$WIDGET/Contents/Resources"
python3 -I "$ROOT/build/l10n.py" "$WIDGET/Contents/Resources"

# the project for installing without Terminal: what the repository has, without the app's own
# sources and CI. personal lists come from the template files
PAYLOAD="$APP/Contents/Resources/project"
mkdir -p "$PAYLOAD"
if git -C "$ROOT" rev-parse >/dev/null 2>&1; then
	git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- zapret.command LICENSE README.md README.en.md CHANGELOG.md CHANGELOG.en.md src lists build |
		(cd "$ROOT" && xargs -0 tar -cf -) | tar -xf - -C "$PAYLOAD"
else
	rsync -a "$ROOT/zapret.command" "$ROOT/LICENSE" "$ROOT/README.md" "$ROOT/README.en.md" "$ROOT/CHANGELOG.md" "$ROOT/CHANGELOG.en.md" \
		"$ROOT/src" "$ROOT/lists" "$ROOT/build" "$PAYLOAD/"
fi

xcrun swift "$ROOT/app/icon.swift" "$TMP/icon.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
	sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
	sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc: there is no Apple developer account; Apple Silicon runs only signed code.
# the extension first, with its sandbox entitlement, then the app around it
codesign --force -s - --entitlements "$ROOT/app/Widget/Widget.entitlements" "$WIDGET"
codesign --force -s - "$APP"
codesign -v --deep "$APP"

rm -f "$OUT/zapret-app.zip" "$OUT/zapret.dmg"
ditto -c -k --keepParent "$APP" "$OUT/zapret-app.zip"

# the disk image: the app and a shortcut to Applications to drag it onto
mkdir "$TMP/dmg"
cp -R "$APP" "$TMP/dmg/"
ln -s /Applications "$TMP/dmg/Программы"
hdiutil create -quiet -volname zapret -srcfolder "$TMP/dmg" -fs HFS+ -format UDZO -ov "$OUT/zapret.dmg"
shasum -a 256 "$OUT/zapret-app.zip" "$OUT/zapret.dmg"
