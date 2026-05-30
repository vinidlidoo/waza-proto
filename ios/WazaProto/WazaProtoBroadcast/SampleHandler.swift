import LiveKit

// The whole broadcast pipeline — receiving ReplayKit sample buffers and pumping
// them over the App Group socket to the main app's BroadcastScreenCapturer —
// lives in LiveKit's LKSampleHandler base class. We only enable logging so the
// extension's messages show up in Console under category "LKSampleHandler".
#if os(iOS)
@available(macCatalyst 13.1, *)
class SampleHandler: LKSampleHandler {
    override var enableLogging: Bool { true }
}
#endif
