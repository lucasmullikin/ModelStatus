import XCTest
@testable import ModelStatus

/// v1.0.1: Tests for `Discovery.shouldFilterOut(host:ownIPs:)` — the link-local
/// + self-IP filter introduced to keep ghost entries (auto-config 169.254.X.Y,
/// IPv6 link-local fe80::, the user's own Tailscale ULA reflecting via mDNS)
/// out of the Discovery results sheet.
///
/// The filter is a pure function — these tests verify the logic without
/// needing the actual network-interface enumeration.
final class DiscoveryTests: XCTestCase {

    func testFiltersIPv4LinkLocal() {
        let own: Set<String> = []
        XCTAssertTrue(Discovery.shouldFilterOut(host: "169.254.0.1", ownIPs: own))
        XCTAssertTrue(Discovery.shouldFilterOut(host: "169.254.226.184", ownIPs: own))
        XCTAssertTrue(Discovery.shouldFilterOut(host: "169.254.255.254", ownIPs: own))
    }

    func testDoesNotFilterNonLinkLocalIPv4() {
        let own: Set<String> = []
        // 169.255.X.X is OUTSIDE the link-local range — must NOT be filtered
        XCTAssertFalse(Discovery.shouldFilterOut(host: "169.255.0.1", ownIPs: own))
        XCTAssertFalse(Discovery.shouldFilterOut(host: "168.254.0.1", ownIPs: own))
        // Common LAN ranges — explicitly allowed
        XCTAssertFalse(Discovery.shouldFilterOut(host: "192.168.1.42", ownIPs: own))
        XCTAssertFalse(Discovery.shouldFilterOut(host: "10.0.0.5", ownIPs: own))
        XCTAssertFalse(Discovery.shouldFilterOut(host: "172.16.0.1", ownIPs: own))
        // Tailscale CGNAT range (100.64.0.0/10) — explicitly allowed (these are
        // useful Tailnet peers, just not the user's own machine)
        XCTAssertFalse(Discovery.shouldFilterOut(host: "100.100.100.100", ownIPs: own))
    }

    func testFiltersIPv6LinkLocal() {
        let own: Set<String> = []
        // fe80::/10 — RFC 4291 IPv6 link-local
        XCTAssertTrue(Discovery.shouldFilterOut(host: "fe80::1", ownIPs: own))
        XCTAssertTrue(Discovery.shouldFilterOut(host: "fe80::cafe:beef", ownIPs: own))
        XCTAssertTrue(Discovery.shouldFilterOut(host: "fe80:7::1489:4eff:fe43:3537", ownIPs: own))
        // Case-insensitive — IPv6 addresses can be written in either case
        XCTAssertTrue(Discovery.shouldFilterOut(host: "FE80::1", ownIPs: own))
    }

    func testDoesNotFilterNonLinkLocalIPv6() {
        let own: Set<String> = []
        // Tailscale IPv6 ULA prefix fd7a:115c:a1e0::/48 — NOT link-local,
        // legitimate peer addresses. Must NOT be filtered unless the address
        // matches the user's own machine (covered by testFiltersSelfIPs below).
        XCTAssertFalse(Discovery.shouldFilterOut(host: "fd7a:115c:a1e0::1", ownIPs: own))
        XCTAssertFalse(Discovery.shouldFilterOut(host: "fd7a:115c:a1e0::cafe", ownIPs: own))
        // Other ULA / global-unicast prefixes
        XCTAssertFalse(Discovery.shouldFilterOut(host: "fc00::1", ownIPs: own))
        XCTAssertFalse(Discovery.shouldFilterOut(host: "2001:db8::1", ownIPs: own))
    }

    func testFiltersSelfIPs() {
        // Mac with both an IPv4 LAN address and an IPv6 Tailscale ULA on its
        // own interfaces — Discovery should filter both out so they don't
        // show as "discoverable servers."
        let own: Set<String> = [
            "192.168.1.2",
            "fd7a:115c:a1e0::7d3b:2a72",
        ]
        XCTAssertTrue(Discovery.shouldFilterOut(host: "192.168.1.2", ownIPs: own))
        XCTAssertTrue(Discovery.shouldFilterOut(host: "fd7a:115c:a1e0::7d3b:2a72", ownIPs: own))
        // Different addresses on the same subnet — must NOT be filtered
        XCTAssertFalse(Discovery.shouldFilterOut(host: "192.168.1.3", ownIPs: own))
        XCTAssertFalse(Discovery.shouldFilterOut(host: "fd7a:115c:a1e0::cafe", ownIPs: own))
    }

    func testFiltersLoopbackAliases() {
        let own: Set<String> = []
        XCTAssertTrue(Discovery.shouldFilterOut(host: "127.0.0.1", ownIPs: own))
        XCTAssertTrue(Discovery.shouldFilterOut(host: "localhost", ownIPs: own))
        XCTAssertTrue(Discovery.shouldFilterOut(host: "::1", ownIPs: own))
        // Case-insensitive — "Localhost" should also be filtered
        XCTAssertTrue(Discovery.shouldFilterOut(host: "Localhost", ownIPs: own))
    }

    func testStripsBracketsFromIPv6BeforeSelfCompare() {
        // Discovered hosts shouldn't have brackets but Discovery is defensive
        // about it — a host like "[fd7a:...]" should still match the bracketless
        // own-IP in the set.
        let own: Set<String> = ["fd7a:115c:a1e0::1"]
        XCTAssertTrue(Discovery.shouldFilterOut(host: "[fd7a:115c:a1e0::1]", ownIPs: own))
    }

    func testRealWorldExampleFromUser() {
        // The actual ghost entries the user saw in v1.0.0 when clicking
        // Discover — both should now be filtered post-v1.0.1.
        let own: Set<String> = [
            "fd7a:115c:a1e0::7d3b:2a72",
        ]
        XCTAssertTrue(Discovery.shouldFilterOut(
            host: "169.254.226.184", ownIPs: own),
            "IPv4 link-local from disconnected interface")
        XCTAssertTrue(Discovery.shouldFilterOut(
            host: "fd7a:115c:a1e0::7d3b:2a72", ownIPs: own),
            "User's own Tailscale ULA reflecting via mDNS")
    }
}
