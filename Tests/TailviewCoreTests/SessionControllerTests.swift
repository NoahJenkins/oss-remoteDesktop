import Foundation
import Testing
@testable import TailviewCore

struct SessionControllerTests {
    let endpoint = Endpoint(host: "100.64.0.2", port: 5900)
    let credentials = SessionCredentials(username: "", password: "secret")

    @Test func connectFailureOffersFailover() async {
        let factory = FakeSessionFactory(result: .failure(.connectionRefused))
        let controller = SessionController(
            endpoint: endpoint,
            desktopProtocol: .vnc,
            credentials: credentials,
            factory: factory
        )
        await controller.start()
        let events = await collect(controller.events, atLeast: 2)
        #expect(events.contains(.connecting))
        #expect(events.contains(.offerFailover(from: .vnc, to: .rdp, port: 3389)))
        #expect(!events.contains(.failed(.authenticationFailed)))
    }

    @Test func authenticationFailureDoesNotFailover() async {
        let factory = FakeSessionFactory(result: .failure(.authenticationFailed))
        let controller = SessionController(
            endpoint: endpoint,
            desktopProtocol: .vnc,
            credentials: credentials,
            factory: factory
        )
        await controller.start()
        let events = await collect(controller.events, atLeast: 2)
        #expect(events.contains(.failed(.authenticationFailed)))
        #expect(!events.contains { if case .offerFailover = $0 { return true }; return false })
    }

    @Test func acceptFailoverStartsPairedProtocol() async {
        let factory = FakeSessionFactory(results: [.failure(.timeout), .success(())])
        let controller = SessionController(
            endpoint: endpoint,
            desktopProtocol: .vnc,
            credentials: credentials,
            factory: factory
        )
        await controller.start()
        await controller.acceptFailover()
        #expect(factory.createdProtocols == [.vnc, .rdp])
        #expect(factory.createdPorts == [5900, 3389])
        let events = await collect(controller.events, atLeast: 3)
        #expect(events.contains(.connected))
    }

    @Test func reconnectUsesSameProtocolPortAndCredentials() async {
        let factory = FakeSessionFactory(result: .success(()))
        let controller = SessionController(
            endpoint: endpoint,
            desktopProtocol: .vnc,
            credentials: credentials,
            factory: factory
        )
        await controller.start()
        await controller.reconnect()
        #expect(factory.createdProtocols == [.vnc, .vnc])
        #expect(factory.createdPorts == [5900, 5900])
        #expect(factory.createdCredentials == [credentials, credentials])
    }

    @Test func disconnectTearsDownBackend() async {
        let factory = FakeSessionFactory(result: .success(()))
        let controller = SessionController(
            endpoint: endpoint,
            desktopProtocol: .vnc,
            credentials: credentials,
            factory: factory
        )
        await controller.start()
        await controller.disconnect()
        #expect(factory.lastSession?.disconnectCalled == true)
    }

    @Test func failedConnectReleasesBackendAndDropsInput() async {
        let factory = FakeSessionFactory(result: .failure(.connectionRefused))
        let controller = SessionController(
            endpoint: endpoint,
            desktopProtocol: .vnc,
            credentials: credentials,
            factory: factory
        )
        await controller.start()
        await controller.sendClipboard("secret")
        #expect(factory.lastSession?.disconnectCalled == true)
        #expect(factory.lastSession?.sentClipboard.isEmpty == true)
    }

    @Test func declineFailoverReleasesFailedSession() async {
        let factory = FakeSessionFactory(result: .failure(.timeout))
        let controller = SessionController(
            endpoint: endpoint,
            desktopProtocol: .vnc,
            credentials: credentials,
            factory: factory
        )
        await controller.start()
        await controller.declineFailover()
        #expect(factory.lastSession?.disconnectCalled == true)
        let events = await collect(controller.events, atLeast: 3)
        #expect(events.contains(.disconnected))
    }

    @Test func connectTimeDroppedOffersFailover() async {
        let factory = FakeSessionFactory(result: .failure(.dropped))
        let controller = SessionController(
            endpoint: endpoint,
            desktopProtocol: .vnc,
            credentials: credentials,
            factory: factory
        )
        await controller.start()
        let events = await collect(controller.events, atLeast: 2)
        #expect(events.contains(.connecting))
        #expect(events.contains(.offerFailover(from: .vnc, to: .rdp, port: 3389)))
        #expect(!events.contains(.dropped))
    }

    @Test func dropAfterConnectYieldsDropped() async {
        let factory = FakeSessionFactory(result: .success(()), dropAfterConnect: true)
        let controller = SessionController(
            endpoint: endpoint,
            desktopProtocol: .vnc,
            credentials: credentials,
            factory: factory
        )
        await controller.start()
        let events = await collect(controller.events, atLeast: 3)
        #expect(events.contains(.connecting))
        #expect(events.contains(.connected))
        #expect(events.contains(.dropped))
        #expect(!events.contains { if case .offerFailover = $0 { return true }; return false })
    }

    @Test func unknownStartErrorFailsHandshake() async {
        let controller = SessionController(
            endpoint: endpoint,
            desktopProtocol: .vnc,
            credentials: credentials,
            factory: ThrowingSessionFactory()
        )
        await controller.start()
        let events = await collect(controller.events, atLeast: 2)
        #expect(events.contains(.connecting))
        #expect(events.contains(.failed(.handshakeFailed)))
        #expect(!events.contains { if case .offerFailover = $0 { return true }; return false })
    }

    @Test func declineFailoverDisconnectsWithoutSecondSession() async {
        let factory = FakeSessionFactory(result: .failure(.connectionRefused))
        let controller = SessionController(
            endpoint: Endpoint(host: "100.64.0.2", port: 5900),
            desktopProtocol: .vnc,
            credentials: SessionCredentials(username: "", password: "x"),
            factory: factory
        )
        await controller.start()
        await controller.declineFailover()
        #expect(factory.createdProtocols == [.vnc])
        let events = await collect(controller.events, atLeast: 3)
        #expect(events.contains(.disconnected))
    }
}

private struct ThrowingSessionFactory: RemoteSessionFactory {
    struct Boom: Error {}

    func makeSession(
        endpoint: Endpoint,
        desktopProtocol: DesktopProtocol,
        credentials: SessionCredentials
    ) throws -> any RemoteSession {
        throw Boom()
    }
}

func collect<T: Sendable>(_ stream: AsyncStream<T>, atLeast _: Int) async -> [T] {
    let box = CollectBox<T>()
    let reader = Task {
        for await item in stream {
            box.append(item)
        }
    }
    try? await Task.sleep(for: .milliseconds(200))
    reader.cancel()
    return box.snapshot()
}

private final class CollectBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    func snapshot() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
