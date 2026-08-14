#!/usr/bin/env bash
# Build meow-ios-ffi for iOS device only and pack into an XCFramework.
# Used by TestFlight CI deployment to avoid building simulator targets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CRATE_DIR="$ROOT/core/rust/meow-ios-ffi"
OUT_DIR="$ROOT/MeowCore/Frameworks"
HEADER_SRC="$CRATE_DIR/include/meow_core.h"
HEADER_DST="$ROOT/MeowCore/include/meow_core.h"

PROFILE="release"
TARGET="aarch64-apple-ios"

# Match the iOS deployment target declared in project.yml so the Rust static
# libs and the Xcode targets agree on LC_BUILD_VERSION minos.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

if ! rustup target list --installed | grep -qx "$TARGET"; then
    echo "==> Adding rust target $TARGET"
    rustup target add "$TARGET"
fi

cd "$CRATE_DIR"

echo "==> cargo build --target $TARGET (device)"
cargo build --release --target "$TARGET"

DEVICE_LIB="$CRATE_DIR/target/$TARGET/$PROFILE/libmeow_ios_ffi.a"

if [[ ! -f "$DEVICE_LIB" ]]; then
    echo "error: expected static lib missing: $DEVICE_LIB" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/MeowCore.xcframework" "$OUT_DIR/MihomoCore.xcframework"

# Ensure the header we ship to Swift matches what cbindgen emitted.
if [[ -f "$HEADER_SRC" ]]; then
    cp "$HEADER_SRC" "$HEADER_DST"
fi
# Drop the old header path if a stale copy lingers from before the rename.
rm -f "$ROOT/MeowCore/include/mihomo_core.h"

HEADERS_STAGE="$(mktemp -d)"
cp "$HEADER_DST" "$HEADERS_STAGE/meow_core.h"

echo "==> xcodebuild -create-xcframework (device only)"
xcodebuild -create-xcframework \
    -library "$DEVICE_LIB" -headers "$HEADERS_STAGE" \
    -output "$OUT_DIR/MeowCore.xcframework"

rm -rf "$HEADERS_STAGE"
echo "==> wrote $OUT_DIR/MeowCore.xcframework (device only)"
