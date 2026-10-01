#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULECACHE_PATH"
swift build --disable-sandbox --cache-path .build/cache --scratch-path .build/debug-build
ACCESSOR=".build/debug-build/$(uname -m)-apple-macosx/debug/Kenar.build/DerivedSources/resource_bundle_accessor.swift"
DEMO_SOURCES=()
for FILE in Sources/Kenar/*.swift; do
    case "$FILE" in */AppMain.swift|*/PanelController.swift) continue ;; esac
    DEMO_SOURCES+=("$FILE")
done
swiftc -swift-version 5 -parse-as-library -module-cache-path "$SWIFT_MODULECACHE_PATH" \
    "${DEMO_SOURCES[@]}" "$ACCESSOR" Scripts/RenderDemo.swift -lsqlite3 -o .build/kenar-demo
DEMO_DIR=".build/demo"
mkdir -p "$DEMO_DIR"
KENAR_PREVIEW=1 .build/kenar-demo "$DEMO_DIR/kenar-demo.gif"
cp "$DEMO_DIR/kenar-demo.gif" assets/kenar-demo.gif
