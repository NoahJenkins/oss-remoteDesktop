public enum ListModel: Equatable, Sendable {
    case ready([PeerRow])
    case notRunning
    case notLoggedIn

    public static func from(status: TailscaleStatus, profiles: [String: PeerProfile]) -> ListModel {
        switch status {
        case .unavailable(.notRunning):
            return .notRunning
        case .unavailable(.notLoggedIn):
            return .notLoggedIn
        case .running(let selfNode, let peers):
            return .ready(PeerDirectory.rows(selfNode: selfNode, peers: peers, profiles: profiles))
        }
    }
}
