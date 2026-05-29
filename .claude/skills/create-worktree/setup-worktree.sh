#!/usr/bin/env bash
# Create and fully provision a waza-proto git worktree.
#
# A fresh worktree is missing every gitignored file, so it neither builds nor
# tests until they're restored: .env + Secrets.swift (iOS build),
# viewer/node_modules (viewer test tiers), assets/testsrc.h264 (e2e tier).
# This script restores them all and handles the already-exists-branch case.
# Idempotent — safe to re-run to re-provision an existing worktree.
#
# Usage: setup-worktree.sh <branch> [worktree-path]
#
# IMPORTANT: run with the sandbox DISABLED — it creates a sibling directory
# outside the repo and `npm ci` needs the network; both fail when sandboxed.
set -euo pipefail

BRANCH="${1:?usage: setup-worktree.sh <branch> [worktree-path]}"

# Resolve the MAIN worktree root via git so this works no matter where it runs
# from — the shared .git "common dir" always lives in the primary worktree.
MAIN_ROOT="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd)"
REPO_NAME="$(basename "$MAIN_ROOT")"
SAFE_BRANCH="${BRANCH//\//-}"                       # slashes → dashes for the dir name
WT_PATH="${2:-$(dirname "$MAIN_ROOT")/${REPO_NAME}-${SAFE_BRANCH}}"

echo "main:     $MAIN_ROOT"
echo "branch:   $BRANCH"
echo "worktree: $WT_PATH"
echo

[ -f "$MAIN_ROOT/.env" ] || { echo "FATAL: $MAIN_ROOT/.env missing — can't provision secrets." >&2; exit 1; }

# 1. Worktree — guard the already-exists branch + path cases. A prior sandboxed
#    `git worktree add` can fail AFTER creating the ref, leaving an orphan branch.
if [ -e "$WT_PATH" ]; then
    echo "→ worktree path exists; re-provisioning in place"
elif git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "→ branch '$BRANCH' already exists; attaching worktree to it"
    git -C "$MAIN_ROOT" worktree add "$WT_PATH" "$BRANCH"
else
    echo "→ creating branch '$BRANCH' + worktree"
    git -C "$MAIN_ROOT" worktree add -b "$BRANCH" "$WT_PATH"
fi

# 2. Root .env — symlink (never copy) so secret rotations from main propagate.
ln -sf "$MAIN_ROOT/.env" "$WT_PATH/.env"
echo "✓ .env → main"

# 3. iOS Secrets.swift — regenerated from .env (gitignored, per-worktree).
( cd "$WT_PATH" && bash scripts/refresh-secrets.sh )

# 4. Viewer. npm ci is required by BOTH test tiers (vitest/playwright binaries).
#    viewer/.env* are only for `vercel dev` — the test tiers read the ROOT .env.
ln -sf "$MAIN_ROOT/.env" "$WT_PATH/viewer/.env"
ln -sf .env "$WT_PATH/viewer/.env.local"
if [ -d "$WT_PATH/viewer/node_modules" ]; then
    echo "✓ viewer/node_modules present (skipping npm ci)"
else
    ( cd "$WT_PATH/viewer" && npm ci )
fi

# 5. e2e asset (30 MB, gitignored — the whole assets/ dir is) — symlink from main.
mkdir -p "$WT_PATH/assets"
if [ -f "$MAIN_ROOT/assets/testsrc.h264" ]; then
    ln -sf "$MAIN_ROOT/assets/testsrc.h264" "$WT_PATH/assets/testsrc.h264"
    echo "✓ assets/testsrc.h264 → main"
else
    echo "⚠ main has no assets/testsrc.h264 — generate it (scripts/publish-test-pattern.sh) for the Playwright e2e tier"
fi

echo
echo "Done. Worktree ready at: $WT_PATH"
echo "Next:"
echo "  cd \"$WT_PATH\""
echo "  just test-detail        # all four tiers   (e2e publishes to the live room)"
echo "  open ios/WazaProto/WazaProto.xcodeproj"
