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

# 1. 确保所有依赖已下载并解压到 ~/.cargo/git/checkouts
echo "==> Fetching cargo dependencies..."
cargo fetch --target "$TARGET"

# 2. 给内核注入自定义逻辑（直接在 ~/.cargo/git/checkouts 中就地 patch）
if [[ -f "$SCRIPT_DIR/patch_kernel.py" ]]; then
    python3 "$SCRIPT_DIR/patch_kernel.py"
fi

# 3. 彻底删除 target 缓存中 meow-config 及其依赖链的编译产物，逼迫 Cargo 100% 重新编译 meow-config！
echo "==> Purging meow-config, meow-api, and meow-ios-ffi artifacts from target cache..."
find "$CRATE_DIR/target" -type f \( -name "*meow_config*" -o -name "*meow-config*" -o -name "*meow_api*" -o -name "*meow-api*" -o -name "*meow_ios_ffi*" -o -name "*meow-ios-ffi*" \) -delete 2>/dev/null || true
find "$CRATE_DIR/target" -type d \( -name "*meow_config*" -o -name "*meow-config*" -o -name "*meow_api*" -o -name "*meow-api*" -o -name "*meow_ios_ffi*" -o -name "*meow-ios-ffi*" \) -exec rm -rf {} + 2>/dev/null || true
rm -f "$CRATE_DIR/target/$TARGET/$PROFILE/libmeow_ios_ffi.a"

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
