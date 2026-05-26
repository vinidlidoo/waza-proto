# CI integration for the test suite

**What.** Wire the locally-runnable test suite from [plan 08](../active/08-test-suite.md) into GitHub Actions so every push / PR gets the same signal Vincent gets locally — without him having to remember to run it.

**Why.** Plan 08 stops deliberately at "runs locally." Tests that only run locally rot the first time someone forgets to invoke them. CI integration is what turns a test suite from "available" into "load-bearing."

**Why not now.** Originally bundled into plan 08; split out 2026-05-26 to keep that plan focused on the harder problem (getting the tests to exist and verify regressions at all). CI is its own surface — workflow YAML, secrets, runner cost management, test reporters, branch-protection rules — worth its own scoped pass.

## Prereq

Plan 08 stages 1-5 shipped: Vitest for the token mint, XCTest pure-logic + MDK tiers, XCUITest, and Playwright all runnable locally with one command each.

## Scope (sketch — settle when scoping)

- **Workflow shape:** single `.github/workflows/test.yml` vs split (`vitest.yml`, `ios.yml`, `playwright.yml`). Lean single + matrix; revisit if jobs need wildly different `on:` triggers.
- **Free Linux runner jobs:** Vitest (token mint) on push + PR. Playwright (viewer) on PR. Both fast.
- **macOS runner jobs:** XCTest + XCUITest (iOS). PR-only, `paths: ['ios/**', 'plans/**']` gated. macOS runners cost ~10× Linux — don't burn them on docs-only PRs.
- **GitHub Actions secrets:**
  - Fake `LIVEKIT_API_SECRET` + `INVITE_SIGNING_SECRET` for Vitest (could be repo constants; secrets only if we want to mirror prod shape).
  - Real CI LiveKit creds + room name for Playwright. Probably a dedicated `waza-proto-ci` room separate from demo credentials so the test pattern never leaks into a viewer.
- **Test reporters:** junit on Vitest + Playwright; xcresult parser (e.g. `slidoapp/xcresulttool` or successor) on iOS to surface annotations in the PR check UI.
- **README updates:** how to read PR check results, what to do when a CI run is green locally but red in CI.
- **Branch protection (optional):** require these checks on `main`. Up to Vincent — strict gating vs trust-and-revert.

## Open questions (defer until picking up)

- Self-hosted macOS runner (e.g. a Mac mini Vincent owns) vs GitHub-hosted? GH-hosted is simpler but slow + metered. Self-hosted is fast + free but requires uptime + security posture.
- Playwright in CI against a Vercel preview deployment, or against a locally-served viewer fed by an in-job `lk` publisher? Preview deploy is the more honest test; local serve is faster.
- Do we want xcresult artifacts uploaded on failure (large but invaluable for debugging UI test flakes)?
- Concurrency / cancellation: cancel in-progress CI on new pushes to the same branch, yes?
