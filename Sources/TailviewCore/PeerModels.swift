import Foundation

public struct ProtocolOverride: Equatable, Codable, Sendable {
    public var desktopProtocol: DesktopProtocol
    public var port: UInt16

    public init(desktopProtocol: DesktopProtocol, port: UInt16) {
        self.desktopProtocol = desktopProtocol
        self.port = port
    }
}

public struct PeerProfile: Equatable, Codable, Sendable {
    public var peerID: String
    public var protocolOverride: ProtocolOverride?
    public var lastUsed: Date?

    public init(peerID: String, protocolOverride: ProtocolOverride?, lastUsed: Date?) {
        self.peerID = peerID
        self.protocolOverride = protocolOverride
        self.lastUsed = lastUsed
    }
}
