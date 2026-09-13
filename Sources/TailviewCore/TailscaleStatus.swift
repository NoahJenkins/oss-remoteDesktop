public enum TailscaleUnavailability: Equatable, Sendable {
    case notRunning
    case notLoggedIn
}

public enum TailscaleStatus: Equatable, Sendable {
    case unavailable(TailscaleUnavailability)
    case running(selfNode: SelfNode, peers: [PeerSnapshot])
}
