#!/usr/bin/env bash
# Plan 15 stage 2 relay: pull HEVC Annex-B from the iPhone's TCP listener and
# publish it to the waza-proto LiveKit room as a separate participant
# (identity=`glasses-passthrough`) — no re-encode, h265 stays h265 end-to-end.
#
# Two-participant model: the iPhone publishes audio-only (mic keep-alive); this
# relay publishes video-only. The viewer subscribes to both via auto-subscribe.
#
# Order of operations:
#   1. iPhone: tap Connect (with Config.glassesEncodedIngest = true).
#      Don glasses; TCP listener on port 16400 starts serving once the first
#      frame fires.
#   2. Mac: run this script with the iPhone's LAN IP.
#   3. Viewer: open invite URL.
#
# `lk room join` mints its own token from .env (LIVEKIT_URL / API_KEY / SECRET).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

IPHONE_IP="${1:-}"
if [[ -z "$IPHONE_IP" ]]; then
  echo "usage: $0 <iphone-lan-ip>" >&2
  echo "example: $0 192.168.0.13" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

PORT="${GLASSES_INGEST_PORT:-16400}"

exec lk room join \
  --room waza-proto \
  --identity glasses-passthrough \
  --publish "h265://${IPHONE_IP}:${PORT}"
