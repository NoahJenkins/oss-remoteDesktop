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
            credentials: credentials,
            eventContinuation: eventStream.continuation,
            frameContinuation: frameStream.continuation,
            clipboardContinuation: clipboardStream.continuation
        )
    }

    public func start() async {
        await tearDownSession(emitDisconnected: false)
        yield(.connecting)
        let (desktopProtocol, port) = state.protocolAndPort()
        let credentials = state.currentCredentials()
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
            await tearDownSession(emitDisconnected: false)
            handleFailure(failure, from: desktopProtocol)
            return
        } catch {
            await tearDownSession(emitDisconnected: false)
            return
        }
        yield(.connected)
        forward(session, sessionID: sessionID)
    }

    public func acceptFailover() async {
        state.applyFailover()
        await start()
    }

    public func declineFailover() async {
        await tearDownSession(emitDisconnected: true)
    }

    public func retryWithCredentials(_ credentials: SessionCredentials) async {
        state.setCredentials(credentials)
        await start()
    }

    public func reconnect() async {
        await tearDownSession(emitDisconnected: false)
        await start()
    }

    public func disconnect() async {
        await tearDownSession(emitDisconnected: true)
    }

    public func sendPointer(_ event: PointerEvent) async {
        await state.currentSession()?.sendPointer(event)
    }

    public func sendKey(_ event: KeyEvent) async {
        await state.currentSession()?.sendKey(event)
    }

    public func sendClipboard(_ text: String) async {
        await state.currentSession()?.sendClipboard(text)
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
                state.yieldFrame(frame)
            }
            if state.clearConnectedIfCurrent(sessionID) {
                state.yieldEvent(.dropped)
            }
        }
        let clipboardTask = Task { [state] in
            for await text in session.remoteClipboard {
                state.yieldClipboard(text)
            }
        }
        state.addForwarding([framesTask, clipboardTask])
        state.markConnected()
    }

    private func tearDownSession(emitDisconnected: Bool) async {
        state.cancelForwarding()
        let session = state.takeSession()
        await session?.disconnect()
        if emitDisconnected {
            yield(.disconnected)
        }
    }

    private func yield(_ event: SessionEvent) {
        state.yieldEvent(event)
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var desktopProtocol: DesktopProtocol
        private var port: UInt16
        private var credentials: SessionCredentials
        private var session: (any RemoteSession)?
        private var connected = false
        private var sessionID = 0
        private var forwardingTasks: [Task<Void, Never>] = []
        private let eventContinuation: AsyncStream<SessionEvent>.Continuation
        private let frameContinuation: AsyncStream<FramebufferFrame>.Continuation
        private let clipboardContinuation: AsyncStream<String>.Continuation

        init(
            desktopProtocol: DesktopProtocol,
            port: UInt16,
            credentials: SessionCredentials,
            eventContinuation: AsyncStream<SessionEvent>.Continuation,
            frameContinuation: AsyncStream<FramebufferFrame>.Continuation,
            clipboardContinuation: AsyncStream<String>.Continuation
        ) {
            self.desktopProtocol = desktopProtocol
            self.port = port
            self.credentials = credentials
            self.eventContinuation = eventContinuation
            self.frameContinuation = frameContinuation
            self.clipboardContinuation = clipboardContinuation
        }

        func protocolAndPort() -> (DesktopProtocol, UInt16) {
            lock.lock()
            defer { lock.unlock() }
            return (desktopProtocol, port)
        }

        func applyFailover() {
            lock.lock()
            defer { lock.unlock() }
            let (nextProtocol, nextPort) = ProtocolHeuristic.failover(from: desktopProtocol)
            desktopProtocol = nextProtocol
            port = nextPort
        }

        func currentCredentials() -> SessionCredentials {
            lock.lock()
            defer { lock.unlock() }
            return credentials
        }

        func setCredentials(_ credentials: SessionCredentials) {
            lock.lock()
            defer { lock.unlock() }
            self.credentials = credentials
        }

        func currentSession() -> (any RemoteSession)? {
            lock.lock()
            defer { lock.unlock() }
            return session
        }

        func install(_ session: any RemoteSession) -> Int {
            lock.lock()
            defer { lock.unlock() }
            self.session = session
            connected = false
            sessionID += 1
            return sessionID
        }

        func takeSession() -> (any RemoteSession)? {
            lock.lock()
            defer { lock.unlock() }
            connected = false
            let current = session
            session = nil
            return current
        }

        func markConnected() {
            lock.lock()
            defer { lock.unlock() }
            connected = true
        }

        func clearConnectedIfCurrent(_ id: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard sessionID == id, session != nil, connected else { return false }
            connected = false
            return true
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

        func yieldEvent(_ event: SessionEvent) {
            eventContinuation.yield(event)
        }

        func yieldFrame(_ frame: FramebufferFrame) {
            frameContinuation.yield(frame)
        }

        func yieldClipboard(_ text: String) {
            clipboardContinuation.yield(text)
        }
    }
}
