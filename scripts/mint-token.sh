#!/usr/bin/env bash
# Mint a LiveKit JWT for the browser viewer.
# Reads LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET from .env at repo root.
# Prints only the token to stdout; pipe to pbcopy or wrap in a URL.

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
  --identity browser-viewer \
  --join \
  --grant '{"canSubscribe":true,"canPublish":false}' \
  --valid-for 6h \
  --token-only
