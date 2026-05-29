# iOS publisher: SwiftProtobuf duplicate class warnings

**What:** On launch, the ObjC runtime logs ~4 warnings like:

```
objc[…]: Class _TtC13SwiftProtobuf17AnyMessageStorage is implemented in both
  …/MWDATCore.framework/MWDATCore (0x…) and
  …/WazaProto.debug.dylib (0x…).
  This may cause spurious casting failures and mysterious crashes.
  One of the duplicates must be removed or renamed.
```

The `MWDATCore.framework` XCFramework (Meta WDAT SDK v0.7) statically links SwiftProtobuf into its binary. The LiveKit Swift SDK *also* pulls SwiftProtobuf via SPM. Two copies of the same Swift Protobuf classes end up loaded into the process; the ObjC runtime registers whichever loads first and warns about the rest.

**Why deferred:** Real fix is vendor-side — Meta would need to either dynamic-link SwiftProtobuf or rename their internal copy's symbols. In practice the warning is benign for our use of LiveKit (we don't serialise SwiftProtobuf messages in any code path that crosses framework boundaries), and no observed crash or behavioural bug so far in step #5. Workarounds (manually strip SwiftProtobuf symbols from the XCFramework, fork & rebuild MWDATCore against shared SwiftProtobuf) are disproportionate to the prototype's scope.

**What would trigger paying it down:**
- Any "mysterious" cast failure or crash in a SwiftProtobuf-touching code path (e.g. LiveKit signaling, DAT capability negotiation).
- If Meta ships an `MWDATCore` build with SwiftProtobuf dynamically linked — pick up the upgrade.

**Where to start:** File a tracking issue with Meta WDAT (link to `https://github.com/facebook/meta-wearables-dat-ios/issues`) referencing the dual-link conflict with `livekit/client-sdk-swift`'s SwiftProtobuf dependency. Until a vendor fix exists, document the warning is expected in `README.md` so it doesn't get re-debugged.
