#!/usr/bin/env bash
# Mint a LiveKit JWT for the waza-proto room.
# Reads LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET from .env at repo root.
# Prints only the token to stdout; pipe to pbcopy or wrap in a URL.
#
# Usage:
#   ./scripts/mint-token.sh             # viewer (default)
#   ./scripts/mint-token.sh viewer      # identity browser-viewer, subscribe-only
#   ./scripts/mint-token.sh publisher   # identity ios-publisher, publish-only

set -euo pipefail

ROLE="${1:-viewer}"

case "$ROLE" in
  viewer)
    IDENTITY="browser-viewer"
    GRANT='{"canSubscribe":true,"canPublish":false}'
    ;;
  publisher)
    IDENTITY="ios-publisher"
    GRANT='{"canSubscribe":false,"canPublish":true}'
    ;;
  *)
    echo "error: unknown role '$ROLE' (expected: viewer | publisher)" >&2
    exit 1
    ;;
esac

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
  --identity "$IDENTITY" \
  --join \
  --grant "$GRANT" \
  --valid-for 6h \
  --token-only
