import Darwin
import Foundation
import TailviewCore

public enum RDPSessionFactory {
    public static func makeSession(endpoint: Endpoint, credentials: SessionCredentials) throws -> any RemoteSession {
        guard loadLibrary() else { throw SessionFailure.rdpUnavailable }
        return RDPSession(endpoint: endpoint, credentials: credentials)
    }

    static func loadLibrary() -> Bool {
        dlopen("libtailview_rdp.dylib", RTLD_NOW | RTLD_GLOBAL) != nil
    }
}

public final class RDPSession: RemoteSession, @unchecked Sendable {
    private let endpoint: Endpoint
    private let credentials: SessionCredentials
    private let state = State()

    public let frames: AsyncStream<FramebufferFrame>
    public let remoteClipboard: AsyncStream<String>

    private let frameContinuation: AsyncStream<FramebufferFrame>.Continuation
    private let clipboardContinuation: AsyncStream<String>.Continuation

    public init(endpoint: Endpoint, credentials: SessionCredentials) {
        self.endpoint = endpoint
        self.credentials = credentials
        let frameStream = AsyncStream.makeStream(of: FramebufferFrame.self)
        frames = frameStream.stream
        frameContinuation = frameStream.continuation
        let clipboardStream = AsyncStream.makeStream(of: String.self)
        remoteClipboard = clipboardStream.stream
        clipboardContinuation = clipboardStream.continuation
    }

    public func connect() async throws {
        do {
            let session = try await Task.detached { [endpoint, credentials] in
                try rdpConnect(
                    host: endpoint.host,
                    port: endpoint.port,
                    username: credentials.username,
                    password: credentials.password
                )
            }.value
            state.install(session)
            startPolling(session)
        } catch let error as RdpError {
            throw Self.mapError(error)
        } catch is CancellationError {
            throw SessionFailure.dropped
        } catch {
            throw SessionFailure.rdpUnavailable
        }
    }

    public func disconnect() async {
        state.takeSession()?.disconnect()
        state.cancelPolling()
        frameContinuation.finish()
        clipboardContinuation.finish()
    }

    public func sendPointer(_ event: PointerEvent) async {
        guard let session = state.currentSession() else { return }
        session.sendPointer(
            x: UInt16(clamping: max(event.x, 0)),
            y: UInt16(clamping: max(event.y, 0)),
            left: event.left,
            right: event.right,
            middle: event.middle
        )
    }

    public func sendKey(_ event: KeyEvent) async {
        guard let session = state.currentSession() else { return }
        guard let scancode = Self.scancode(for: event.macKeyCode) else { return }
        session.sendScancode(scancode: scancode, down: event.down)
    }

    public func sendClipboard(_ text: String) async {
        state.currentSession()?.sendClipboardText(text: text)
    }

    private func startPolling(_ session: RdpSession) {
        let task = Task { [frameContinuation, clipboardContinuation] in
            while !Task.isCancelled {
                if let frame = session.pollFrame() {
                    frameContinuation.yield(
                        FramebufferFrame(width: Int(frame.width), height: Int(frame.height), rgba: frame.rgba)
                    )
                }
                if let text = session.pollClipboard() {
                    clipboardContinuation.yield(text)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        state.setPolling(task)
    }

    private static func mapError(_ error: RdpError) -> SessionFailure {
        switch error {
        case .ConnectionRefused:
            return .connectionRefused
        case .Timeout:
            return .timeout
        case .HandshakeFailed:
            return .handshakeFailed
        case .AuthenticationFailed:
            return .authenticationFailed
        case .Dropped:
            return .dropped
        }
    }

    private static func scancode(for macKeyCode: UInt16) -> UInt16? {
        switch macKeyCode {
        case 0: return 0x1E
        case 1: return 0x1F
        case 2: return 0x20
        case 3: return 0x21
        case 4: return 0x23
        case 5: return 0x22
        case 6: return 0x2C
        case 7: return 0x2D
        case 8: return 0x2E
        case 9: return 0x2F
        case 11: return 0x30
        case 12: return 0x10
        case 13: return 0x11
        case 14: return 0x12
        case 15: return 0x13
        case 16: return 0x15
        case 17: return 0x14
        case 18: return 0x02
        case 19: return 0x03
        case 20: return 0x04
        case 21: return 0x05
        case 22: return 0x07
        case 23: return 0x06
        case 25: return 0x0A
        case 26: return 0x08
        case 28: return 0x09
        case 29: return 0x0B
        case 31: return 0x18
        case 32: return 0x16
        case 34: return 0x17
        case 35: return 0x19
        case 36: return 0x1C
        case 37: return 0x26
        case 38: return 0x24
        case 40: return 0x25
        case 45: return 0x31
        case 46: return 0x32
        case 48: return 0x0F
        case 51: return 0x0E
        case 53: return 0x01
        case 56: return 0x2A
        case 58: return 0x38
        case 59: return 0x1D
        case 60: return 0x36
        case 61: return 0xE038
        case 62: return 0xE01D
        case 123: return 0xE04B
        case 124: return 0xE04D
        case 125: return 0xE050
        case 126: return 0xE048
        default: return nil
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var session: RdpSession?
        private var pollTask: Task<Void, Never>?

        func install(_ session: RdpSession) {
            lock.lock()
            defer { lock.unlock() }
            self.session = session
        }

        func currentSession() -> RdpSession? {
            lock.lock()
            defer { lock.unlock() }
            return session
        }

        func takeSession() -> RdpSession? {
            lock.lock()
            defer { lock.unlock() }
            let current = session
            session = nil
            return current
        }

        func setPolling(_ task: Task<Void, Never>) {
            lock.lock()
            defer { lock.unlock() }
            pollTask = task
        }

        func cancelPolling() {
            lock.lock()
            let task = pollTask
            pollTask = nil
            lock.unlock()
            task?.cancel()
        }
    }
}
