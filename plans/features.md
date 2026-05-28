# Features roadmap

Forward-looking ideas surfaced during implementation that don't belong in the current rung but are worth tracking. One line per idea with a link. When we pick one up, move it to a `plans/active/NN-…md`.

- [ ] [CI integration for the test suite](features/ci-integration.md) — wire plan 08's locally-runnable suite into GitHub Actions: Vitest + Playwright on free Linux runners, iOS XCTest + XCUITest on macOS runners (PR-only, paths-gated). Prereq: plan 08 stages 1-5 shipped locally.
- ~~H.265 publish to LiveKit~~ — folded into [plan 15 Stage 0](active/15-encoded-frame-ingest.md) as a viewer-compat prereq (no H.264 backup; v0.x subscribers are Safari/Chrome on macOS, both decode HEVC).
- ~~Encoded-frame ingest~~ — promoted to [plan 15](active/15-encoded-frame-ingest.md) on 2026-05-27. Path B (`livekit-cli` TCP relay) recommended.
- [ ] **Viewer perceptual sharpen pass** — canvas/WebGL unsharp-mask on the `<video>` output to recover apparent sharpness lost to glasses-side ISP denoising + HEVC compression (real high-freq detail is gone upstream of the iPhone; this is perceptual, not recovery). Tunable kernel size / strength / edge threshold; subjective A/B against the unsharpened baseline. Worth retuning after [plan 15](active/15-encoded-frame-ingest.md) pass-through ships, since the transcode-loss component disappears and the source picture shifts.
- [ ] [Audio-session-free backgrounding](features/audio-session-free-backgrounding.md) — drop plan 07's `AVAudioSession` keep-alive so phone calls / WhatsApp don't snap the publish; test whether `bluetooth-central` + `external-accessory` traffic alone is enough to keep the app un-suspended.
- [ ] [Front-camera backgrounding](features/front-camera-backgrounding.md) — symmetry with glasses-source backgrounding, but Apple blocks normal apps from background camera capture; all three escape hatches (PiP / CallKit / privileged entitlement) are expensive.
