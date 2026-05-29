# Feature archive

Ideas retired from [`plans/features.md`](../features.md) — kept for provenance. Companion write-ups live alongside this file in `plans/archived/`.

- [ ] **Viewer perceptual sharpen pass** — canvas/WebGL unsharp-mask on the `<video>` output to recover apparent sharpness lost to glasses-side ISP denoising + HEVC compression (real high-freq detail is gone upstream of the iPhone; this is perceptual, not recovery). Tunable kernel size / strength / edge threshold; subjective A/B against the unsharpened baseline. Worth retuning after [plan 15](../completed/15-encoded-frame-ingest.md) pass-through ships, since the transcode-loss component disappears and the source picture shifts.
- [ ] [Front-camera backgrounding](front-camera-backgrounding.md) — symmetry with glasses-source backgrounding, but Apple blocks normal apps from background camera capture; all three escape hatches (PiP / CallKit / privileged entitlement) are expensive.
- [ ] [Pass-through self-preview](passthrough-self-preview.md) — surfaced by plan 15 Stage 2: in encoded-ingest mode the in-app preview is black (no local decode by design). Subscribe back to the `glasses-passthrough` track so the wearer sees the same feed as viewers. ~300–500ms delayed; HW HEVC decode is cheap.
