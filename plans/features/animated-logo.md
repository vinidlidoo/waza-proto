# Animated logo (pre-broadcast preview)

Forward-looking feature doc (backlog — not scheduled). Surfaced 2026-05-30.

Animate the app's logo, looping, in the center of the live preview before broadcasting starts — and
figure out what asset format to ship and how to produce it.

## Problem / motivation

The pre-broadcast state is visually dead. Today, when no preview is live, the publisher shows a
static **Waza** logo (`Image("WazaLogo")`) on a black screen — added in
[24 — full-bleed streaming UI](../completed/24-full-bleed-streaming-ui.md). A tasteful, looping
animation in the center of the preview makes that idle moment feel intentional and polished instead
of like a frozen viewfinder — a small touch that sets the tone before the stream goes live.

Two things to resolve: **what the output asset should be**, and **how to produce it** with the
tools available to a product designer as of May 2026.

## Exploration plan

### 1. What should the output asset be?

Survey the options and trade-offs for a looping logo over the publisher's preview surface in SwiftUI:

- **Lottie / Bodymovin JSON** — vector, tiny, scalable, runtime-controllable; needs the Lottie runtime.
- **Rive (`.riv`)** — interactive, state-machine driven, small.
- **Video (HEVC/H.264 with alpha, or ProRes 4444)** — pixel-perfect for complex motion; alpha
  compositing over the preview is the catch.
- **APNG / animated WebP / GIF** — simple, but quality/size/alpha trade-offs.
- **Native SwiftUI / Core Animation / Metal** — no asset at all; animate vector shapes in-engine.

Decide a primary format on: transparency over a live preview, loop seamlessness, file size, runtime
control (start/stop on broadcast), and how cleanly it composites in SwiftUI.

### 2. How to produce it (as of May 2026)

Research the current production paths for product designers:

- Motion tools (After Effects + Bodymovin/Lottie export, Rive, Figma motion, Jitter, …) and which
  export cleanly to the chosen format.
- AI-assisted motion generation — what's viable in 2026 for turning a static logo into a clean,
  loopable animation, and whether output is production-quality or just ideation.
- The handoff: what the designer delivers and how it drops into the iOS app.

## Open questions

- Do we have the logo as layered/vector source, or only the flat `WazaLogo` raster? (Drives which
  tools are usable.)
- Loop style — subtle breathing/shimmer vs. a full build-on animation?
- React to state (e.g. transition out when broadcast starts) or pure idle loop?
- Keep it lightweight so it never competes with the capture/encode pipeline.

## Dependencies / related

- Replaces/upgrades the static logo from [24 — full-bleed streaming UI](../completed/24-full-bleed-streaming-ui.md).
- Shares the pre-broadcast surface with [settings menu & mute controls](settings-and-mute-controls.md).
- Pure client-side polish; no LiveKit / serverless dependency.
