import Foundation
import Testing
import TailviewCore
@testable import TailviewRDP

struct RDPSessionTests {
    @Test func unknownConnectErrorIsHandshakeFailed() {
        struct Boom: Error {}
        #expect(RDPSession.mapConnectError(Boom()) == .handshakeFailed)
    }

    @Test func rdpUnavailableIsNotUsedForGenericConnectFailure() {
        struct Boom: Error {}
        #expect(RDPSession.mapConnectError(Boom()) != .rdpUnavailable)
    }

    @Test func rdpErrorStillMapsToSessionFailure() {
        #expect(RDPSession.mapConnectError(RdpError.ConnectionRefused(message: "x")) == .connectionRefused)
        #expect(RDPSession.mapConnectError(RdpError.Timeout(message: "x")) == .timeout)
        #expect(RDPSession.mapConnectError(RdpError.HandshakeFailed(message: "x")) == .handshakeFailed)
        #expect(RDPSession.mapConnectError(RdpError.AuthenticationFailed(message: "x")) == .authenticationFailed)
        #expect(RDPSession.mapConnectError(RdpError.Dropped(message: "x")) == .dropped)
    }
}
