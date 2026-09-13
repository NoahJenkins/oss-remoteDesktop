import Foundation

public struct SessionCredentials: Equatable, Sendable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct FramebufferFrame: Sendable {
    public var width: Int
    public var height: Int
    public var rgba: Data

    public init(width: Int, height: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

public struct PointerEvent: Sendable {
    public var x: Int
    public var y: Int
    public var left: Bool
    public var right: Bool
    public var middle: Bool

    public init(x: Int, y: Int, left: Bool, right: Bool, middle: Bool) {
        self.x = x
        self.y = y
        self.left = left
        self.right = right
        self.middle = middle
    }
}

public struct KeyEvent: Sendable {
    public var down: Bool
    public var macKeyCode: UInt16
    public var characters: String

    public init(down: Bool, macKeyCode: UInt16, characters: String) {
        self.down = down
        self.macKeyCode = macKeyCode
        self.characters = characters
    }
}

public enum SessionFailure: Equatable, Error, Sendable {
    case connectionRefused
    case timeout
    case handshakeFailed
    case authenticationFailed
    case dropped
    case rdpUnavailable
}

public protocol RemoteSession: AnyObject, Sendable {
    func connect() async throws
    func disconnect() async
    var frames: AsyncStream<FramebufferFrame> { get }
    var remoteClipboard: AsyncStream<String> { get }
    func sendPointer(_ event: PointerEvent) async
    func sendKey(_ event: KeyEvent) async
    func sendClipboard(_ text: String) async
}

public protocol RemoteSessionFactory: Sendable {
    func makeSession(
        endpoint: Endpoint,
        desktopProtocol: DesktopProtocol,
        credentials: SessionCredentials
    ) throws -> any RemoteSession
}
