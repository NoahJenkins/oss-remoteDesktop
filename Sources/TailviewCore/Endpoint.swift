public struct Endpoint: Equatable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public static func preferredHost(ips: [String]) -> String? {
        if let ipv4 = ips.first(where: { $0.contains(".") && !$0.contains(":") }) {
            return ipv4
        }
        return ips.first
    }
}
