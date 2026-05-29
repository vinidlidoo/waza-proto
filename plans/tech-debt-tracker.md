# Tech debt tracker

Things knowingly deferred. One checklist item per debt with a link; full write-up (what, why deferred, what would trigger paying it down, where to start) lives in `tech-debt/{slug}.md`. Check the box when the debt is paid down.

- [ ] [iOS publisher: SwiftProtobuf duplicate class warnings](tech-debt/ios-publisher-swiftprotobuf-duplicate-warnings.md) — MWDATCore and the LiveKit SDK both static-link SwiftProtobuf, so the ObjC runtime logs dual-load warnings; benign today, vendor-side fix.
- [ ] [Glasses stream: watchdog misses EAAccessory-level disconnects](tech-debt/glasses-watchdog-eaaccessory-disconnect.md) — a BT accessory disconnect doesn't promote to DAT's session state/error streams, so `onTerminated` never fires and the UI shows "Connected" while the glasses are detached (pre-existing, plan 13; path-independent).
- [ ] [Glasses stream: background-transition reference-frame stutter](tech-debt/glasses-background-transition-stutter.md) — ~5 s of reference-missing decode errors per foreground↔background transition until the next IDR; no DAT keyframe API to shorten it.
- [ ] [RoomConnection: reconnect-on-stale-token fallback](tech-debt/roomconnection-reconnect-stale-token.md) — if the cached refresh token (10-min TTL) ages out while offline, reconnect fails to `.failed`; ~10 LOC re-connect fallback deferred until a real session reproduces it.

## To-Archive

Staging area. Move checklist items here from `tech-debt-tracker.md` or `features.md` as they're retired, then ask me to migrate them — entries into [`archived/feature-archive.md`](archived/feature-archive.md), companion docs into `plans/archived/`.

- [ ] [iOS publisher: video quality defaults](tech-debt/ios-publisher-video-quality-defaults.md) — front-camera feed uses the LiveKit SDK's stock encoding defaults (simulcast on, default bitrate/resolution); tune before any external demo or if encoder load turns thermal.
