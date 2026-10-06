#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP_NAME="Kenar"
DIST="${KENAR_DIST:-dist}"
APP="$DIST/$APP_NAME.app"
source Scripts/SwiftEnvironment.sh
swift "${SWIFT_COMPILER_ARGS[@]}" Scripts/MakeIcon.swift assets/AppIcon-source.png .build/AppIcon.iconset .build/AppIcon.icns
swift build "${SWIFT_PACKAGE_ARGS[@]}" --disable-sandbox --cache-path .build/cache -c release --triple arm64-apple-macosx
swift build "${SWIFT_PACKAGE_ARGS[@]}" --disable-sandbox --cache-path .build/cache -c release --triple x86_64-apple-macosx
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/Kenar .build/x86_64-apple-macosx/release/Kenar -output "$APP/Contents/MacOS/Kenar"
cp -R Sources/Kenar/Resources/. "$APP/Contents/Resources/"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE UPSTREAM.md THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Kenar</string>
<key>CFBundleDisplayName</key><string>Kenar</string>
<key>CFBundleIdentifier</key><string>local.kenar.usage</string>
<key>CFBundleVersion</key><string>12</string>
<key>CFBundleShortVersionString</key><string>1.5.2</string>
<key>CFBundleExecutable</key><string>Kenar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>tr</string>
<key>CFBundleLocalizations</key><array><string>tr</string><string>en</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><false/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
DMG_ROOT="$DIST/dmgroot"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -sfn /Applications "$DMG_ROOT/Applications"
if ! hdiutil create -volname Kenar -srcfolder "$DMG_ROOT" -ov -format UDZO "$DIST/Kenar.dmg"; then
    # makehybrid + convert works without attaching a writable disk device,
    # useful in sandboxed build environments with no DiskManagement service.
    hdiutil makehybrid -hfs -hfs-volume-name Kenar -o "$DIST/Kenar-hybrid.dmg" "$DMG_ROOT"
    hdiutil convert "$DIST/Kenar-hybrid.dmg" -format UDZO -ov -o "$DIST/Kenar.dmg"
    rm -f "$DIST/Kenar-hybrid.dmg"
fi
hdiutil verify "$DIST/Kenar.dmg"
rm -rf "$DMG_ROOT"
echo "Hazır: $APP ve $DIST/Kenar.dmg"
