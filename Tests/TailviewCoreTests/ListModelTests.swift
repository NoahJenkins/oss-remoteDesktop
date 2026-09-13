import Testing
@testable import TailviewCore

struct ListModelTests {
    @Test func notRunning() {
        #expect(ListModel.from(status: .unavailable(.notRunning), profiles: [:]) == .notRunning)
    }

    @Test func notLoggedIn() {
        #expect(ListModel.from(status: .unavailable(.notLoggedIn), profiles: [:]) == .notLoggedIn)
    }

    @Test func runningHidesSelf() {
        let status = TailscaleStatus.running(
            selfNode: SelfNode(id: "nSelf", hostName: "my-mac"),
            peers: [
                PeerSnapshot(id: "nSelf", hostName: "my-mac", dnsName: "", os: "macOS", online: true, tailscaleIPs: ["100.64.0.1"]),
                PeerSnapshot(id: "nLinux", hostName: "devbox", dnsName: "devbox.tailnet.ts.net.", os: "linux", online: true, tailscaleIPs: ["100.64.0.2"]),
            ]
        )
        guard case .ready(let rows) = ListModel.from(status: status, profiles: [:]) else {
            Issue.record("expected ready")
            return
        }
        #expect(rows.map(\.id) == ["nLinux"])
    }
}
