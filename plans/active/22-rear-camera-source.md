# 22 — iPhone rear camera source

Today the publisher offers exactly two sources — the iPhone **front** camera and the **glasses** POV (`RoomConnection.Source` = `.frontCamera` / `.glasses`). Add the iPhone **rear** camera as a third source so the segmented picker becomes Front · Rear · Glasses. (The glasses expose a single POV lens with no camera-selection knob in DAT, so "another camera" can only mean the phone's back camera.)

## Goal

A three-segment source picker — **Front · Rear · Glasses** — where selecting *Rear* publishes the iPhone's back camera through the same LiveKit path the front camera already uses. Live-switching among all three works without dropping the room (the existing `switchSource` flow). The rear feed renders upright and un-mirrored in both the local preview and the viewer.

## Why this slice

The source layer is already a clean abstraction: a `VideoPublisher` protocol, a `Source` enum that drives the picker, and a `makePublisher(source:)` factory in `RoomConnection`. The only thing special about the front camera today is the literal `position: .front` in `FrontCameraSource`. The rear camera is the *same* publisher with `position: .back` — so the right move is to parameterize the camera publisher by position rather than duplicate the class. Everything downstream (mirror rule, connect/switch/disconnect, profiler tagging, the glasses gate) is already keyed on `Source` and extends by one case.

## Direction

1. **Generalize the camera publisher by position.** `FrontCameraSource` is identical to a hypothetical rear-camera source except for one enum value. Rename it to `CameraSource` and give it an `init(position: AVCaptureDevice.Position)`. (File rename is friction-free — the Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so there's no `project.pbxproj` reference to update.)
2. **Add the `.rearCamera` case** to `RoomConnection.Source`, with its `profileID`, and wire it in `makePublisher`.
3. **Shorten the picker labels** to single words so three segments fit cleanly on a phone-width segmented control.
4. **Extend the two source-keyed `switch`es** in `ContentView` that don't already fall through (`canConnect(for:)`).

No new permission (the generic `NSCameraUsageDescription` covers every camera), no Info.plist change, no viewer change, no pipeline change.

## Approach

### `CameraSource.swift` (renamed from `FrontCameraSource.swift`)

Add a stored `position` and thread it into the capture options + log label; the publish/unpublish bodies and the load-bearing comment about explicit publish/unpublish (vs `setCamera`'s mute round-trip) are unchanged.

```swift
@MainActor
final class CameraSource: VideoPublisher {
    private let position: AVCaptureDevice.Position
    private var publication: LocalTrackPublication?

    init(position: AVCaptureDevice.Position) { self.position = position }

    func publish(to room: Room) async throws -> VideoTrack? {
        // … existing comment about explicit publish/unpublish vs setCamera mute …
        let track = LocalVideoTrack.createCameraTrack(
            options: CameraCaptureOptions(position: position)
        )
        let pub = try await room.localParticipant.publish(
            videoTrack: track,
            options: VideoPublishOptions(simulcast: false)
        )
        publication = pub
        print("[\(label)] published \(pub.sid)")  // label = position == .front ? "frontCamera" : "rearCamera"
        return track
    }
    // unpublish(from:) unchanged except the log label (same frontCamera/rearCamera derivation)
}
```

### `RoomConnection.swift`

```swift
enum Source: String, CaseIterable, Identifiable {
    case frontCamera = "Front"
    case rearCamera  = "Rear"
    case glasses     = "Glasses"
    var id: String { rawValue }
    var profileID: String {
        switch self {
        case .frontCamera: return "frontCamera"
        case .rearCamera:  return "rearCamera"
        case .glasses:     return "glasses"
        }
    }
}

// makePublisher(source:)
case .frontCamera: return CameraSource(position: .front)
case .rearCamera:  return CameraSource(position: .back)
case .glasses:     return GlassesSource(…)   // unchanged
```

### `ContentView.swift`

Only `canConnect(for:)` has a non-exhaustive `switch` that needs the new case; merge it with `.frontCamera`:

```swift
case .frontCamera, .rearCamera: return true
case .glasses:                  return glasses.isReady
```

Everything else falls through correctly as-is:
- The picker already iterates `Source.allCases`, so the third segment appears automatically.
- `mirror: source == .frontCamera` already mirrors **only** the front (selfie) camera — rear and glasses stay un-mirrored, which is exactly right.
- The glasses gate (`source == .glasses, showGlassesGate`) and "Don glasses to connect" status are untouched — rear camera has no gate.

## File layout (delta)

```code
ios/WazaProto/WazaProto/CameraSource.swift          ← renamed from FrontCameraSource.swift; + position param
ios/WazaProto/WazaProto/RoomConnection.swift        ← Source enum (+rearCamera, +profileID), makePublisher, factory
ios/WazaProto/WazaProto/ContentView.swift           ← canConnect(for:) gains the .rearCamera case
plans/active/22-rear-camera-source.md
plans/index.md
```

No `project.pbxproj` edit (synchronized file group). No Info.plist edit. No `viewer/` edit. No test edits required (see decisions).

## Key decisions (upfront)

- **Parameterize one `CameraSource`, don't add a `BackCameraSource`.** The two would be byte-identical but for `position`; a second class would also duplicate the careful publish/unpublish comment block. One class with `init(position:)` is the minimal, honest factoring. Renaming `FrontCameraSource` → `CameraSource` is safe: nothing references the class name except `makePublisher`, and the sync'd file group means no project-file churn.
- **Shorten labels to "Front" / "Rear" / "Glasses".** A segmented control with three long labels ("Front camera" / "Rear camera" / "Glasses") truncates on phone widths. The rawValue is used only as the picker label and the enum `id` — it isn't persisted (`source` is transient `@State`) and no test asserts on it — so shortening has no migration or test cost. `profileID` stays `frontCamera`/`rearCamera`/`glasses`, decoupled from the display label, so profiler run-IDs and recorded data keys remain stable.
- **Rear camera is not mirrored.** Front-camera preview mirrors for natural selfie feel; the rear camera shows the world as-is. The existing `mirror: source == .frontCamera` already yields this — no change needed. (Mirroring is local-preview-only via `VideoView.mirrorMode`; viewers always receive un-mirrored frames.)
- **No new permission.** `NSCameraUsageDescription` is generic ("publishes your camera…") and covers front and back. iOS does not prompt per-lens.
- **No new tests strictly required.** `RoomConnectionTests` exercises `profileRunID` with raw source strings, not the enum, so it's unaffected; no test references `FrontCameraSource`. A one-line `Source.allCases.count == 3` / profileID-mapping unit is optional polish in the plan-18 spirit, but the change is mechanical and covered by manual verification below.

## Out of scope / inherited behavior

- **Backgrounding (plan 07).** The rear camera is an `AVCaptureSession`-backed source exactly like the front camera, so it inherits the same foreground/background capture behavior — no new `UIBackgroundModes` work, and nothing here changes the glasses background path.
- **Rear-camera capture format / lens choice (wide vs ultra-wide / zoom).** Default `CameraCaptureOptions(position: .back)` device only; multi-lens selection is a possible later `features.md` one-liner, not this slice.

## Done criteria

1. The source picker shows **three** segments — Front · Rear · Glasses — laid out without truncation on an iPhone.
2. Selecting **Rear** and tapping **Connect** publishes the iPhone rear camera; the viewer browser shows the rear-camera feed, **upright** and **not mirrored**.
3. **Live switching** among all three sources (Front ↔ Rear ↔ Glasses) succeeds without dropping the room connection — same path as today's Front ↔ Glasses swap.
4. The **front-camera** local preview is still mirrored; **rear** and **glasses** previews are not.
5. Profiler runs started on the rear source carry the `rearCamera` tag in their run-ID.
6. The glasses gate / "Don glasses to connect" status appears **only** for the Glasses source — selecting Rear shows neither.
7. Existing test suite still passes; no new camera-permission prompt appears (front, rear, and glasses all run under the existing grant).

## Decisions logged during implementation

- **`RoomConnection` needed `import AVFoundation` — the one deviation from the plan as written.** `makePublisher` now names `AVCaptureDevice.Position` cases (`.front`/`.back`) when constructing `CameraSource`; the old `FrontCameraSource()` took no args, so that type never surfaced in `RoomConnection.swift`. Without the import the build fails with *"enum case 'back'/'front' is not available due to missing import of defining module 'AVFoundation'."* (`CameraSource.swift` already imported it.) Everything else landed exactly as planned — three `Source` switches covered, no `project.pbxproj`/Info.plist/viewer change, no test edits.
- **Verified on-device (iPhone 17), not just the sim.** Selecting Rear + Connect logs `[rearCamera] published …`; repeated Rear↔Front swaps each log a clean unpublish→publish pair with no `Error:` and no room drop — confirming the rear publish path (criteria 2, 5) and live switching (criterion 3) on real hardware. Build clean (0 errors); 34/34 `WazaProtoTests` pass (criterion 7).

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

None this slice. (Multi-lens rear capture — wide/ultra-wide/zoom — remains a possible later `features.md` one-liner, as scoped out above.)
