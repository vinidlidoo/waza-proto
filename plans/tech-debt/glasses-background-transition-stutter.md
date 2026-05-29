# Glasses stream: background-transition reference-frame stutter

**What:** Every foreground↔background app transition produces ~5 seconds of `kVTVideoDecoderReferenceMissingErr` (-17694) in the in-app HEVC decode path. The HW decoder loses its reference frame across the suspension and waits for the next IDR before recovering. Heartbeat resumes at ~25-30 fps once the IDR arrives.

**Why deferred:** Acceptable for the "publisher puts phone in pocket and walks around" use case (one transition, then steady). DAT's public API doesn't currently expose a way to request an immediate keyframe, so the fix would be either a runtime workaround (drop frames silently until the next IDR, which we effectively already do) or a vendor request to Meta.

**What would trigger paying it down:** Use cases that involve frequent app switching, or demo feedback specifically calling out the post-transition stutter.

**Where to start:** File a feature request against `facebook/meta-wearables-dat-ios` for a `Stream.requestKeyframe()` (or equivalent) hook. In the meantime, an option worth experimenting with: log an explicit "decoder recovering" status to the UI during the stutter so the user knows the freeze is intentional.
