import Foundation
import Testing
@testable import TailviewCore

struct LocalAPIStatusParserTests {
    @Test func runningParsesSelfAndPeers() throws {
        let status = try LocalAPIStatusParser.parse(fixture("status-running.json"))
        guard case .running(let selfNode, let peers) = status else {
            Issue.record("expected running")
            return
        }
        #expect(selfNode.id == "nSelf123")
        #expect(peers.contains(where: { $0.id == "nLinux1" && $0.os == "linux" && $0.online }))
        #expect(peers.contains(where: { $0.id == "nPhone" && $0.os == "iOS" }))
    }

    @Test func needsLoginIsUnavailableNotLoggedIn() throws {
        let status = try LocalAPIStatusParser.parse(fixture("status-needs-login.json"))
        #expect(status == .unavailable(.notLoggedIn))
    }

    @Test func stoppedIsUnavailableNotRunning() throws {
        let status = try LocalAPIStatusParser.parse(fixture("status-stopped.json"))
        #expect(status == .unavailable(.notRunning))
    }

    private func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name.replacingOccurrences(of: ".json", with: ""), withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name.replacingOccurrences(of: ".json", with: ""), withExtension: "json")
        return try! Data(contentsOf: url!)
    }
}
