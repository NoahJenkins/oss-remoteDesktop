import Testing
@testable import TailviewCore

struct ClipboardLoopTests {
    @Test func localChangeSendsOnce() async {
        var loop = ClipboardLoop()
        let session = FakeRemoteSession(connectResult: .success(()))
        if let outgoing = loop.localPasteboardChanged("abc") {
            await session.sendClipboard(outgoing)
        }
        if let duplicate = loop.localPasteboardChanged("abc") {
            await session.sendClipboard(duplicate)
        }
        #expect(session.sentClipboard == ["abc"])
    }

    @Test func remoteEchoAfterSendDoesNotReapply() {
        var loop = ClipboardLoop()
        #expect(loop.localPasteboardChanged("abc") == "abc")
        #expect(loop.remoteArrived("abc") == nil)
    }
}
