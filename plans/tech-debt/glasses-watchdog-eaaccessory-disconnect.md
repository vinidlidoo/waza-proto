# Glasses stream: watchdog misses EAAccessory-level disconnects

**What:** A Bluetooth accessory disconnect of the Ray-Ban glasses (the `EAAccessory`-level event) doesn't promote to DAT's `DeviceSession.stateStream` / `errorStream`, so the app's `onTerminated` teardown never fires. The UI keeps showing "Connected" while the glasses are physically detached. Path-independent — it affects both the shipped re-encode path and the flag-gated pass-through path identically.

**Why deferred:** Pre-existing since plan 13, which wired the *in-SDK* teardown paths (hinge-fold, session-terminated → `stateStream`/`errorStream` → `onTerminated`) but not the separate `EAAccessory` disconnect notification source. The common teardown paths already fire correctly; this is the rarer "BT link drops without an accompanying SDK state transition" case. Surfaced again during the plans 15–17 encoded-mode work, but it predates and outlives that decision.

**What would trigger paying it down:** A session where the glasses disconnect at the BT-accessory level (e.g. out of range, powered off) and the UI stays stuck on "Connected" with a frozen last frame — particularly if it confuses a demo or a real wearer.

**Where to start:** Plan 13's teardown wiring in `plans/completed/13-glasses-disconnected-status.md`. Add an `EAAccessoryManager` / `EAAccessoryDidDisconnect` (NotificationCenter) observer that drives the same `onTerminated` path the SDK streams use, so the UI reflects the detach regardless of whether DAT emits a state transition.
