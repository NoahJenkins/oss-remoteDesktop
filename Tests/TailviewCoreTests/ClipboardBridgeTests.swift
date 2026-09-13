import Testing
@testable import TailviewCore

struct ClipboardBridgeTests {
    @Test func doesNotResendUnchangedLocalText() {
        #expect(ClipboardBridge.outgoingText("hello", lastSent: "hello") == nil)
        #expect(ClipboardBridge.outgoingText("hello", lastSent: nil) == "hello")
        #expect(ClipboardBridge.outgoingText(nil, lastSent: nil) == nil)
    }

    @Test func doesNotReapplyUnchangedRemoteText() {
        #expect(ClipboardBridge.incomingText("hi", lastApplied: "hi") == nil)
        #expect(ClipboardBridge.incomingText("hi", lastApplied: nil) == "hi")
    }
}
