import CoreGraphics
import Darwin
import Foundation
import Network
import RoyalVNCKit
import TailviewCore

public final class VNCSession: NSObject, RemoteSession, VNCConnectionDelegate, @unchecked Sendable {
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
        super.init()
    }

    public func connect() async throws {
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: endpoint.host,
            port: endpoint.port,
            isShared: true,
            isScalingEnabled: false,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
            isClipboardRedirectionEnabled: true,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        state.reset(connection: connection)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state.setConnectContinuation(continuation)
            connection.connect()
        }
    }

    public func disconnect() async {
        state.markDisconnectRequested()?.disconnect()
        frameContinuation.finish()
        clipboardContinuation.finish()
    }

    public func sendPointer(_ event: PointerEvent) async {
        let snapshot = state.pointerSnapshot(updatingTo: event)
        guard let connection = snapshot.connection else { return }
        let x = UInt16(clamping: max(event.x, 0))
        let y = UInt16(clamping: max(event.y, 0))
        if event.left != snapshot.left {
            if event.left {
                connection.mouseButtonDown(.left, x: x, y: y)
            } else {
                connection.mouseButtonUp(.left, x: x, y: y)
            }
        }
        if event.right != snapshot.right {
            if event.right {
                connection.mouseButtonDown(.right, x: x, y: y)
            } else {
                connection.mouseButtonUp(.right, x: x, y: y)
            }
        }
        if event.middle != snapshot.middle {
            if event.middle {
                connection.mouseButtonDown(.middle, x: x, y: y)
            } else {
                connection.mouseButtonUp(.middle, x: x, y: y)
            }
        }
        connection.mouseMove(x: x, y: y)
    }

    public func sendKey(_ event: KeyEvent) async {
        guard let connection = state.currentConnection() else { return }
        for code in Self.keyCodes(for: event) {
            if event.down {
                connection.keyDown(code)
            } else {
                connection.keyUp(code)
            }
        }
    }

    public func sendClipboard(_ text: String) async {}

    public func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        switch connectionState.status {
        case .connected:
            state.takeConnectContinuation(markConnected: true)?.resume()
        case .disconnected:
            let snapshot = state.takeDisconnectSnapshot()
            if let continuation = snapshot.continuation {
                if snapshot.disconnectRequested {
                    continuation.resume()
                } else if let error = connectionState.error {
                    continuation.resume(throwing: Self.mapError(error, didConnect: snapshot.didConnect))
                } else {
                    continuation.resume(throwing: SessionFailure.handshakeFailed)
                }
            } else if snapshot.didConnect && !snapshot.disconnectRequested {
                frameContinuation.finish()
            }
            clipboardContinuation.finish()
        case .connecting, .disconnecting:
            break
        @unknown default:
            break
        }
    }

    public func connection(
        _ connection: VNCConnection,
        credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCCredential?) -> Void
    ) {
        if authenticationType.requiresUsername {
            completion(VNCUsernamePasswordCredential(username: credentials.username, password: credentials.password))
        } else if authenticationType.requiresPassword {
            completion(VNCPasswordCredential(password: credentials.password))
        } else {
            completion(nil)
        }
    }

    public func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {}

    public func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}

    public func connection(
        _ connection: VNCConnection,
        didUpdateFramebuffer framebuffer: VNCFramebuffer,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) {
        guard let image = framebuffer.cgImage, let frame = Self.rgbaFrame(from: image) else { return }
        frameContinuation.yield(frame)
    }

    public func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}

    private static func keyCodes(for event: KeyEvent) -> [VNCKeyCode] {
        if let special = specialKeyCode(event.macKeyCode) {
            return [special]
        }
        return VNCKeyCode.keyCodesFrom(characters: event.characters)
    }

    private static func specialKeyCode(_ macKeyCode: UInt16) -> VNCKeyCode? {
        switch macKeyCode {
        case 36: return .return
        case 48: return .tab
        case 49: return .space
        case 51: return .delete
        case 53: return .escape
        case 54: return .rightCommand
        case 55: return .command
        case 56: return .shift
        case 58: return .option
        case 59: return .control
        case 60: return .rightShift
        case 61: return .rightOption
        case 62: return .rightControl
        case 96: return .f5
        case 97: return .f6
        case 98: return .f7
        case 99: return .f3
        case 100: return .f8
        case 101: return .f9
        case 103: return .f11
        case 109: return .f10
        case 111: return .f12
        case 115: return .home
        case 116: return .pageUp
        case 117: return .forwardDelete
        case 118: return .f4
        case 119: return .end
        case 120: return .f2
        case 121: return .pageDown
        case 122: return .f1
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default: return nil
        }
    }

    private static func mapError(_ error: Error, didConnect: Bool) -> SessionFailure {
        guard let vncError = error as? VNCError else {
            return didConnect ? .dropped : mapConnectionFailure(error)
        }
        switch vncError {
        case .authentication:
            return .authenticationFailed
        case .connection(let connectionError):
            switch connectionError {
            case .closed:
                return didConnect ? .dropped : .handshakeFailed
            case .cancelled:
                return didConnect ? .dropped : .handshakeFailed
            case .closedDuringHandshake:
                return .handshakeFailed
            case .notReady:
                return .handshakeFailed
            case .failed(let underlying):
                if didConnect { return .dropped }
                return mapConnectionFailure(underlying)
            @unknown default:
                return didConnect ? .dropped : .handshakeFailed
            }
        case .protocol:
            return didConnect ? .dropped : .handshakeFailed
        @unknown default:
            return didConnect ? .dropped : .handshakeFailed
        }
    }

    private static func mapConnectionFailure(_ error: Error?) -> SessionFailure {
        guard let error else { return .connectionRefused }
        if let posix = posixCode(error) {
            switch posix {
            case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH:
                return .connectionRefused
            case ETIMEDOUT:
                return .timeout
            default:
                break
            }
        }
        let description = String(describing: error).lowercased()
        if description.contains("timed out") || description.contains("timeout") || description.contains("etimedout") {
            return .timeout
        }
        if description.contains("refused") || description.contains("econnrefused") {
            return .connectionRefused
        }
        return .connectionRefused
    }

    private static func posixCode(_ error: Error) -> Int32? {
        if let nwError = error as? NWError {
            if case .posix(let code) = nwError {
                return code.rawValue
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let posix = error as? POSIXError {
            return posix.code.rawValue
        }
        return nil
    }

    private static func rgbaFrame(from image: CGImage) -> FramebufferFrame? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let ok = data.withUnsafeMutableBytes { pointer in
            guard let base = pointer.baseAddress else { return false }
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            )
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                return false
            }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return FramebufferFrame(width: width, height: height, rgba: data)
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: VNCConnection?
        private var connectContinuation: CheckedContinuation<Void, Error>?
        private var disconnectRequested = false
        private var didConnect = false
        private var lastLeft = false
        private var lastRight = false
        private var lastMiddle = false

        func reset(connection: VNCConnection) {
            lock.lock()
            defer { lock.unlock() }
            self.connection = connection
            disconnectRequested = false
            didConnect = false
            lastLeft = false
            lastRight = false
            lastMiddle = false
        }

        func setConnectContinuation(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            connectContinuation = continuation
        }

        func markDisconnectRequested() -> VNCConnection? {
            lock.lock()
            defer { lock.unlock() }
            disconnectRequested = true
            return connection
        }

        func currentConnection() -> VNCConnection? {
            lock.lock()
            defer { lock.unlock() }
            return connection
        }

        func pointerSnapshot(updatingTo event: PointerEvent) -> (connection: VNCConnection?, left: Bool, right: Bool, middle: Bool) {
            lock.lock()
            defer { lock.unlock() }
            let snapshot = (connection, lastLeft, lastRight, lastMiddle)
            lastLeft = event.left
            lastRight = event.right
            lastMiddle = event.middle
            return snapshot
        }

        func takeConnectContinuation(markConnected: Bool) -> CheckedContinuation<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            if markConnected {
                didConnect = true
            }
            let continuation = connectContinuation
            connectContinuation = nil
            return continuation
        }

        func takeDisconnectSnapshot() -> (
            continuation: CheckedContinuation<Void, Error>?,
            disconnectRequested: Bool,
            didConnect: Bool
        ) {
            lock.lock()
            defer { lock.unlock() }
            let continuation = connectContinuation
            connectContinuation = nil
            return (continuation, disconnectRequested, didConnect)
        }
    }
}
