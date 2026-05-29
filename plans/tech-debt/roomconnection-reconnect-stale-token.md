# RoomConnection: reconnect-on-stale-token fallback

**What:** If the iOS app stays disconnected from LiveKit long enough for the server-pushed cached refresh token (10-min TTL) to age out, the SDK's automatic reconnect will fail with an auth error and the room ends up in `.failed`. The fix is small — catch the failed reconnect and call `connect()` again, which re-mints a fresh publisher JWT via `/api/publisher-token`.

**Why deferred:** Plan 10 closed out without ever observing this in practice. The risk only materializes if the app sits backgrounded *without network* for >10 min and then tries to reconnect. Real backgrounded sessions on cellular/wifi keep the WebSocket alive and the server keeps pushing fresh refresh tokens, so the cache never goes stale. Adding the fallback now would be speculative — wait for a real session log showing the failure mode.

**What would trigger paying it down:** A glasses session where `RoomConnection.Status` flips to `.failed("…401…")` (or another auth-shaped error) after a long backgrounded period, ideally with an iOS console log capturing which exact LiveKit reconnect path failed.

**Where to start:** `RoomConnection.swift` — extend the `RoomDelegate` handling to detect `Room.didDisconnect` with reason `.tokenExpired` (or an auth-marker in the underlying error string) and call `connect(source:, glasses:)` instead of surfacing as `.failed`. Roughly ~10 LOC. Stage 3 of plan 10 was scoped for this and explicitly skipped — full finding in `plans/completed/10-jwt-auto-refresh.md` Decisions logged section.
