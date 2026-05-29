---
name: merge-worktree
description: Merge a waza-proto feature worktree's branch into main via PR and tear it all down (worktree, directory, branch local+remote, main synced). Handles the divergence/teardown-ordering/force gotchas. Use when a branch worked on in a separate worktree is done and ready to land.
---

# merge-worktree

Run **with the sandbox disabled** (push/`gh` need network + keychain; teardown touches a sibling dir):

```bash
bash .claude/skills/merge-worktree/merge-worktree.sh <branch> [pr-title]
```

Does: push branch → PR (reuses an open one, else creates a minimal one) → merge → fast-forward local `main` → remove worktree + delete branch (local **and** remote) → prune. Stops before any outward action if the state is wrong. For a meaningful PR description, run `gh pr create` yourself first — the script then reuses it.

## Before you run this: land the branch on main first

The script merges the branch **as-is** — it does not sync with main. If the branch is behind `main` with overlapping edits, `gh pr merge` conflicts. Sync + verify in the worktree first (where you can build + test):

```bash
git fetch origin
git rebase origin/main        # NOT interactive (only `-i` is); pauses per conflicting commit
# resolve markers → git add <file> → GIT_EDITOR=true git rebase --continue
just test-ios-unit            # + viewer tier — verify the merged result
git push --force-with-lease
```

Rather not rewrite history? `git merge origin/main` instead: one stop, all conflicts at once, no force-push (trade: a merge commit).

## What it does

1. Pre-flight (stops early): main worktree on `main`; local `main` not ahead of `origin/main`; target worktree clean.
2. `git push -u origin <branch>`.
3. `gh pr create` (if none) → `gh pr merge --merge`.
4. `git fetch` + `git merge --ff-only origin/main`.
5. `git worktree remove --force` → `git branch -d` → `git push origin --delete` → `git worktree prune`.

## Gotchas (one per footgun I actually hit)

- **Sandbox must be OFF.** Push/`gh` need the network and the keychain credential helper; removing the worktree touches a dir outside the repo. All fail sandboxed.
- **Direct push to `main` is blocked by the auto-mode classifier** — needs your explicit OK. The script never pushes main; if local `main` is ahead of origin it **stops** and tells you to push first.
- **Local `main` ahead of `origin/main` → the PR merge diverges local main**, and `git merge --ff-only` then fails. Push `main` first so `origin == local` before merging. (This bites when plan-docs/skill commits accumulate on local main between worktrees.)
- **Can't delete a branch that's checked out in a worktree** → remove the **worktree first**, then delete the branch. The script orders it this way; `gh pr merge --delete-branch` does the opposite and fails, so the script merges without it and deletes explicitly.
- **`git worktree remove` needs `--force`** — the worktree's `Secrets.swift`, `viewer/node_modules`, and `.env`/asset symlinks are untracked, so a plain remove refuses.
- **Run teardown from `main`, never inside the worktree** — you can't remove a worktree you're `cd`'d into. The script `cd`s to the main root (resolved via `git rev-parse --git-common-dir`, so it's path-independent).
- **Repo merges via merge commits** (`--merge`, matching PRs #2/#3/#6), not squash.
- **Plain `git rebase` isn't interactive** (only `-i` is), but `--continue`/`commit`/`merge` may open an editor mid-flow — prefix `GIT_EDITOR=true` so they never block.

## Sibling skill

[create-worktree](../create-worktree/SKILL.md) sets one up; this tears it down.
