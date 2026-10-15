#!/bin/sh
# Xcode build step: builds the Rust server (rust/) and puts it inside the app (Contents/Resources/vacuumd).
# Release builds contain both Apple Silicon and Intel code (when both Rust targets are installed:
# rustup target add x86_64-apple-darwin aarch64-apple-darwin); Debug builds only the Mac you are on.
# Without Rust installed the app still builds; it then looks for vacuumd in ~/Library/Application Support/Vacuum/bin.
set -e
# Xcode sets this to the app's own (very new) macOS; the server inside should run on older Macs too.
export MACOSX_DEPLOYMENT_TARGET=11.0
export PATH="/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
    echo "warning: Rust (cargo) not found, so vacuumd is not bundled in the app. Install Rust from https://rustup.rs"
    exit 0
fi

cd "$SRCROOT/rust"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST"

installed=$(rustup target list --installed 2>/dev/null || true)
if [ "$CONFIGURATION" = "Release" ] && echo "$installed" | grep -q x86_64-apple-darwin && echo "$installed" | grep -q aarch64-apple-darwin; then
    cargo build --release --quiet --target x86_64-apple-darwin
    cargo build --release --quiet --target aarch64-apple-darwin
    lipo -create -output "$DEST/vacuumd" target/x86_64-apple-darwin/release/vacuumd target/aarch64-apple-darwin/release/vacuumd
    codesign --force --sign - "$DEST/vacuumd"  # lipo drops the signature, and Apple Silicon refuses unsigned code
else
    [ "$CONFIGURATION" = "Release" ] && echo "warning: building vacuumd for this Mac only; run: rustup target add x86_64-apple-darwin aarch64-apple-darwin"
    cargo build --release --quiet
    cp target/release/vacuumd "$DEST/vacuumd"
fi

# On incremental builds Xcode keeps the old signature of the app while vacuumd inside it changed,
# which makes the app look tampered with. Refresh the (ad-hoc) signature in that case.
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
if [ "$CODE_SIGN_IDENTITY" = "-" ] && [ -f "$APP/Contents/Info.plist" ]; then
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi
