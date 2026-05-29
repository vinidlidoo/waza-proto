#!/usr/bin/env bash
# Merge a waza-proto feature worktree's branch via PR, then tear everything down.
#
# Flow: push branch → PR (reuse or create) → merge → sync main (ff-only) →
# remove worktree + branch (local + remote). Stops before any outward/destructive
# action if the state is wrong (main ahead of origin, dirty worktree, not on main).
#
# Usage: merge-worktree.sh <branch> [pr-title]   (run from anywhere in the repo)
#
# IMPORTANT: run with the sandbox DISABLED — push/gh need the network + the
# keychain credential helper, and worktree removal touches a sibling dir.
set -euo pipefail

BRANCH="${1:?usage: merge-worktree.sh <branch> [pr-title]}"
TITLE="${2:-$BRANCH}"

# Resolve the MAIN worktree via git so this works from any worktree.
MAIN_ROOT="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd)"
cd "$MAIN_ROOT"

# Find the branch's worktree (to tear it down, and so we never run from inside it).
WT_PATH="$(git worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '
    /^worktree /{p=substr($0,10)} /^branch /{ if ($2==b) print p }')"

echo "main:     $MAIN_ROOT"
echo "branch:   $BRANCH"
echo "worktree: ${WT_PATH:-<none>}"
echo

git fetch origin --quiet --prune

# --- Pre-flight: stop BEFORE any outward/destructive action -----------------
CURRENT="$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)"
[ "$CURRENT" = "main" ] || { echo "STOP: main worktree is on '$CURRENT', not main." >&2; exit 1; }

# Local main ahead of origin → merging the PR would diverge local main. Push
# main first (a direct push to main needs your explicit OK; the classifier
# blocks it otherwise) so origin == local before the merge.
if [ -n "$(git log --oneline origin/main..main)" ]; then
    echo "STOP: local main is ahead of origin/main — merging would diverge it." >&2
    echo "      Push main first:  git push origin main" >&2
    git log --oneline origin/main..main >&2
    exit 1
fi

# Don't push/merge/delete a branch with uncommitted work in its worktree.
if [ -n "$WT_PATH" ] && [ -n "$(git -C "$WT_PATH" status --porcelain)" ]; then
    echo "STOP: worktree has uncommitted changes — commit or stash first:" >&2
    git -C "$WT_PATH" status --short >&2
    exit 1
fi

# --- Push → PR → merge ------------------------------------------------------
git push -u origin "$BRANCH"

PR_STATE="$(gh pr view "$BRANCH" --json state -q .state 2>/dev/null || echo NONE)"
if [ "$PR_STATE" = "NONE" ]; then
    echo "→ no PR for $BRANCH; creating a minimal one (prefer hand-writing it — see SKILL.md)"
    gh pr create --base main --head "$BRANCH" --title "$TITLE" \
        --body "Merging \`$BRANCH\`."$'\n\n'"🤖 via merge-worktree skill"
fi
if [ "$PR_STATE" != "MERGED" ]; then
    gh pr merge "$BRANCH" --merge   # repo convention is merge commits, not squash
fi

# --- Sync main (ff-only; if this fails, main diverged — see pre-flight) -----
git fetch origin --prune
git merge --ff-only origin/main

# --- Teardown: worktree BEFORE branch (can't delete a checked-out branch) ---
if [ -n "$WT_PATH" ] && [ -e "$WT_PATH" ]; then
    # --force: the worktree's Secrets.swift / node_modules / .env+asset symlinks
    # are untracked, so a plain remove refuses.
    git worktree remove --force "$WT_PATH"
fi
git branch -d "$BRANCH" 2>/dev/null || git branch -D "$BRANCH"
git push origin --delete "$BRANCH" 2>/dev/null || true   # no-op if the merge already deleted it
git worktree prune

echo
echo "Done. $BRANCH merged + synced into main; worktree + branch (local + remote) removed."
git worktree list
