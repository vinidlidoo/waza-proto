#!/usr/bin/env bash
# Mint a 6h LiveKit publisher JWT for the waza-proto room. Standalone dev
# utility — the iOS app fetches publisher tokens from /api/publisher-token at
# runtime (plan 10); this script is for ad-hoc CLI testing (e.g. piping into
# `lk room join --token`).
#
# Reads LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET from .env at repo
# root. Prints only the token to stdout. Viewer JWTs are minted on-demand by
# viewer/api/viewer-token.js (Vercel) and are not handled here.

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
  --grant '{"canSubscribe":false,"canPublish":true,"canPublishData":true}' \
  --valid-for 6h \
  --token-only
