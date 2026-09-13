import Testing
@testable import TailviewCore

struct EndpointTests {
    @Test func prefersIPv4OverIPv6() {
        let host = Endpoint.preferredHost(ips: ["fd7a:115c:a1e0::2", "100.64.0.2"])
        #expect(host == "100.64.0.2")
    }

    @Test func usesIPv6WhenNoIPv4() {
        #expect(Endpoint.preferredHost(ips: ["fd7a:115c:a1e0::2"]) == "fd7a:115c:a1e0::2")
    }

    @Test func emptyReturnsNil() {
        #expect(Endpoint.preferredHost(ips: []) == nil)
    }
}
