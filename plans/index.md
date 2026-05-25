# Plans index

Progressive-disclosure summary of architectural plans. One line per plan with a link.

## Active

_None — v0.05 shipped._

## Completed

- [05 — Glasses frames via WDAT, published through LiveKit](completed/05-wdat-glasses-frames.md) — swapped iPhone front camera for Ray-Ban Meta POV via DAT v0.7; frame bridge `videoFramePublisher.listen { capturer.capture($0.sampleBuffer) }`; live source swap, hinge-fold teardown, Developer Mode credentials. Closes v0.05.
- [04 — iOS shell publishing the iPhone front camera](completed/04-ios-front-camera.md) — minimal SwiftUI app; LiveKit Swift SDK 2.14.1; `setCamera(enabled:captureOptions:)` publishes the front camera to `waza-proto` room; browser viewer confirmed end-to-end.
- [03 — Test publisher via LiveKit CLI](completed/03-test-publisher.md) — locally-generated H.264 test pattern published via `lk room join --publish`; closed the loop on the SFU/codec/viewer pipeline before any native code.
- [02 — Browser viewer with hardcoded JWT](completed/02-browser-viewer.md) — static HTML + LiveKit JS SDK subscribing to a hardcoded room. Validated against a manually-minted token; awaits test-pattern publisher in step #3.
