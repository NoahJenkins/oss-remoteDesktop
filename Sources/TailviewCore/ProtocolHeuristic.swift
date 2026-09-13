public enum ProtocolSuggestion: Equatable, Sendable {
    case connectable(DesktopProtocol, port: UInt16)
    case notConnectable(reason: String)
}

public enum ProtocolHeuristic {
    public static func suggest(os: String) -> ProtocolSuggestion {
        switch os.lowercased() {
        case "macos":
            return .connectable(.screenSharing, port: 5900)
        case "linux":
            return .connectable(.vnc, port: 5900)
        case "windows":
            return .connectable(.rdp, port: 3389)
        case "ios":
            return .notConnectable(reason: "iOS devices cannot host a desktop session")
        case "android":
            return .notConnectable(reason: "Android devices cannot host a desktop session")
        default:
            return .notConnectable(reason: "No desktop protocol for OS \(os)")
        }
    }

    public static func failover(from desktopProtocol: DesktopProtocol) -> (DesktopProtocol, UInt16) {
        switch desktopProtocol {
        case .vnc, .screenSharing:
            return (.rdp, 3389)
        case .rdp:
            return (.vnc, 5900)
        }
    }
}
