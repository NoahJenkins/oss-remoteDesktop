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

public struct SelfNode: Equatable, Sendable {
    public var id: String
    public var hostName: String

    public init(id: String, hostName: String) {
        self.id = id
        self.hostName = hostName
    }
}

public struct PeerSnapshot: Equatable, Sendable {
    public var id: String
    public var hostName: String
    public var dnsName: String
    public var os: String
    public var online: Bool
    public var tailscaleIPs: [String]

    public init(id: String, hostName: String, dnsName: String, os: String, online: Bool, tailscaleIPs: [String]) {
        self.id = id
        self.hostName = hostName
        self.dnsName = dnsName
        self.os = os
        self.online = online
        self.tailscaleIPs = tailscaleIPs
    }
}

public struct PeerRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var os: String
    public var online: Bool
    public var host: String?
    public var connectEnabled: Bool
    public var disabledReason: String?
    public var desktopProtocol: DesktopProtocol?
    public var port: UInt16?

    public init(
        id: String,
        displayName: String,
        os: String,
        online: Bool,
        host: String?,
        connectEnabled: Bool,
        disabledReason: String?,
        desktopProtocol: DesktopProtocol?,
        port: UInt16?
    ) {
        self.id = id
        self.displayName = displayName
        self.os = os
        self.online = online
        self.host = host
        self.connectEnabled = connectEnabled
        self.disabledReason = disabledReason
        self.desktopProtocol = desktopProtocol
        self.port = port
    }
}
