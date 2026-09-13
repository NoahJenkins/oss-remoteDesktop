public enum PeerDirectory {
    public static func rows(selfNode: SelfNode, peers: [PeerSnapshot], profiles: [String: PeerProfile]) -> [PeerRow] {
        peers.compactMap { peer in
            guard peer.id != selfNode.id else { return nil }

            let displayName: String
            if peer.dnsName.isEmpty {
                displayName = peer.hostName
            } else if peer.dnsName.hasSuffix(".") {
                displayName = String(peer.dnsName.dropLast())
            } else {
                displayName = peer.dnsName
            }

            let host = Endpoint.preferredHost(ips: peer.tailscaleIPs)

            let desktopProtocol: DesktopProtocol?
            let port: UInt16?
            let connectable: Bool
            let heuristicReason: String?

            if let override = profiles[peer.id]?.protocolOverride {
                desktopProtocol = override.desktopProtocol
                port = override.port
                connectable = true
                heuristicReason = nil
            } else {
                switch ProtocolHeuristic.suggest(os: peer.os) {
                case .connectable(let proto, port: let suggestedPort):
                    desktopProtocol = proto
                    port = suggestedPort
                    connectable = true
                    heuristicReason = nil
                case .notConnectable(reason: let reason):
                    desktopProtocol = nil
                    port = nil
                    connectable = false
                    heuristicReason = reason
                }
            }

            let connectEnabled = peer.online && connectable && host != nil
            let disabledReason: String?
            if !peer.online {
                disabledReason = "Offline"
            } else if !connectable {
                disabledReason = heuristicReason
            } else {
                disabledReason = nil
            }

            return PeerRow(
                id: peer.id,
                displayName: displayName,
                os: peer.os,
                online: peer.online,
                host: host,
                connectEnabled: connectEnabled,
                disabledReason: disabledReason,
                desktopProtocol: desktopProtocol,
                port: port
            )
        }
    }
}
