import Foundation
@testable import TailviewCore

final class FakeRemoteSession: RemoteSession, @unchecked Sendable {
    var connectResult: Result<Void, SessionFailure>
    var dropAfterConnect: Bool
    private(set) var disconnectCalled = false
    private(set) var sentClipboard: [String] = []

    let frames: AsyncStream<FramebufferFrame>
    let remoteClipboard: AsyncStream<String>

    private let frameContinuation: AsyncStream<FramebufferFrame>.Continuation
    private let clipboardContinuation: AsyncStream<String>.Continuation

    init(connectResult: Result<Void, SessionFailure>, dropAfterConnect: Bool = false) {
        self.connectResult = connectResult
        self.dropAfterConnect = dropAfterConnect
        let frameStream = AsyncStream.makeStream(of: FramebufferFrame.self)
        frames = frameStream.stream
        frameContinuation = frameStream.continuation
        let clipboardStream = AsyncStream.makeStream(of: String.self)
        remoteClipboard = clipboardStream.stream
        clipboardContinuation = clipboardStream.continuation
    }

    func connect() async throws {
        switch connectResult {
        case .success:
            if dropAfterConnect {
                frameContinuation.finish()
            }
        case .failure(let failure):
            throw failure
        }
    }

    func disconnect() async {
        disconnectCalled = true
        frameContinuation.finish()
        clipboardContinuation.finish()
    }

    func sendPointer(_ event: PointerEvent) async {}

    func sendKey(_ event: KeyEvent) async {}

    func sendClipboard(_ text: String) async {
        sentClipboard.append(text)
    }

    func emitRemoteClipboard(_ text: String) {
        clipboardContinuation.yield(text)
    }

    func emitFrame(_ frame: FramebufferFrame) {
        frameContinuation.yield(frame)
    }
}

final class FakeSessionFactory: RemoteSessionFactory, @unchecked Sendable {
    private var results: [Result<Void, SessionFailure>]
    private(set) var createdProtocols: [DesktopProtocol] = []
    private(set) var createdPorts: [UInt16] = []
    private(set) var createdCredentials: [SessionCredentials] = []
    private(set) var lastSession: FakeRemoteSession?

    init(result: Result<Void, SessionFailure>) {
        results = [result]
    }

    init(results: [Result<Void, SessionFailure>]) {
        self.results = results
    }

    func makeSession(
        endpoint: Endpoint,
        desktopProtocol: DesktopProtocol,
        credentials: SessionCredentials
    ) throws -> any RemoteSession {
        createdProtocols.append(desktopProtocol)
        createdPorts.append(endpoint.port)
        createdCredentials.append(credentials)
        let result = results.isEmpty ? Result<Void, SessionFailure>.success(()) : results.removeFirst()
        let session = FakeRemoteSession(connectResult: result)
        lastSession = session
        return session
    }
}
