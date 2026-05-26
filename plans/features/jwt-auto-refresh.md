# Long-session JWT auto-refresh on the publisher

**What.** Add a refresh path on the iOS publisher's LiveKit JWT (today minted with a 6h TTL by `scripts/refresh-secrets.sh`). Either rotate via the same Vercel mint endpoint used by viewers, or vend short-lived publisher tokens from a separate endpoint.

**Why.** Backgrounded glasses sessions could run hours. The current manual-refresh workflow is fine for demos but breaks the moment a session crosses the 6h boundary.

**Why not now.** Surfaced as an open question in step 7. The current demo cadence (sub-hour) doesn't hit it. Bundle with whatever step touches `Secrets.swift` or the auth side again.
