#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source Scripts/SwiftEnvironment.sh
swift build "${SWIFT_PACKAGE_ARGS[@]}" --disable-sandbox --cache-path .build/cache --scratch-path .build/debug-build
ACCESSOR=".build/debug-build/$(uname -m)-apple-macosx/debug/Kenar.build/DerivedSources/resource_bundle_accessor.swift"
CHECK_SOURCES=()
for FILE in Sources/Kenar/*.swift; do
    case "$FILE" in */AppMain.swift|*/Views.swift|*/PanelController.swift) continue ;; esac
    CHECK_SOURCES+=("$FILE")
done
swiftc "${SWIFT_COMPILER_ARGS[@]}" -swift-version 5 -parse-as-library -module-cache-path "$SWIFT_MODULECACHE_PATH" \
    "${CHECK_SOURCES[@]}" "$ACCESSOR" Scripts/VerifyAccounts.swift -lsqlite3 -o .build/kenar-verify
.build/kenar-verify "$@"
