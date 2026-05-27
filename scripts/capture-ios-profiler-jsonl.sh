#!/usr/bin/env bash
# Launch the iOS app with console attached and capture profiler JSONL lines.
#
# Usage:
#   DEVICE_ID=<udid> ./scripts/capture-ios-profiler-jsonl.sh
#   ./scripts/capture-ios-profiler-jsonl.sh <udid>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_ID="${1:-${DEVICE_ID:-}}"
BUNDLE_ID="${BUNDLE_ID:-com.vincent.WazaProto}"

if [[ -z "$DEVICE_ID" ]]; then
  echo "error: pass a device UDID as argv[1] or DEVICE_ID" >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/profiler"
OUT="$REPO_ROOT/profiler/ios-$(date -u +%Y-%m-%dT%H-%M-%SZ).jsonl"
echo "capturing profiler JSONL metric lines to $OUT" >&2

xcrun devicectl device process launch \
  --console \
  --terminate-existing \
  --device "$DEVICE_ID" \
  "$BUNDLE_ID" \
  | awk -v out="$OUT" '
      { print }
      /^\{/ && /"event":"(run_start|profile_window|run_stop)"/ {
        print >> out
        fflush(out)
      }
    '
