# Shared by the command-line build, verification, test and demo scripts.
# Keep SwiftPM's established output paths and allow selecting a compatible SDK.
export SWIFT_MODULECACHE_PATH="$PWD/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULECACHE_PATH"
mkdir -p "$SWIFT_MODULECACHE_PATH"
SWIFT_PACKAGE_ARGS=(--build-system native)
SWIFT_COMPILER_ARGS=()
if [ -n "${KENAR_SDK:-}" ]; then
    export SDKROOT="$KENAR_SDK"
    SWIFT_PACKAGE_ARGS+=(--sdk "$KENAR_SDK")
    SWIFT_COMPILER_ARGS+=(-sdk "$KENAR_SDK")
fi
