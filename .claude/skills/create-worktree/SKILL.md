---
name: create-worktree
description: Create and fully provision a git worktree for waza-proto so a fresh branch checkout builds and tests cleanly. Restores the gitignored files that don't carry over (.env, Secrets.swift, viewer/node_modules, assets/testsrc.h264), handles an already-existing branch, and runs with the sandbox off. Use when starting work on a branch in a separate worktree.
---

# create-worktree

Run the setup script **with the sandbox disabled** (it creates a sibling dir outside the repo and `npm ci` needs the network):

```bash
bash .claude/skills/create-worktree/setup-worktree.sh <branch> [worktree-path]
```

Default path: `<parent>/waza-proto-<branch>`. Idempotent — re-run to re-provision an existing worktree.

## What it does

1. `git worktree add` — creates the branch, or attaches if it already exists.
2. `.env` → symlink to main's (rotations propagate; never copied).
3. `scripts/refresh-secrets.sh` → regenerates `ios/.../Secrets.swift`.
4. `viewer/`: `npm ci` + `.env`/`.env.local` symlinks.
5. `assets/testsrc.h264` (30 MB, gitignored) → symlink from main.

## Gotchas (one per failure I actually hit)

- **Sandbox must be OFF.** `git worktree add` writes a sibling dir outside the repo and `npm ci` hits the network — both fail under the default sandbox. Same for the script's git/npm steps.
- **`.env` + `Secrets.swift` are gitignored** → a fresh worktree won't build (`cannot find 'Secrets' in scope`) until steps 2–3 run. `refresh-secrets.sh` does nothing without `.env`, so the symlink comes first.
- **`viewer/node_modules` is gitignored** → without `npm ci`, `just test-detail`'s viewer tiers die with `vitest`/`playwright: command not found`, and the catalog prints **empty** Vitest/Playwright sections while every iOS test still passes — looks like an iOS failure but isn't.
- **`assets/testsrc.h264` is gitignored** (the whole `assets/` dir is) → the Playwright e2e tier errors without it. If main lacks it too, regenerate via `scripts/publish-test-pattern.sh`.
- **The branch may already exist** — a prior sandboxed `git worktree add` can fail *after* creating the ref, leaving an orphan branch. The script guards with `git show-ref` and attaches instead of erroring.
- **iOS tests use default signing** — `just test-detail` / `xcodebuild test` work as-is. Add `CODE_SIGN_IDENTITY="-"` **only** if you hit the `Call configure() before … Wearables!` bootstrap fatal, and **never** pass `CODE_SIGNING_ALLOWED=NO` (that's what triggers it — meta-wearables-dat-ios#197).
- **Viewer `.env`/`.env.local` are only for `vercel dev`** — the test tiers load the *root* `.env`. Set up anyway; harmless.

## Teardown

```bash
git worktree remove <worktree-path>     # --force if it has uncommitted/untracked junk
```
