import Testing
@testable import TailviewCore

struct CredentialStoreTests {
    @Test func missingReturnsNil() throws {
        let store = MemoryCredentialStore()
        #expect(try store.load(peerID: "n1", desktopProtocol: .vnc) == nil)
    }

    @Test func saveLoadDelete() throws {
        let store = MemoryCredentialStore()
        let creds = SessionCredentials(username: "ada", password: "pw")
        try store.save(peerID: "n1", desktopProtocol: .rdp, credentials: creds)
        #expect(try store.load(peerID: "n1", desktopProtocol: .rdp) == creds)
        #expect(try store.load(peerID: "n1", desktopProtocol: .vnc) == nil)
        try store.delete(peerID: "n1", desktopProtocol: .rdp)
        #expect(try store.load(peerID: "n1", desktopProtocol: .rdp) == nil)
    }
}
