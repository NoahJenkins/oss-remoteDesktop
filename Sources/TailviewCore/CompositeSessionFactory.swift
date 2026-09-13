public struct CompositeSessionFactory: RemoteSessionFactory, @unchecked Sendable {
    public var vnc: (Endpoint, SessionCredentials) -> any RemoteSession
    public var rdp: ((Endpoint, SessionCredentials) throws -> any RemoteSession)?

    public init(
        vnc: @escaping (Endpoint, SessionCredentials) -> any RemoteSession,
        rdp: ((Endpoint, SessionCredentials) throws -> any RemoteSession)?
    ) {
        self.vnc = vnc
        self.rdp = rdp
    }

    public func makeSession(
        endpoint: Endpoint,
        desktopProtocol: DesktopProtocol,
        credentials: SessionCredentials
    ) throws -> any RemoteSession {
        switch desktopProtocol {
        case .vnc, .screenSharing:
            return vnc(endpoint, credentials)
        case .rdp:
            guard let rdp else { throw SessionFailure.rdpUnavailable }
            return try rdp(endpoint, credentials)
        }
    }
}
