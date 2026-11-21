import XCTest
@testable import LockgateCore

final class FilterPolicyTests: XCTestCase {
    private func policy() -> FilterPolicySnapshot {
        FilterPolicySnapshot(ownerUID: 501, blocked: false, protectDesktop: true, protectCLI: true,
            desktopRoots: ["/Applications/Claude.app/Contents"],
            cliPaths: ["/opt/claude", "/opt/node_modules/@anthropic-ai/claude-code/cli.js"],
            preferences: NetworkFilterPreferences())
    }

    func testDefaultsAreOptInAndValid() {
        let preferences = NetworkFilterPreferences()
        XCTAssertFalse(preferences.enabled)
        XCTAssertFalse(preferences.includeOtherApps)
        XCTAssertNil(preferences.validationError)
        XCTAssertFalse(preferences.addresses.isEmpty)
    }

    func testAddressBoundariesAndNormalization() {
        let wildcard = NetworkAddressRule("*.Claude.AI")!
        XCTAssertTrue(wildcard.matches("api.claude.ai."))
        XCTAssertFalse(wildcard.matches("claude.ai"))
        XCTAssertFalse(wildcard.matches("evilclaude.ai"))
        XCTAssertFalse(wildcard.matches("claude.ai.evil.com"))
        XCTAssertTrue(NetworkAddressRule("claude.ai")!.matches("CLAUDE.AI"))
        XCTAssertFalse(NetworkAddressRule("claude.ai")!.matches("api.claude.ai"))
        XCTAssertTrue(NetworkAddressRule("2001:db8::1")!.matches("2001:0db8:0:0:0:0:0:1"))
        for invalid in ["https://claude.ai", "claude.ai:443", "claude.ai/path", "*claude.ai", "-bad.com", "256.0.0.1", ""] {
            XCTAssertNil(NetworkAddressRule(invalid), invalid)
        }
    }

    func testBlankEditorLinesAndRuleLimit() {
        var preferences = NetworkFilterPreferences()
        preferences.addresses = ["", "  ", "claude.ai"]
        XCTAssertNil(preferences.validationError)
        preferences.addresses = Array(repeating: "claude.ai", count: 201)
        XCTAssertNotNil(preferences.validationError)
    }

    func testSelectedProcessesIncludingLocalProxy() {
        let snapshot = policy()
        XCTAssertTrue(snapshot.protects(uid: 501, executable: "/opt/claude", entrypoint: nil, hostname: nil, ip: "127.0.0.1"))
        XCTAssertTrue(snapshot.protects(uid: 501, executable: "/Applications/Claude.app/Contents/MacOS/Claude", entrypoint: nil, hostname: nil, ip: nil))
        XCTAssertFalse(snapshot.protects(uid: 501, executable: "/Applications/Claude.app/ContentsFake/Claude", entrypoint: nil, hostname: nil, ip: nil))
        XCTAssertFalse(snapshot.protects(uid: 502, executable: "/opt/claude", entrypoint: nil, hostname: nil, ip: nil))
        XCTAssertFalse(snapshot.protects(uid: nil, executable: "/opt/claude", entrypoint: nil, hostname: nil, ip: nil))
        XCTAssertTrue(snapshot.protects(uid: 501, executable: "/usr/bin/node", entrypoint: "/opt/node_modules/@anthropic-ai/claude-code/cli.js", hostname: nil, ip: nil))
        XCTAssertFalse(snapshot.protects(uid: 501, executable: "/usr/bin/node", entrypoint: "/tmp/cli.js", hostname: nil, ip: nil))
    }

    func testOtherApplicationsRequireExplicitOptIn() {
        var snapshot = policy()
        XCTAssertFalse(snapshot.protects(uid: 501, executable: "/opt/browser", entrypoint: nil, hostname: "claude.ai", ip: nil))
        snapshot.preferences.includeOtherApps = true
        XCTAssertTrue(snapshot.protects(uid: 501, executable: nil, entrypoint: nil, hostname: "claude.ai", ip: nil))
        XCTAssertFalse(snapshot.protects(uid: 501, executable: nil, entrypoint: nil, hostname: "example.com", ip: nil))
        XCTAssertFalse(snapshot.protects(uid: 502, executable: nil, entrypoint: nil, hostname: "claude.ai", ip: nil))
        snapshot.protectCLI = false
        XCTAssertFalse(snapshot.protects(uid: 501, executable: "/opt/claude", entrypoint: nil, hostname: nil, ip: "127.0.0.1"))
    }

    func testLeaseStartsClosedExpiresAndRecoversOnlyWithNewPolicy() {
        var snapshot = policy()
        var lease = FilterLease(policy: snapshot)
        XCTAssertTrue(lease.shouldBlock(uptime: 10))
        lease.receive(snapshot, uptime: 10)
        XCTAssertFalse(lease.shouldBlock(uptime: 17.9))
        XCTAssertTrue(lease.shouldBlock(uptime: 18))
        XCTAssertTrue(lease.shouldBlock(uptime: 9))
        snapshot.blocked = true
        lease.receive(snapshot, uptime: 20)
        XCTAssertTrue(lease.shouldBlock(uptime: 20))
        snapshot.blocked = false
        lease.receive(snapshot, uptime: 30)
        XCTAssertFalse(lease.shouldBlock(uptime: 30))
    }

    func testLaunchNeedsFreshFilterAcknowledgement() {
        var state = ProtectionState()
        let now = Date()
        state.enabled = true
        state.heartbeat = now
        XCTAssertTrue(state.permitsLaunch(.allow, now: now))
        state.settings.filterPreferences.enabled = true
        XCTAssertFalse(state.permitsLaunch(.allow, now: now))
        state.filterReadyUntil = now.addingTimeInterval(4)
        XCTAssertTrue(state.permitsLaunch(.allow, now: now))
        XCTAssertFalse(state.permitsLaunch(.allow, now: now.addingTimeInterval(4)))
        state.filterReadyUntil = now.addingTimeInterval(30)
        XCTAssertFalse(state.permitsLaunch(.allow, now: now))
        state.filterReadyUntil = now.addingTimeInterval(4)
        state.lockedReason = "unsafe exit"
        XCTAssertFalse(state.permitsLaunch(.allow, now: now))
    }

    func testOldStateLoadsWithFilterDisabled() throws {
        let encoded = try JSONEncoder().encode(ProtectionState())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "filterReadyUntil")
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "networkFilter")
        object["settings"] = settings
        let restored = try JSONDecoder().decode(ProtectionState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(restored.settings.filterPreferences.enabled)
        XCTAssertNil(restored.filterReadyUntil)
        let snapshot = policy()
        XCTAssertEqual(try JSONDecoder().decode(FilterPolicySnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }
}
