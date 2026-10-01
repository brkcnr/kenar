#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULECACHE_PATH"
swift build --disable-sandbox --cache-path .build/cache --scratch-path .build/debug-build
ACCESSOR=".build/debug-build/$(uname -m)-apple-macosx/debug/Kenar.build/DerivedSources/resource_bundle_accessor.swift"
CHECK_SOURCES=()
for FILE in Sources/Kenar/*.swift; do
    case "$FILE" in */AppMain.swift|*/Views.swift|*/PanelController.swift) continue ;; esac
    CHECK_SOURCES+=("$FILE")
done
swiftc -swift-version 5 -parse-as-library -module-cache-path "$SWIFT_MODULECACHE_PATH" \
    "${CHECK_SOURCES[@]}" "$ACCESSOR" Scripts/VerifyAccounts.swift -lsqlite3 -o .build/kenar-verify
.build/kenar-verify "$@"
