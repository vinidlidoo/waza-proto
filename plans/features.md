# Features roadmap

Forward-looking ideas surfaced during implementation that don't belong in the current rung but are worth tracking. One line per idea with a link. When we pick one up, move it to a `plans/active/NN-…md`.

- [ ] [CI integration for the test suite](features/ci-integration.md) — wire plan 08's locally-runnable suite into GitHub Actions: Vitest + Playwright on free Linux runners, iOS XCTest + XCUITest on macOS runners (PR-only, paths-gated). Prereq: plan 08 stages 1-5 shipped locally.
- [ ] [Audio-session-free backgrounding](features/audio-session-free-backgrounding.md) — drop plan 07's `AVAudioSession` keep-alive so phone calls / WhatsApp don't snap the publish; test whether `bluetooth-central` + `external-accessory` traffic alone is enough to keep the app un-suspended.

## To-Archive

Staging area. Move checklist items here from `features.md` or `tech-debt-tracker.md` as they're retired, then ask me to migrate them — entries into [`archived/feature-archive.md`](archived/feature-archive.md), companion docs into `plans/archived/`.

_(empty)_

Retired features live in [`archived/feature-archive.md`](archived/feature-archive.md).
