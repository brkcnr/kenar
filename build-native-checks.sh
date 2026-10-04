#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source Scripts/SwiftEnvironment.sh
mkdir -p "$SWIFT_MODULECACHE_PATH"
swift build "${SWIFT_PACKAGE_ARGS[@]}" --disable-sandbox --cache-path .build/cache --scratch-path .build/debug-build
ACCESSOR=".build/debug-build/arm64-apple-macosx/debug/Kenar.build/DerivedSources/resource_bundle_accessor.swift"
if [ ! -f "$ACCESSOR" ]; then ACCESSOR=".build/debug-build/x86_64-apple-macosx/debug/Kenar.build/DerivedSources/resource_bundle_accessor.swift"; fi
CHECK_SOURCES=()
for FILE in Sources/Kenar/*.swift; do
    case "$FILE" in */AppMain.swift|*/Views.swift|*/PanelController.swift) continue ;; esac
    CHECK_SOURCES+=("$FILE")
done
swiftc "${SWIFT_COMPILER_ARGS[@]}" -swift-version 5 -parse-as-library -D KENAR_STANDALONE_TESTS -module-cache-path "$SWIFT_MODULECACHE_PATH" \
    "${CHECK_SOURCES[@]}" "$ACCESSOR" Tests/KenarTests/KenarTests.swift \
    Scripts/CheckSupport.swift Scripts/CheckRunner.swift -lsqlite3 -o .build/kenar-checks
APP=".build/Kenar Native Checks 1.5.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/kenar-checks "$APP/Contents/MacOS/KenarChecks15"
cp -R Sources/Kenar/Resources/. "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.kenar.checks.v15</string>
<key>CFBundleName</key><string>Kenar Native Checks</string>
<key>CFBundleExecutable</key><string>KenarChecks15</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Open $APP to run 75 checks, including the WebKit DOM fixture. Results: .build/native-tests.log"
