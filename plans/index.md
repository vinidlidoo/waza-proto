# Plans index

Progressive-disclosure summary of architectural plans. One line per plan with a link.

## Active

_None — next up is step #4 (iOS shell publishing the iPhone front camera)._

## Completed

- [03 — Test publisher via LiveKit CLI](completed/03-test-publisher.md) — locally-generated H.264 test pattern published via `lk room join --publish`; closed the loop on the SFU/codec/viewer pipeline before any native code.
- [02 — Browser viewer with hardcoded JWT](completed/02-browser-viewer.md) — static HTML + LiveKit JS SDK subscribing to a hardcoded room. Validated against a manually-minted token; awaits test-pattern publisher in step #3.
