# Features roadmap

Forward-looking ideas surfaced during implementation that don't belong in the current rung but are worth tracking. One line per idea with a link. When we pick one up, move it to a `plans/active/NN-…md`.

- [ ] [CI integration for the test suite](features/ci-integration.md) — wire plan 08's locally-runnable suite into GitHub Actions: Vitest + Playwright on free Linux runners, iOS XCTest + XCUITest on macOS runners (PR-only, paths-gated). Prereq: plan 08 stages 1-5 shipped locally.
- [ ] [H.265 publish to LiveKit](features/h265-publish.md) — codec swap only (Swift SDK encoder switches H.264 → H.265, H.264 as backup); ~30-50% bitrate cut, no change to the decode-then-re-encode path. Pairs with encoded-frame ingest below.
- [ ] [Encoded-frame ingest (true HEVC pass-through)](features/encoded-frame-ingest.md) — skip in-app decode + LiveKit re-encode entirely. Path A: wait for native Swift SDK API (rust-sdks#1048, 3-6+ months + Swift port). Path B: `livekit-cli` TCP relay today.
- [ ] [Front-camera backgrounding](features/front-camera-backgrounding.md) — symmetry with glasses-source backgrounding, but Apple blocks normal apps from background camera capture; all three escape hatches (PiP / CallKit / privileged entitlement) are expensive.
