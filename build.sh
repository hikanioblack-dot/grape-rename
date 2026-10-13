#!/bin/zsh
set -eu
cd "${0:A:h}"
output="${GRAPE_BUILD_DIR:-$PWD/dist}"
mkdir -p "$output"
stage="$(mktemp -d "${TMPDIR:-/tmp}/grape-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Grape Rename.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -target arm64-apple-macosx26.0 -module-cache-path "${TMPDIR:-/tmp}/grape-swift-module-cache" *.swift -o "$app/Contents/MacOS/GrapeRename"
cp Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
mkdir -p "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/ru.lproj"
cp -X Resources/en.lproj/InfoPlist.strings "$app/Contents/Resources/en.lproj/InfoPlist.strings"
cp -X Resources/ru.lproj/InfoPlist.strings "$app/Contents/Resources/ru.lproj/InfoPlist.strings"
xattr -cr "$app"
codesign --force --sign - "$app"
GRAPE_TEST_LANGUAGE=en "$app/Contents/MacOS/GrapeRename" --self-test
GRAPE_TEST_LANGUAGE=ru "$app/Contents/MacOS/GrapeRename" --self-test
codesign --verify --deep --strict "$app"
ditto "$app" "$output/Grape Rename.app"
ditto -c -k --norsrc --noextattr --keepParent "$app" "$output/Grape-Rename.zip"
mkdir -p "$stage/dmg"
ditto --noextattr "$app" "$stage/dmg/Grape Rename.app"
ln -s /Applications "$stage/dmg/Applications"
cp Installation.txt "$stage/dmg/Read Me.txt"
hdiutil create -volname "Grape Rename" -srcfolder "$stage/dmg" -ov -format UDZO -fs HFS+ "$output/Grape-Rename.dmg"
hdiutil verify "$output/Grape-Rename.dmg"
(cd "$output" && shasum -a 256 Grape-Rename.dmg > SHA256SUMS.txt)
