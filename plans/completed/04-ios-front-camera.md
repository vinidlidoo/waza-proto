# 04 — iOS shell publishing the iPhone front camera

Build ladder step #4 (see `README.md`). First native code in the repo. Confirms the iOS publish path end-to-end before we add WDAT's glasses-frames complication.

## Goal

A minimal iOS app, running on a real iPhone, publishes the front camera to the `waza-proto` LiveKit room. The browser viewer from step #2 shows the iPhone's camera with sub-second latency. No WDAT, no glasses, no annotations.

## Why this slice

After this step, every piece of *non-WDAT* infrastructure is validated end-to-end on real hardware:

- iOS signing and provisioning (free Apple ID path).
- LiveKit Swift SDK API surface for publishing.
- iOS camera capture + LiveKit's `CameraCapturer` track source.
- Adaptive bitrate behaviour with a real live encoder (which we now expect to be vastly smoother than the file-publisher in step #3, given what `WebRTC Video Loss Recovery` note taught us).
- Permission prompts (`NSCameraUsageDescription`).
- Token delivery to a mobile app.

When step #5 inevitably fails, the failure is localised to "the WDAT frame conversion code I just added", not "iOS LiveKit publishing in general."

## Approach

Three pieces, in order:

### 1. Parameterise `scripts/mint-token.sh` (revisiting the step-#3 deferral)

Step #3 left `mint-token.sh` viewer-only because `lk room join` mints its own token. The iOS app *cannot* mint its own token (it would have to ship `LIVEKIT_API_SECRET`, which is a hard "no" — see Waza Proto's CLAUDE.md secrets policy). So we genuinely need a publisher-token script now.

```bash
./scripts/mint-token.sh viewer     # existing behaviour (default)
./scripts/mint-token.sh publisher  # new: canPublish only, identity ios-publisher
```

The identity is `ios-publisher` (distinct from step #3's `test-publisher`) so LiveKit Cloud session logs make the two sources distinguishable.

### 2. Create the Xcode project at `ios/WazaProto/`

- Single-target SwiftUI app, deployment target iOS 26 (matches Vincent's iPhone 17 / iOS 26.4.2; only device that'll ever run this).
- Bundle ID `com.vincent.wazaproto` (or similar — must be globally-unique-ish for free-tier sideloading).
- Signing: **free Apple ID**, "Sign to Run Locally" — 7-day provisioning. Re-sign weekly during prototype phase. Defer the $99/yr until step #5's WDAT work confirms whether paid provisioning is required.
- LiveKit Swift SDK added via SPM: `https://github.com/livekit/client-sdk-swift` pinned `from: "2.14.1"` (current stable per Docs MCP). We are *not* adding `components-swift` — we only publish, never render remote participants, so the components library's `VideoTrackView` / `ForEachParticipant` add nothing.
- `Info.plist` gets `NSCameraUsageDescription` = "Waza Proto publishes your camera to demonstrate the streaming pipeline." (And `NSMicrophoneUsageDescription` even though we don't publish audio, because LiveKit's CameraCapturer probes the mic permission on init in some SDK versions — defensive.)

### 3. Minimal SwiftUI app

One screen, three elements:

- **Local preview** (`CameraPreviewView` wrapping LiveKit's `VideoView` showing the local publication).
- **Status label** ("disconnected" / "connecting" / "connected as ios-publisher" / "error: ...").
- **Connect / Disconnect button.**

Token delivery: **hardcoded constant in source** for this step. Generated via `./scripts/mint-token.sh publisher` and pasted in. Survives 6h (script TTL). Next step iterates if needed.

Code outline (verified against client-sdk-swift 2.14.1 README + `CameraCaptureOptions` source via the Docs MCP):

```swift
let room = Room()
room.add(delegate: self)  // RoomDelegate.didPublishTrack → assign track to localVideoView
try await room.connect(url: wsURL, token: token)
try await room.localParticipant.setCamera(
    enabled: true,
    captureOptions: CameraCaptureOptions(position: .front)
)
```

Local preview = LiveKit's UIKit `VideoView` wrapped in `UIViewRepresentable`.

⚠️ The iOS Simulator does **not** support publishing the camera track (per LiveKit README). We can only test on the physical iPhone.

```
ios/
  WazaProto/
    WazaProto.xcodeproj/
    WazaProto/
      WazaProtoApp.swift           ← @main
      ContentView.swift             ← UI
      RoomConnection.swift          ← LiveKit connect/publish logic (an ObservableObject)
      Info.plist
```

## Key decisions (upfront)

- **Free Apple ID sideloading, not paid Developer account.** Defer the $99 until step #5 forces it (WDAT may require a paid profile for Bluetooth Classic entitlements — we don't yet know). 7-day re-sign is annoying but acceptable for daily-test cadence.
- **SwiftUI over UIKit.** Fewer ceremony files, native to LiveKit Swift SDK's modern API, matches what we'd write today for a fresh iOS project. Vincent gets cleaner code to learn from.
- **Hardcoded token in source, not a fetch-from-server endpoint.** Same trade-off as step #2's browser viewer. A real app would have a backend that mints per-user tokens; a prototype that runs once a day doesn't need that yet.
- **Front camera, not rear.** Closer mental model to "the glasses' POV camera" (the user is the operator and sees themselves). Also: easier to debug — Vincent can wave at his own face and immediately see if the viewer shows it.
- **No audio publishing.** Scope reduction. Audio is an explicit v0.06 thing. Skip the `AVAudioSession` configuration headache for now.
- **Identity is `ios-publisher`, not `iphone-publisher` or similar.** Keeps the door open for an Android publisher later without renaming. Matches the `ios/` directory name.

## Open questions

- ~~**LiveKit Swift SDK API surface.**~~ ✅ Resolved via Docs MCP: `room.connect(url:token:)` + `localParticipant.setCamera(enabled:captureOptions:)` with `CameraCaptureOptions(position: .front)`. SDK pinned to 2.14.1.
- **CameraCapturer device-selection on multi-camera iPhones.** iPhone 15 Pro has 4 cameras (ultra-wide, wide, telephoto, front). LiveKit's default is probably the front-facing wide. Worth confirming.
- **Simulcast defaults.** The Swift SDK enables simulcast for video tracks by default (LOW/MEDIUM/HIGH). Fine for our case — viewer will request HIGH on a desktop browser. Worth noting in learnings whether/how to disable for WDAT later (WDAT's frame source is fixed 720×1280 @ 30 — simulcast would force re-encoding to lower tiers, killing battery).
- **Bundle ID collision risk.** Free Apple ID provisioning may reject a bundle ID someone else has registered. If `com.vincent.wazaproto` is taken, try `com.vincent.wazaproto.vethier` or similar.
- **iOS Local Network permission.** LiveKit's signalling websocket goes to `*.livekit.cloud` (public internet, not local), so this *shouldn't* trigger iOS's Local Network permission prompt. But the WebRTC stack does ICE candidate gathering which probes local interfaces — sometimes iOS pops the prompt anyway. Worth knowing in advance so it doesn't read as a bug.

## Done criteria

1. `./scripts/mint-token.sh publisher` prints a valid JWT with `canPublish: true`, `canSubscribe: false`, identity `ios-publisher`. `./scripts/mint-token.sh viewer` (or no-arg default) still works as before.
2. iOS app builds in Xcode, installs on a physical iPhone via free Apple ID provisioning.
3. On first launch, app prompts for camera permission. After granting, tapping Connect joins the room and starts publishing.
4. Browser viewer (with a fresh viewer token) shows the iPhone front camera within ~2s of Connect.
5. Latency is qualitatively low (well under 1s — measure by waving at the camera and watching the viewer). No PLI floods (real encoder + adaptive bitrate should keep the decoder in sync).
6. Tapping Disconnect cleanly tears down; viewer's status reverts to "waiting for video".
7. Backgrounding the app (home button) does *not* crash — graceful behaviour expected, even if publishing stops.

## Decisions logged during implementation

- **No `components-swift` dependency.** Only `client-sdk-swift` 2.14.1. The components library's `VideoTrackView` / `ForEachParticipant` / `RoomScope` add nothing for a publish-only app. Keeps surface minimal.
- **Secrets extracted to gitignored `ios/WazaProto/WazaProto/Secrets.swift`** (with companion `scripts/refresh-secrets.sh`). The plan said "hardcoded constant in source" — that would have committed the JWT and the wsURL into git history. The `Secrets.swift` extraction keeps `RoomConnection.swift` clean and committable while letting the values live where the app can statically read them. `refresh-secrets.sh` regenerates the file from `.env` + a fresh `mint-token.sh publisher` call, so JWT expiry (every 6h) doesn't require a manual paste each time.
- **Used `localParticipant.firstCameraVideoTrack` convenience accessor instead of implementing `RoomDelegate`.** The README's example wires a delegate to catch `didPublishTrack`. But the `setCamera(enabled:captureOptions:)` call is `await`-able — by the time it returns, the track exists, and we can read it synchronously. Removes ~15 lines of delegate boilerplate and a Swift 6 actor-hopping wrinkle (delegate methods are called off-main).
- **Local preview = `LocalPreview: UIViewRepresentable` wrapping LiveKit's UIKit `VideoView`, as a private struct in `ContentView.swift`** — not a separate file. Short enough not to justify its own file.
- **`mirrorMode = .auto`** on the local preview, so the front-camera feed reads like a mirror (FaceTime-style). Match's user expectation for a self-view.
- **`disconnect()` on `Room` is async-but-not-throws.** First draft had `try? await room.disconnect()` in the catch block — Xcode flagged the unnecessary `try?`. Clean call is just `await room.disconnect()`.

## Vincent's learnings

- **The LiveKit Docs MCP server is the single biggest workflow upgrade for this kind of project.** Last step's API research (PLI/RTCP/keyframes) was hours of reading. This step's "what's the canonical Swift publish recipe" took two queries and ~2 minutes. The MCP returns *current* docs with full code blocks — no risk of training-data drift to a stale v1 API.
- **The Swift SDK is API-stable enough to be predictable.** `Room()` → `connect(url:token:)` → `localParticipant.setCamera(enabled:captureOptions:)`. The bulk of the iOS app code is SwiftUI ceremony, not LiveKit ceremony.
- **`@Published` and `ObservableObject` live in the `Combine` framework, not SwiftUI.** In Swift 6 strict-concurrency mode, SwiftUI's implicit re-export of these symbols is unreliable — you need an explicit `import Combine`. The error message ("does not conform to protocol 'ObservableObject'") doesn't mention Combine at all; the actual hint is buried in a sibling error about `@Published`'s wrapped-value initializer. The Xcode MCP made this debug trivial: one tool call surfaced all 5 cascading errors, and the fix was one line.
- **Xcode 16 introduced "filesystem-synchronized groups" (`PBXFileSystemSynchronizedRootGroup`)** as a project-file structure. Any file you drop into the synchronized folder auto-joins the target. Removes the old "drag file into Xcode sidebar, check 'Add to target' checkbox" dance. Means tools (like Claude Code) can create Swift files without touching the `.xcodeproj` at all.
- **Xcode auto-creates a nested `.git` repo when generating a new project**, even when the destination is already inside another git repo. Have to remove it or git treats `ios/` as an opaque embedded repo. Sandbox blocks `rm -rf .git` for safety; needs an explicit override.
- **Privacy strings live in target build settings as `INFOPLIST_KEY_*`** (Xcode 14+), not a standalone `Info.plist` file. Xcode generates `Info.plist` at build time from these keys. Plan was wrong to assume a hand-editable Info.plist — modern projects don't have one by default.
- **Free Apple ID sideloading: three friction points beyond signing.**
  - (1) Have to add the Apple ID under Xcode → Settings → Accounts; the project wizard's "Team" dropdown is empty until then.
  - (2) iOS 16+ requires Developer Mode on the device (Settings → Privacy & Security → Developer Mode). One-time, but easy to miss.
  - (3) First launch shows "Untrusted Developer"; user manually trusts under Settings → General → VPN & Device Management.
  - All three are one-time per device, but they're hard-stops if skipped.
- **The full pipeline (iOS publisher → LiveKit Cloud → browser viewer) worked first try once the build succeeded.** No PLI flood like step #3, no connection failures, no codec issues. Validates the working theory from `WebRTC Video Loss Recovery`: a real encoder on a real device handles PLIs correctly because it can produce keyframes on demand, unlike a file-based publisher.
- **The Xcode MCP server is a step-change for build-fix-rebuild cycles.** `XcodeListNavigatorIssues` surfaces all current errors; `XcodeRefreshCodeIssuesInFile` re-checks after a write; `BuildProject` runs a full build and returns success/errors structurally. The whole "fix import Combine" loop took ~30 seconds without leaving Claude. Compare to step #3 where I had to paste console output back and forth.

## Tech debt opened

Logged separately in `plans/tech-debt-tracker.md`:
- Video quality tuning: defaults work but feed is "not amazing" subjectively. Revisit simulcast layers, bitrate caps, resolution. Trigger to pay down: before demoing to anyone, or when WDAT integration exposes encoder load problems.
