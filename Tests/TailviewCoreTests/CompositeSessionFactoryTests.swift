import Testing
@testable import TailviewCore

struct CompositeSessionFactoryTests {
    let endpoint = Endpoint(host: "100.64.0.2", port: 5900)
    let credentials = SessionCredentials(username: "", password: "x")

    @Test func screenSharingAndVNCUseVNCClosure() throws {
        var used: [DesktopProtocol] = []
        let factory = CompositeSessionFactory(
            vnc: { _, _ in
                used.append(.vnc)
                return FakeRemoteSession(connectResult: .success(()))
            },
            rdp: nil
        )
        _ = try factory.makeSession(endpoint: endpoint, desktopProtocol: .vnc, credentials: credentials)
        _ = try factory.makeSession(endpoint: endpoint, desktopProtocol: .screenSharing, credentials: credentials)
        #expect(used == [.vnc, .vnc])
    }

    @Test func rdpWithoutClosureThrowsUnavailable() {
        let factory = CompositeSessionFactory(
            vnc: { _, _ in FakeRemoteSession(connectResult: .success(())) },
            rdp: nil
        )
        do {
            _ = try factory.makeSession(endpoint: endpoint, desktopProtocol: .rdp, credentials: credentials)
            Issue.record("expected throw")
        } catch let failure as SessionFailure {
            #expect(failure == .rdpUnavailable)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}
