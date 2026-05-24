#!/usr/bin/env bash
# Regenerate ios/WazaProto/WazaProto/Secrets.swift with the current LiveKit
# wsURL (from .env) and a fresh 6h publisher JWT (from mint-token.sh).
#
# Re-run whenever the JWT in the iOS app stops working.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
SECRETS_FILE="$REPO_ROOT/ios/WazaProto/WazaProto/Secrets.swift"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

TOKEN=$("$REPO_ROOT/scripts/mint-token.sh" publisher)

cat > "$SECRETS_FILE" <<EOF
// Gitignored. Regenerate via: ./scripts/refresh-secrets.sh
// JWT expires every 6h.

enum Secrets {
    static let wsURL = "$LIVEKIT_URL"
    static let token = "$TOKEN"
}
EOF

echo "wrote $SECRETS_FILE"
