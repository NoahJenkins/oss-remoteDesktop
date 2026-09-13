import Foundation
import Testing
@testable import TailviewCore

struct ProfileStoreTests {
    @Test func missingProfileIsNil() throws {
        let store = try ProfileStore(directory: temporaryDirectory())
        #expect(store.profile(for: "nMissing") == nil)
    }

    @Test func overrideRoundTripsOnDisk() throws {
        let directory = try temporaryDirectory()
        let store = try ProfileStore(directory: directory)
        try store.setOverride(
            peerID: "nLinux1",
            override: ProtocolOverride(desktopProtocol: .rdp, port: 3389)
        )
        let reloaded = try ProfileStore(directory: directory)
        let profile = reloaded.profile(for: "nLinux1")
        #expect(profile?.protocolOverride?.desktopProtocol == .rdp)
        #expect(profile?.protocolOverride?.port == 3389)
    }

    @Test func duplicatePeerIDsKeepLast() throws {
        let directory = try temporaryDirectory()
        let encoder = JSONEncoder()
        let data = try encoder.encode(DuplicateEnvelope(profiles: [
            PeerProfile(peerID: "n1", protocolOverride: ProtocolOverride(desktopProtocol: .vnc, port: 5900), lastUsed: nil),
            PeerProfile(peerID: "n1", protocolOverride: ProtocolOverride(desktopProtocol: .rdp, port: 3389), lastUsed: nil),
        ]))
        try data.write(to: directory.appendingPathComponent("profiles.json"))
        let store = try ProfileStore(directory: directory)
        #expect(store.profile(for: "n1")?.protocolOverride?.desktopProtocol == .rdp)
    }

    @Test func lastUsedIsPreservedWhenSettingOverride() throws {
        let store = try ProfileStore(directory: temporaryDirectory())
        let used = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsert(PeerProfile(peerID: "n1", protocolOverride: nil, lastUsed: used))
        try store.setOverride(peerID: "n1", override: ProtocolOverride(desktopProtocol: .vnc, port: 5901))
        #expect(store.profile(for: "n1")?.lastUsed == used)
    }

    private struct DuplicateEnvelope: Encodable {
        var profiles: [PeerProfile]
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
