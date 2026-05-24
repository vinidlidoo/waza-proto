#!/usr/bin/env bash
# Join `waza-proto` room as `test-publisher` and publish a generated H.264 test pattern.
# Builds assets/testsrc.h264 (5min, 640x360, 30fps, 800kbps baseline H.264) on first run.
# `lk room join` mints its own token from the api-key/secret it reads from .env.
# Ctrl+C disconnects cleanly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
ASSET="$REPO_ROOT/assets/testsrc.h264"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found" >&2
  exit 1
fi

if [[ ! -f "$ASSET" ]]; then
  echo "generating test pattern at $ASSET (one-time)…" >&2
  mkdir -p "$(dirname "$ASSET")"
  ffmpeg -hide_banner -loglevel error \
    -f lavfi -i testsrc2=size=640x360:rate=30 \
    -t 300 \
    -c:v libx264 -preset veryfast \
    -profile:v baseline -level 3.1 -pix_fmt yuv420p \
    -g 30 -keyint_min 30 -sc_threshold 0 \
    -b:v 800k -maxrate 800k -bufsize 1600k \
    -x264-params "repeat-headers=1" \
    -f h264 "$ASSET"
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

exec lk room join \
  --room waza-proto \
  --identity test-publisher \
  --publish "$ASSET" \
  --fps 30
