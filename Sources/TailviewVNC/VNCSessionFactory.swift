import TailviewCore

public enum VNCSessionFactory {
    public static func makeSession(endpoint: Endpoint, credentials: SessionCredentials) -> any RemoteSession {
        VNCSession(endpoint: endpoint, credentials: credentials)
    }
}

public struct DefaultSessionFactory: RemoteSessionFactory {
    public init() {}

    public func makeSession(
        endpoint: Endpoint,
        desktopProtocol: DesktopProtocol,
        credentials: SessionCredentials
    ) throws -> any RemoteSession {
        try CompositeSessionFactory(vnc: VNCSessionFactory.makeSession, rdp: nil)
            .makeSession(endpoint: endpoint, desktopProtocol: desktopProtocol, credentials: credentials)
    }
}
