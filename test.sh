#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULECACHE_PATH"
mkdir -p "$SWIFT_MODULECACHE_PATH"
if swift -e 'import XCTest' >/dev/null 2>&1; then
    swift test --disable-sandbox --cache-path .build/cache --scratch-path .build/debug-build
else
    swift build --disable-sandbox --cache-path .build/cache --scratch-path .build/debug-build
    ACCESSOR=".build/debug-build/arm64-apple-macosx/debug/Kenar.build/DerivedSources/resource_bundle_accessor.swift"
    if [ ! -f "$ACCESSOR" ]; then
        ACCESSOR=".build/debug-build/x86_64-apple-macosx/debug/Kenar.build/DerivedSources/resource_bundle_accessor.swift"
    fi
    CHECK_SOURCES=()
    for FILE in Sources/Kenar/*.swift; do
        case "$FILE" in */AppMain.swift|*/Views.swift|*/PanelController.swift) continue ;; esac
        CHECK_SOURCES+=("$FILE")
    done
    swiftc -swift-version 5 -parse-as-library -D KENAR_STANDALONE_TESTS -module-cache-path "$SWIFT_MODULECACHE_PATH" \
        "${CHECK_SOURCES[@]}" "$ACCESSOR" Tests/KenarTests/KenarTests.swift \
        Scripts/CheckSupport.swift Scripts/CheckRunner.swift -lsqlite3 -o .build/kenar-checks
    .build/kenar-checks
fi
