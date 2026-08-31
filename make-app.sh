#!/bin/bash
# Packages the SuperVisor SPM executable into a launchable, signed .app bundle.
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

APP_NAME="SuperVisor"
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

# Sparkle ships as a binary xcframework artifact; the bundle carries its own copy so the app
# is self-contained on machines that never built it. SPM links the framework for lookup
# beside the binary (@loader_path, where the build dir keeps a copy); in the bundle the
# binary sits in Contents/MacOS, so an added @executable_path/../Frameworks rpath is what
# resolves the embedded copy. Any absolute build-dir rpath a toolchain adds is deleted so
# the shipped binary never references paths from this machine.
FRAMEWORKS_DIR="${APP_DIR}/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE_FW" "${FRAMEWORKS_DIR}/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS_DIR}/${APP_NAME}"
while read -r RPATH; do
  [ -n "$RPATH" ] && install_name_tool -delete_rpath "$RPATH" "${MACOS_DIR}/${APP_NAME}"
done < <(otool -l "${MACOS_DIR}/${APP_NAME}" \
  | awk '/LC_RPATH/{getline; getline; sub(/^ *path /,""); sub(/ \(offset [0-9]+\)$/,""); print}' \
  | grep "/.build/" || true)

# Bundled image assets (SwarmVisor's Claude session mark, etc). NSImage renders the SVGs as
# vectors at runtime, so they stay crisp at any size.
cp Resources/*.svg "$RES_DIR/"

# SwarmVisor's Claude Code session hook. Settings copies it into ~/.claude/hooks and wires it
# into settings.json; the app compares this shipped copy against the installed one to detect a
# stale install, so it has to be present in the bundle for that check to pass.
cp Resources/supervisor-agent-hook.py "$RES_DIR/"

# Build the entitled now-playing adapter dylib that reads the system now-playing info dict
# (including artwork bytes) via the private MediaRemote C function. It ships in Resources and
# is loaded at runtime by /usr/bin/perl (an Apple-signed host that the mediaremoted
# entitlement gate admits since macOS 15.4). See NowPlayingReader.swift for the call path.
echo "==> Building MediaRemote adapter dylib…"
clang -dynamiclib -fobjc-arc -O2 \
  -framework Foundation -framework CoreFoundation \
  Sources/MediaRemoteAdapter/mediaremote_adapter.m \
  -o "${RES_DIR}/mediaremote_adapter.dylib"

# Prefer an installed Apple-issued identity so TCC grants persist across rebuilds. An
# explicit SIGNING_IDENTITY can be supplied by CI or a developer with multiple identities.
SIGN_IDENTITY="${SIGNING_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/Developer ID Application:/ { print $2; exit }')"
  if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F'"' '/Apple Development:/ { print $2; exit }')"
  fi
fi

if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
  echo "==> Ad-hoc code signing (no Apple identity found)…"
else
  echo "==> Code signing with ${SIGN_IDENTITY}…"
fi

# A real (secure) timestamp lets signatures outlive the signing certificate. Only shipped
# artifacts need one; requiring it for debug builds would put seven timestamp-server round
# trips (and a network dependency) in the inner dev loop, and ad-hoc signatures cannot be
# timestamped at all.
TIMESTAMP_FLAG="--timestamp"
if [ "$SIGN_IDENTITY" = "-" ] || [ "$CONFIG" != "release" ]; then TIMESTAMP_FLAG="--timestamp=none"; fi

# Nested code signs individually, innermost first — never --deep: deep signing stamps the
# app's entitlements onto every nested executable, which would hand Sparkle's XPC services
# the app's TCC entitlements. --preserve-metadata keeps whatever entitlements a service
# ships with, whatever a future Sparkle chooses those to be.
SPARKLE_B="${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B"
codesign --force --options runtime "$TIMESTAMP_FLAG" --preserve-metadata=entitlements \
  --sign "$SIGN_IDENTITY" "${SPARKLE_B}/XPCServices/Downloader.xpc"
codesign --force --options runtime "$TIMESTAMP_FLAG" --preserve-metadata=entitlements \
  --sign "$SIGN_IDENTITY" "${SPARKLE_B}/XPCServices/Installer.xpc"
codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$SIGN_IDENTITY" "${SPARKLE_B}/Autoupdate"
codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$SIGN_IDENTITY" "${SPARKLE_B}/Updater.app"
codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$SIGN_IDENTITY" "${FRAMEWORKS_DIR}/Sparkle.framework"
codesign --force --options runtime "$TIMESTAMP_FLAG" --sign "$SIGN_IDENTITY" "${RES_DIR}/mediaremote_adapter.dylib"

codesign --force --sign "$SIGN_IDENTITY" \
  --options runtime \
  "$TIMESTAMP_FLAG" \
  --entitlements SuperVisor.entitlements \
  --generate-entitlement-der \
  --identifier com.supervisor.SuperVisor \
  "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "==> Built ${APP_DIR}"
if [ "$RUN" = "1" ]; then
  echo "==> Launching…"
  open "$APP_DIR"
fi
