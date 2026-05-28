# Pass-through self-preview

**What.** In encoded-ingest mode (plan 15 Stage 2), show the glasses-passthrough video track inside the iOS app's `LocalPreview` so the wearer sees the same feed as remote viewers.

**Why.** With `Config.glassesEncodedIngest = true`, the iPhone never decodes the HEVC bitstream — that's the architectural win. The downside is the in-app preview goes black, which is disorienting for the wearer (no way to tell if the feed is healthy without a separate viewer URL open on another device). Subscribing back to the room's video track gives a "viewer-eye" preview with no extra encode/decode on the upstream side.

**How (sketch).**
- `viewer/api/publisher-token.js`: flip `canSubscribe` from `false` to `true` on the `ios-publisher` grant.
- `RoomConnection.swift`: in encoded-ingest mode, hook `RoomDelegate.didSubscribe` (or equivalent participant track-publication observation), match on `participant.identity == "glasses-passthrough"` + `track.kind == .video`, expose as a `@Published var previewTrack: VideoTrack?` (separate from `localVideoTrack`, since this is a *remote* track).
- `ContentView.swift`: when encoded-ingest mode is active, bind `LocalPreview` to `previewTrack` instead of `localVideoTrack`. Same `VideoView` UIKit wrapper; no view-layer change beyond the source.
- Lifecycle: when `LocalParticipant` disconnects or the relay drops, the subscribed track unpublishes automatically — clear `previewTrack` on `didUnsubscribe`.

**Trade-offs.**
- **Pro:** symmetric with viewer (debug signal — freezes you see in the preview are real freezes viewers see); HW HEVC decode is cheap (way under the encode-side cost plan 15 eliminated); same audio-session keep-alive carries the subscription too.
- **Con:** preview is delayed by full round-trip (BT → DAT → TCP → relay → SFU → iPhone subscribe → decode). ~300–500 ms is plausible. Not a "live" preview.
- **Con:** extra downlink ~500 kbps on iPhone. Wi-Fi fine; cellular use cases (out of v0.x scope) would care.
- **Con:** subscription stalls when the app backgrounds. Acceptable — only foreground needs preview anyway.

**Why not now.** Cosmetic polish on top of plan 15 Stage 2; doesn't change pipeline correctness. Land the A/B measurement first so the pass-through path's quantitative wins are on record before adding any iPhone-side downlink load that could confuse future measurements.
