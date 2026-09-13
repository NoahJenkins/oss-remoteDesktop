import Testing
@testable import TailviewCore

struct ProtocolHeuristicTests {
    @Test func macOSDefaultsToScreenSharing5900() {
        #expect(ProtocolHeuristic.suggest(os: "macOS") == .connectable(.screenSharing, port: 5900))
    }

    @Test func linuxDefaultsToVNC5900() {
        #expect(ProtocolHeuristic.suggest(os: "linux") == .connectable(.vnc, port: 5900))
    }

    @Test func windowsDefaultsToRDP3389() {
        #expect(ProtocolHeuristic.suggest(os: "windows") == .connectable(.rdp, port: 3389))
    }

    @Test func iOSIsNotConnectable() {
        guard case .notConnectable = ProtocolHeuristic.suggest(os: "iOS") else {
            Issue.record("expected notConnectable")
            return
        }
    }

    @Test func androidIsNotConnectable() {
        guard case .notConnectable = ProtocolHeuristic.suggest(os: "android") else {
            Issue.record("expected notConnectable")
            return
        }
    }

    @Test func unknownOSIsNotConnectable() {
        guard case .notConnectable = ProtocolHeuristic.suggest(os: "tvOS") else {
            Issue.record("expected notConnectable")
            return
        }
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(ProtocolHeuristic.suggest(os: "Linux") == .connectable(.vnc, port: 5900))
        #expect(ProtocolHeuristic.suggest(os: "WINDOWS") == .connectable(.rdp, port: 3389))
    }

    @Test func failoverPairsVNCAndRDP() {
        let vnc = ProtocolHeuristic.failover(from: .vnc)
        #expect(vnc.0 == .rdp)
        #expect(vnc.1 == 3389)
        let ss = ProtocolHeuristic.failover(from: .screenSharing)
        #expect(ss.0 == .rdp)
        #expect(ss.1 == 3389)
        let rdp = ProtocolHeuristic.failover(from: .rdp)
        #expect(rdp.0 == .vnc)
        #expect(rdp.1 == 5900)
    }
}
