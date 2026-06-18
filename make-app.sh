#!/bin/bash
# Packages the DynamicLake SPM executable into a launchable, ad-hoc-signed .app bundle.
#
# Why a bundle: the privacy permission grants (Location, Calendar, Accessibility,
# Bluetooth, Notifications) only persist when macOS can identify a stable, signed bundle.
# A bare `swift run` binary gets a fresh identity each launch and the grants never stick.
#
# Usage:  ./make-app.sh [--release] [--run]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="debug"
RUN=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --run)     RUN=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

APP_NAME="DynamicLake"
APP_DIR="build/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

echo "==> Building (${CONFIG})…"
if [ "$CONFIG" = "release" ]; then
  swift build -c release
else
  swift build
fi
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"

echo "==> Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN_PATH" "${MACOS_DIR}/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

# Build the entitled now-playing adapter dylib that reads the system now-playing info dict
# (including artwork bytes) via the private MediaRemote C function. It ships in Resources and
# is loaded at runtime by /usr/bin/perl (an Apple-signed host that the mediaremoted
# entitlement gate admits since macOS 15.4). See NowPlayingReader.swift for the call path.
echo "==> Building MediaRemote adapter dylib…"
clang -dynamiclib -fobjc-arc -O2 \
  -framework Foundation -framework CoreFoundation \
  Sources/MediaRemoteAdapter/mediaremote_adapter.m \
  -o "${RES_DIR}/mediaremote_adapter.dylib"

# Ad-hoc sign so macOS assigns a stable code identity (required for TCC permission grants).
echo "==> Ad-hoc code signing…"
codesign --force --deep --sign - \
  --options runtime \
  --identifier com.dynamiclake.DynamicLake \
  "$APP_DIR"
codesign --verify --verbose "$APP_DIR"

echo "==> Built ${APP_DIR}"
if [ "$RUN" = "1" ]; then
  echo "==> Launching…"
  open "$APP_DIR"
fi
