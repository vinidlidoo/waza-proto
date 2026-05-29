# Front-camera backgrounding

**What.** Keep the iPhone front-camera source publishing while the app is backgrounded.

**Why.** Symmetry with glasses-source backgrounding. The wearer might be doing a hands-free walk-and-talk and want their face on stream too.

**Why not now.** Apple actively blocks normal apps from capturing the camera in the background. The three escape hatches all cost a lot: PiP (fiddly capture-into-PiP plumbing), CallKit + VoIP background mode (PushKit, call lifecycle, real overhead), or a privileged entitlement we won't get. Re-evaluate only if demo feedback says it matters; for now we treat the front-camera source as foreground-only.
