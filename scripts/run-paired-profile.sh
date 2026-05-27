#!/usr/bin/env bash
# One-command paired profiling helper. Builds + installs the iOS app, starts
# the local viewer server, mints an invite URL, opens the browser, then captures
# iOS stdout JSONL into profiler/. Drives whichever profiling stage the app is
# currently compiled for (Stage 1, Stage 2, …).
#
# Usage:
#   ./scripts/run-paired-profile.sh
#   DEVICE_ID=<udid> ./scripts/run-paired-profile.sh
#   SKIP_BUILD=1 ./scripts/run-paired-profile.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/ios/WazaProto/WazaProto.xcodeproj"
SCHEME="${SCHEME:-WazaProto}"
CONFIGURATION="${CONFIGURATION:-Debug}"
PORT="${PORT:-4173}"
BUNDLE_ID="${BUNDLE_ID:-com.vincent.WazaProto}"
BUILD_APP="${BUILD_APP:-1}"
OPEN_VIEWER="${OPEN_VIEWER:-1}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/.build/xcode-derived}"
SERVER_PID=""

if [[ "${SKIP_BUILD:-0}" == "1" ]]; then
  BUILD_APP=0
fi

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

detect_device_id() {
  local json_path
  json_path="${TMPDIR:-/tmp}/waza-devices-$$.json"
  xcrun devicectl list devices --timeout 10 --json-output "$json_path" >/dev/null
  node - "$json_path" <<'NODE'
const fs = require('node:fs');
const path = process.argv[2];
const root = JSON.parse(fs.readFileSync(path, 'utf8'));
const seen = new Set();
const candidates = [];

function maybeDevice(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return;
  const id = value.identifier || value.udid || value.deviceIdentifier;
  const name = value.name || value.deviceProperties?.name || value.properties?.name;
  if (!id || !name || seen.has(id)) return;
  const blob = JSON.stringify(value).toLowerCase();
  const platform = String(value.hardwareProperties?.platform || value.platform || '').toLowerCase();
  const isMobile = /iphone|ipad/.test(`${name} ${platform}`.toLowerCase());
  const isSimulator = blob.includes('simulator');
  if (!isMobile || isSimulator) return;
  seen.add(id);
  candidates.push({ id, name });
}

function visit(value) {
  maybeDevice(value);
  if (!value || typeof value !== 'object') return;
  for (const child of Object.values(value)) {
    if (child && typeof child === 'object') visit(child);
  }
}

visit(root);
if (candidates.length === 1) {
  console.log(candidates[0].id);
  process.exit(0);
}
if (candidates.length === 0) {
  console.error('error: no physical iPhone/iPad found. Pass DEVICE_ID=<udid>.');
} else {
  console.error('error: multiple physical devices found. Pass DEVICE_ID=<udid>.');
  for (const device of candidates) {
    console.error(`  ${device.id}  ${device.name}`);
  }
}
process.exit(1);
NODE
}

wait_for_server() {
  local url
  url="http://127.0.0.1:$PORT/"
  for _ in {1..40}; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "error: local viewer server did not start on $url" >&2
  exit 1
}

port_is_busy() {
  nc -z "127.0.0.1" "$1" >/dev/null 2>&1
}

DEVICE_ID="${DEVICE_ID:-${1:-}}"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(detect_device_id)"
fi

mkdir -p "$REPO_ROOT/profiler"

if [[ "$BUILD_APP" != "0" ]]; then
  echo "building iOS app for device" >&2
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build

  APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION-iphoneos/WazaProto.app"
  echo "installing $APP_PATH on $DEVICE_ID" >&2
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
else
  echo "skipping build/install because BUILD_APP=0 or SKIP_BUILD=1" >&2
fi

REQUESTED_PORT="$PORT"
while port_is_busy "$PORT"; do
  PORT="$((PORT + 1))"
done
if [[ "$PORT" != "$REQUESTED_PORT" ]]; then
  echo "port $REQUESTED_PORT is busy; using http://localhost:$PORT" >&2
fi

echo "starting local viewer server on http://localhost:$PORT" >&2
(
  cd "$REPO_ROOT/viewer"
  PORT="$PORT" node "e2e/local-server.js"
) &
SERVER_PID="$!"
wait_for_server

VIEWER_URL="$(VIEWER_BASE_URL="http://localhost:$PORT" node "$REPO_ROOT/scripts/mint-viewer-invite-url.js")"
echo "viewer URL:" >&2
echo "$VIEWER_URL" >&2

if [[ "$OPEN_VIEWER" != "0" ]]; then
  open "$VIEWER_URL"
fi

echo "capturing iOS profiler logs. Press Ctrl-C here when the paired runs are done." >&2
echo "manual steps after the app is visible: select source, tap Start 3m, repeat for front camera and glasses." >&2
set +e
BUNDLE_ID="$BUNDLE_ID" "$REPO_ROOT/scripts/capture-ios-profiler-jsonl.sh" "$DEVICE_ID"
CAPTURE_STATUS="$?"
set -e

echo "latest profiler summary:" >&2
node "$REPO_ROOT/scripts/analyze-video-quality.js" || true
exit "$CAPTURE_STATUS"
