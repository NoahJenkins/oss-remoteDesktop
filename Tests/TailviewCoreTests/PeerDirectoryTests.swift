import Testing
@testable import TailviewCore

struct PeerDirectoryTests {
    let selfNode = SelfNode(id: "nSelf", hostName: "my-mac")

    @Test func hidesSelfEvenIfAlsoInPeerList() {
        let peers = [
            PeerSnapshot(id: "nSelf", hostName: "my-mac", dnsName: "my-mac.tailnet.ts.net.", os: "macOS", online: true, tailscaleIPs: ["100.64.0.1"]),
            PeerSnapshot(id: "nLinux", hostName: "devbox", dnsName: "devbox.tailnet.ts.net.", os: "linux", online: true, tailscaleIPs: ["100.64.0.2"]),
        ]
        let rows = PeerDirectory.rows(selfNode: selfNode, peers: peers, profiles: [:])
        #expect(rows.map(\.id) == ["nLinux"])
    }

    @Test func linuxGetsVNCUnlessOverriddenToRDP() {
        let peer = PeerSnapshot(id: "nLinux", hostName: "devbox", dnsName: "devbox.tailnet.ts.net.", os: "linux", online: true, tailscaleIPs: ["100.64.0.2"])
        let defaultRows = PeerDirectory.rows(selfNode: selfNode, peers: [peer], profiles: [:])
        #expect(defaultRows[0].desktopProtocol == .vnc)
        #expect(defaultRows[0].port == 5900)
        let profiles = ["nLinux": PeerProfile(peerID: "nLinux", protocolOverride: ProtocolOverride(desktopProtocol: .rdp, port: 3389), lastUsed: nil)]
        let overridden = PeerDirectory.rows(selfNode: selfNode, peers: [peer], profiles: profiles)
        #expect(overridden[0].desktopProtocol == .rdp)
        #expect(overridden[0].port == 3389)
    }

    @Test func offlinePeerKeepsRowButDisablesConnect() {
        let peer = PeerSnapshot(id: "nMac", hostName: "studio", dnsName: "studio.tailnet.ts.net.", os: "macOS", online: false, tailscaleIPs: ["100.64.0.3"])
        let row = PeerDirectory.rows(selfNode: selfNode, peers: [peer], profiles: [:])[0]
        #expect(row.connectEnabled == false)
        #expect(row.disabledReason == "Offline")
        #expect(row.desktopProtocol == .screenSharing)
    }

    @Test func iOSIsVisibleButNotConnectable() {
        let peer = PeerSnapshot(id: "nPhone", hostName: "iphone", dnsName: "iphone.tailnet.ts.net.", os: "iOS", online: true, tailscaleIPs: ["100.64.0.4"])
        let row = PeerDirectory.rows(selfNode: selfNode, peers: [peer], profiles: [:])[0]
        #expect(row.connectEnabled == false)
        #expect(row.disabledReason != nil)
        #expect(row.desktopProtocol == nil)
    }

    @Test func displayNameStripsTrailingDotFromDNSName() {
        let peer = PeerSnapshot(id: "nLinux", hostName: "devbox", dnsName: "devbox.tailnet.ts.net.", os: "linux", online: true, tailscaleIPs: ["100.64.0.2"])
        #expect(PeerDirectory.rows(selfNode: selfNode, peers: [peer], profiles: [:])[0].displayName == "devbox.tailnet.ts.net")
    }

    @Test func prefersIPv4Host() {
        let peer = PeerSnapshot(id: "nLinux", hostName: "devbox", dnsName: "devbox.tailnet.ts.net.", os: "linux", online: true, tailscaleIPs: ["fd7a:115c:a1e0::2", "100.64.0.2"])
        #expect(PeerDirectory.rows(selfNode: selfNode, peers: [peer], profiles: [:])[0].host == "100.64.0.2")
    }

    @Test func onlineConnectablePeerEnablesConnect() {
        let peer = PeerSnapshot(id: "nLinux", hostName: "devbox", dnsName: "devbox.tailnet.ts.net.", os: "linux", online: true, tailscaleIPs: ["100.64.0.2"])
        #expect(PeerDirectory.rows(selfNode: selfNode, peers: [peer], profiles: [:])[0].connectEnabled == true)
    }
}
