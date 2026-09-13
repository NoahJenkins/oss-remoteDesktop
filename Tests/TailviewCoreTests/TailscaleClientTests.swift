import Foundation
import Testing
@testable import TailviewCore

struct TailscaleClientTests {
    @Test func missingSocketBecomesNotRunning() async {
        let client = TailscaleClient(transport: FailingTransport(error: MissingSocketError()))
        let status = await client.snapshot()
        #expect(status == .unavailable(.notRunning))
    }

    @Test func runningJSONBecomesRunningStatus() async throws {
        let data = try Data(contentsOf: fixtureURL("status-running.json"))
        let client = TailscaleClient(transport: FixedTransport(data: data))
        let status = await client.snapshot()
        guard case .running(let selfNode, _) = status else {
            Issue.record("expected running")
            return
        }
        #expect(selfNode.id == "nSelf123")
    }

    @Test func snapshotsEmitPolledValues() async throws {
        let data = try Data(contentsOf: fixtureURL("status-running.json"))
        let client = TailscaleClient(transport: FixedTransport(data: data), pollInterval: .milliseconds(20))
        var iterator = client.snapshots().makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first != nil)
        #expect(second != nil)
    }

    private func fixtureURL(_ name: String) -> URL {
        let resource = name.replacingOccurrences(of: ".json", with: "")
        return Bundle.module.url(forResource: resource, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: resource, withExtension: "json")!
    }
}

private struct FixedTransport: LocalAPITransport {
    let data: Data
    func getStatusJSON() async throws -> Data { data }
}

private struct FailingTransport: LocalAPITransport {
    let error: Error
    func getStatusJSON() async throws -> Data { throw error }
}
