import Foundation

public enum LocalAPIStatusParser {
    public static func parse(_ data: Data) throws -> TailscaleStatus {
        let decoded = try JSONDecoder().decode(StatusPayload.self, from: data)
        switch decoded.backendState {
        case "NeedsLogin", "NeedsMachineAuth":
            return .unavailable(.notLoggedIn)
        case "Running":
            guard let selfPayload = decoded.selfNode, let id = selfPayload.id else {
                return .unavailable(.notRunning)
            }
            let selfNode = SelfNode(id: id, hostName: selfPayload.hostName ?? "")
            let peers = (decoded.peer ?? [:]).values.compactMap { $0.peerSnapshot }
            return .running(selfNode: selfNode, peers: peers)
        default:
            return .unavailable(.notRunning)
        }
    }
}

private struct StatusPayload: Decodable {
    let backendState: String
    let selfNode: NodePayload?
    let peer: [String: NodePayload]?

    enum CodingKeys: String, CodingKey {
        case backendState = "BackendState"
        case selfNode = "Self"
        case peer = "Peer"
    }
}

private struct NodePayload: Decodable {
    let id: String?
    let hostName: String?
    let dnsName: String?
    let os: String?
    let online: Bool?
    let tailscaleIPs: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "ID"
        case hostName = "HostName"
        case dnsName = "DNSName"
        case os = "OS"
        case online = "Online"
        case tailscaleIPs = "TailscaleIPs"
    }

    var peerSnapshot: PeerSnapshot? {
        guard let id else { return nil }
        return PeerSnapshot(
            id: id,
            hostName: hostName ?? "",
            dnsName: dnsName ?? "",
            os: os ?? "",
            online: online ?? false,
            tailscaleIPs: tailscaleIPs ?? []
        )
    }
}
