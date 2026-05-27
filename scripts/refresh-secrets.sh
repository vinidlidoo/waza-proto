#!/usr/bin/env bash
# Regenerate ios/WazaProto/WazaProto/Secrets.swift from .env.
#
# Writes only the long-lived HS256 signing secrets the app needs to mint
# short-lived JWTs at runtime (viewer invites + publisher tokens). LiveKit
# wsURL and publisher JWT are no longer baked in — the app fetches both
# from the Vercel /api/publisher-token endpoint at connect time.

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

cat > "$SECRETS_FILE" <<EOF
// Gitignored. Regenerate via: ./scripts/refresh-secrets.sh

enum Secrets {
    // Shared HS256 secret with Vercel env var INVITE_SIGNING_SECRET. Used to
    // sign per-invite JWTs that gate the viewer mint endpoint.
    static let inviteSigningSecret = "$INVITE_SIGNING_SECRET"
    // Shared HS256 secret with Vercel env var PUBLISHER_SIGNING_SECRET. Used
    // to sign short-lived envelopes that gate the publisher mint endpoint.
    static let publisherSigningSecret = "$PUBLISHER_SIGNING_SECRET"
}
EOF

echo "wrote $SECRETS_FILE"
