import Foundation

public enum SessionEvent: Equatable, Sendable {
    case connecting
    case connected
    case failed(SessionFailure)
    case offerFailover(from: DesktopProtocol, to: DesktopProtocol, port: UInt16)
    case dropped
    case disconnected
}

public final class SessionController: Sendable {
    private let host: String
    private let credentials: SessionCredentials
    private let factory: RemoteSessionFactory
    private let state: State

    public let events: AsyncStream<SessionEvent>
    public let frames: AsyncStream<FramebufferFrame>
    public let remoteClipboard: AsyncStream<String>

    public init(
        endpoint: Endpoint,
        desktopProtocol: DesktopProtocol,
        credentials: SessionCredentials,
        factory: RemoteSessionFactory
    ) {
        host = endpoint.host
        self.credentials = credentials
        self.factory = factory
        let eventStream = AsyncStream.makeStream(of: SessionEvent.self)
        let frameStream = AsyncStream.makeStream(of: FramebufferFrame.self)
        let clipboardStream = AsyncStream.makeStream(of: String.self)
        events = eventStream.stream
        frames = frameStream.stream
        remoteClipboard = clipboardStream.stream
        state = State(
            desktopProtocol: desktopProtocol,
            port: endpoint.port,
            eventContinuation: eventStream.continuation,
            frameContinuation: frameStream.continuation,
            clipboardContinuation: clipboardStream.continuation
        )
    }

    public func start() async {
        await tearDownSession(emitDisconnected: false)
        yield(.connecting)
        let desktopProtocol = state.desktopProtocol
        let port = state.port
        let session: any RemoteSession
        do {
            session = try factory.makeSession(
                endpoint: Endpoint(host: host, port: port),
                desktopProtocol: desktopProtocol,
                credentials: credentials
            )
        } catch let failure as SessionFailure {
            handleFailure(failure, from: desktopProtocol)
            return
        } catch {
            return
        }
        let sessionID = state.install(session)
        do {
            try await session.connect()
        } catch let failure as SessionFailure {
            handleFailure(failure, from: desktopProtocol)
            return
        } catch {
            return
        }
        yield(.connected)
        forward(session, sessionID: sessionID)
    }

    public func acceptFailover() async {
        let (nextProtocol, nextPort) = ProtocolHeuristic.failover(from: state.desktopProtocol)
        state.desktopProtocol = nextProtocol
        state.port = nextPort
        await start()
    }

    public func declineFailover() async {
        yield(.disconnected)
    }

    public func reconnect() async {
        await tearDownSession(emitDisconnected: false)
        await start()
    }

    public func disconnect() async {
        await tearDownSession(emitDisconnected: true)
    }

    public func sendPointer(_ event: PointerEvent) async {
        await state.session?.sendPointer(event)
    }

    public func sendKey(_ event: KeyEvent) async {
        await state.session?.sendKey(event)
    }

    public func sendClipboard(_ text: String) async {
        await state.session?.sendClipboard(text)
    }

    private func handleFailure(_ failure: SessionFailure, from desktopProtocol: DesktopProtocol) {
        switch failure {
        case .authenticationFailed:
            yield(.failed(.authenticationFailed))
        case .rdpUnavailable:
            yield(.failed(.rdpUnavailable))
        case .connectionRefused, .timeout, .handshakeFailed:
            let (to, port) = ProtocolHeuristic.failover(from: desktopProtocol)
            yield(.offerFailover(from: desktopProtocol, to: to, port: port))
        case .dropped:
            yield(.dropped)
        }
    }

    private func forward(_ session: any RemoteSession, sessionID: Int) {
        let framesTask = Task { [state] in
            for await frame in session.frames {
                state.frameContinuation.yield(frame)
            }
            if state.isCurrent(sessionID) && state.connected {
                state.connected = false
                state.eventContinuation.yield(.dropped)
            }
        }
        let clipboardTask = Task { [state] in
            for await text in session.remoteClipboard {
                state.clipboardContinuation.yield(text)
            }
        }
        state.addForwarding([framesTask, clipboardTask])
        state.connected = true
    }

    private func tearDownSession(emitDisconnected: Bool) async {
        state.cancelForwarding()
        state.connected = false
        let session = state.takeSession()
        await session?.disconnect()
        if emitDisconnected {
            yield(.disconnected)
        }
    }

    private func yield(_ event: SessionEvent) {
        state.eventContinuation.yield(event)
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var desktopProtocol: DesktopProtocol
        var port: UInt16
        var session: (any RemoteSession)?
        var connected = false
        var sessionID = 0
        var forwardingTasks: [Task<Void, Never>] = []
        let eventContinuation: AsyncStream<SessionEvent>.Continuation
        let frameContinuation: AsyncStream<FramebufferFrame>.Continuation
        let clipboardContinuation: AsyncStream<String>.Continuation

        init(
            desktopProtocol: DesktopProtocol,
            port: UInt16,
            eventContinuation: AsyncStream<SessionEvent>.Continuation,
            frameContinuation: AsyncStream<FramebufferFrame>.Continuation,
            clipboardContinuation: AsyncStream<String>.Continuation
        ) {
            self.desktopProtocol = desktopProtocol
            self.port = port
            self.eventContinuation = eventContinuation
            self.frameContinuation = frameContinuation
            self.clipboardContinuation = clipboardContinuation
        }

        func install(_ session: any RemoteSession) -> Int {
            lock.lock()
            defer { lock.unlock() }
            self.session = session
            sessionID += 1
            return sessionID
        }

        func takeSession() -> (any RemoteSession)? {
            lock.lock()
            defer { lock.unlock() }
            let current = session
            session = nil
            return current
        }

        func isCurrent(_ id: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return sessionID == id && session != nil
        }

        func addForwarding(_ tasks: [Task<Void, Never>]) {
            lock.lock()
            defer { lock.unlock() }
            forwardingTasks.append(contentsOf: tasks)
        }

        func cancelForwarding() {
            lock.lock()
            let tasks = forwardingTasks
            forwardingTasks = []
            lock.unlock()
            tasks.forEach { $0.cancel() }
        }
    }
}
