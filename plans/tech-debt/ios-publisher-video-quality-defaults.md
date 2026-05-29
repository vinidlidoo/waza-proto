# iOS publisher: video quality defaults

**What:** The iPhone front-camera feed published from the WazaProto iOS app (step #4) uses the LiveKit Swift SDK's out-of-the-box encoding defaults — simulcast on (LOW/MED/HIGH), default bitrate caps, default resolution. Subjectively the feed is "not amazing" though it functions end-to-end.

**Why deferred:** Step #4's done-criteria was "browser viewer shows the iPhone feed with sub-second latency", not "feed looks great." Tuning is premature until we know what the *final* pipeline (post-WDAT, step #5+) constrains us to.

**What would trigger paying it down:**
- Before showing the prototype to anyone outside the project.
- If WDAT integration (step #5+) reveals encoder load is a thermal/battery problem on the phone — at which point dropping simulcast or one tier would help.
- If the browser viewer's `RTCStatsReport` shows unexpected packet loss or jitter pointing to upstream bitrate.

**Where to start:** `room.localParticipant.setCamera(enabled:captureOptions:publishOptions:)` — the third arg is `VideoPublishOptions` which controls simulcast, bitrate, and codec. `CameraCaptureOptions(position:dimensions:fps:)` controls capture-side resolution and frame rate.
