# Features roadmap

Forward-looking ideas surfaced during implementation that don't belong in the current rung but are worth tracking. One line per idea with a link. When we pick one up, move it to a `plans/active/NN-…md`.

- [ ] [CI integration for the test suite](features/ci-integration.md) — wire plan 08's locally-runnable suite into GitHub Actions: Vitest + Playwright on free Linux runners, iOS XCTest + XCUITest on macOS runners (PR-only, paths-gated). Prereq: plan 08 stages 1-5 shipped locally.
- [ ] [Audio-session-free backgrounding](features/audio-session-free-backgrounding.md) — drop plan 07's `AVAudioSession` keep-alive so phone calls / WhatsApp don't snap the publish; test whether `bluetooth-central` + `external-accessory` traffic alone is enough to keep the app un-suspended.
- [ ] [Shrink coach frame-staleness](features/coach-frame-freshness.md) — the coach answers about a frame ~1–2 s stale; close the glass→model freshness gap (pipeline latency + Gemini's 1 fps video cap + turn-start frame selection). Surfaced in plan 19; the make-or-break UX lever for the coaching epic.
- [ ] [Settings menu, mute controls & pause](features/settings-and-mute-controls.md) — top-left settings button on the iOS publisher housing mute-viewers (talk-back only; coach + wearer stay audible) and mute-my-mic (mute, not unpublish) toggles plus the relocated "Copy viewer link", and a pause control that suspends the broadcast without closing the room (plan 23).
- [ ] [Test hardening](features/test-hardening.md) — robust, systematic test strategy continuing plan 18, to cut the manual glasses→phone→browser verification every build ends in. First step: research the agent-assisted testing landscape (May 2026).
- [ ] [Animated logo](features/animated-logo.md) — looping logo animation in the center of the pre-broadcast preview (upgrades plan 24's static `WazaLogo`); explore the right output asset format and how to produce it as a product designer (May 2026).

## To-Archive

Staging area. Move checklist items here from `features.md` or `tech-debt-tracker.md` as they're retired, then ask me to migrate them — entries into [`archived/feature-archive.md`](archived/feature-archive.md), companion docs into `plans/archived/`.

_(empty)_

Retired features live in [`archived/feature-archive.md`](archived/feature-archive.md).
