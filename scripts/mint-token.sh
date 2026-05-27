#!/usr/bin/env bash
# Mint the iOS publisher's long-lived LiveKit JWT for the waza-proto room.
# Reads LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET from .env at repo root.
# Prints only the token to stdout. Called by scripts/refresh-secrets.sh.
#
# Viewer JWTs are minted on-demand by viewer/api/viewer-token.js (Vercel) —
# gated by per-invite HS256 tokens; not handled here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

lk token create \
  --room waza-proto \
  --identity ios-publisher \
  --join \
  --grant '{"canSubscribe":false,"canPublish":true}' \
  --valid-for 6h \
  --token-only
