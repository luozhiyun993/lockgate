import XCTest
@testable import LockgateCore

final class CoreGateTests: XCTestCase {
    private func runtime(_ gate: [String]?, mode: ProxyMode = .rule) -> CoreRuntime {
        CoreRuntime(mixedPort: 17890, controllerPort: 51234, secret: "s", mode: mode, tun: false, gate: gate)
    }

    private let gateItem = #"{"name":"LOCKGATE-GATE","proxies":["REJECT","PASS"],"type":"select"}"#

    func testGateRulesKeepAddressSemantics() {
        XCTAssertEqual(ProfileComposer.gateRules(["claude.ai", "*.Claude.ai", "203.0.113.7", "2001:4860::1", "claude.ai", "not a host", ""]), [
            "DOMAIN,claude.ai,LOCKGATE-GATE",
            #"DOMAIN-REGEX,^.+\.claude\.ai$,LOCKGATE-GATE"#,
            "IP-CIDR,203.0.113.7/32,LOCKGATE-GATE,no-resolve",
            "IP-CIDR6,2001:4860::1/128,LOCKGATE-GATE,no-resolve"
        ])
    }

    func testGateDefaultsToRejectSoRestartAndReloadFailClosed() throws {
        let composed = ProfileComposer.compose(providerPath: "./p.txt", runtime: runtime(["claude.ai"]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(composed.utf8)) as? [String: Any])
        let group = try XCTUnwrap((object["proxy-groups"] as? [[String: Any]])?.first)
        XCTAssertEqual(group["name"] as? String, ProfileComposer.gateGroup)
        XCTAssertEqual(group["proxies"] as? [String], ["REJECT", "PASS"])
        XCTAssertEqual((object["rules"] as? [String])?.first, "DOMAIN,claude.ai,LOCKGATE-GATE")
    }

    func testInsertionIntoBlockListsKeepsIndentation() {
        let indented = "proxies: []\nrules:\n    # 注释\n    - MATCH,PROXY\nother: 1\n"
        XCTAssertEqual(ProfileComposer.inserting(["A", "B"], intoList: "rules", of: indented),
                       "proxies: []\nrules:\n    - \"A\"\n    - \"B\"\n    # 注释\n    - MATCH,PROXY\nother: 1\n")
        let flush = "rules:\n- MATCH,PROXY\n"
        XCTAssertEqual(ProfileComposer.inserting(["A"], intoList: "rules", of: flush), "rules:\n- \"A\"\n- MATCH,PROXY\n")
    }

    func testInsertionIntoFlowEmptyNullAndMissingLists() {
        XCTAssertEqual(ProfileComposer.inserting(["A"], intoList: "rules", of: "rules: [\"MATCH,PROXY\"]\n"),
                       "rules: [\"A\", \"MATCH,PROXY\"]\n")
        XCTAssertEqual(ProfileComposer.inserting(["A"], intoList: "rules", of: "rules: []\n"), "rules: [\"A\"]\n")
        XCTAssertEqual(ProfileComposer.inserting(["A"], intoList: "rules", of: "rules: [\n  \"MATCH,PROXY\"\n]\n"),
                       "rules: [\"A\", \n  \"MATCH,PROXY\"\n]\n")
        XCTAssertEqual(ProfileComposer.inserting(["A"], intoList: "rules", of: "rules: null\nx: 1\n"), "rules:\n  - \"A\"\nx: 1\n")
        XCTAssertEqual(ProfileComposer.inserting(["A"], intoList: "rules", of: "rules: # 空\nx: 1\n"), "rules: # 空\n  - \"A\"\nx: 1\n")
        XCTAssertEqual(ProfileComposer.inserting(["A"], intoList: "rules", of: "proxies: []"), "proxies: []\nrules:\n  - \"A\"\n")
        XCTAssertEqual(ProfileComposer.inserting([], intoList: "rules", of: "proxies: []"), "proxies: []")
    }

    func testProfileComposeInjectsGateFirstAndForcesRuleMode() throws {
        let profile = "proxies:\n  - {name: a, type: direct}\nproxy-groups:\n  - {name: PROXY, type: select, proxies: [a]}\nrules:\n  - MATCH,PROXY\n"
        let gated = try ProfileComposer.compose(profile: profile, runtime: runtime(["claude.ai", "*.claude.ai"], mode: .global))
        XCTAssertTrue(gated.contains("proxy-groups:\n  - \(gateItem)\n  - {name: PROXY"))
        XCTAssertTrue(gated.contains("rules:\n  - \"DOMAIN,claude.ai,LOCKGATE-GATE\"\n  - \"DOMAIN-REGEX,^.+\\\\.claude\\\\.ai$,LOCKGATE-GATE\"\n  - MATCH,PROXY"))
        XCTAssertTrue(gated.contains("mode: \"rule\""), "全局模式不经过规则，阻断开启时必须固定为规则模式")
        let keys = ProfileComposer.topLevelKeys(in: gated)
        XCTAssertEqual(Set(keys).count, keys.count)

        let open = try ProfileComposer.compose(profile: profile, runtime: runtime(nil, mode: .global))
        XCTAssertFalse(open.contains(ProfileComposer.gateGroup))
        XCTAssertTrue(open.contains("mode: \"global\""))

        let json = try ProfileComposer.compose(profile: #"{"proxies":[],"rules":["MATCH,DIRECT"]}"#, runtime: runtime(["claude.ai"]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["rules"] as? [String], ["DOMAIN,claude.ai,LOCKGATE-GATE", "MATCH,DIRECT"])
        XCTAssertEqual((object["proxy-groups"] as? [[String: Any]])?.count, 1)
    }

    func testPreferencesStayCompatibleAndGateRequiresFreshAcknowledgement() throws {
        let legacy = try JSONDecoder().decode(NetworkFilterPreferences.self,
            from: Data(#"{"enabled":false,"includeOtherApps":false,"addresses":["claude.ai"]}"#.utf8))
        XCTAssertFalse(legacy.gateEnabled)
        var preferences = legacy
        preferences.gateEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(NetworkFilterPreferences.self, from: JSONEncoder().encode(preferences)).gateEnabled)

        var state = ProtectionState()
        state.enabled = true
        state.heartbeat = Date()
        XCTAssertTrue(state.permitsLaunch(.allow))
        state.settings.filterPreferences = preferences
        XCTAssertFalse(state.permitsLaunch(.allow), "内核阻断开启后，没有放行确认不能启动")
        state.filterReadyUntil = Date().addingTimeInterval(3)
        XCTAssertTrue(state.permitsLaunch(.allow))
        state.filterReadyUntil = Date().addingTimeInterval(-1)
        XCTAssertFalse(state.permitsLaunch(.allow))
    }

    /// 设置 LOCKGATE_MIHOMO 为内核路径时，用真实内核校验带阻断规则的配置。
    func testGatedConfigsPassRealCoreValidation() throws {
        guard let path = ProcessInfo.processInfo.environment["LOCKGATE_MIHOMO"] else {
            throw XCTSkip("未设置 LOCKGATE_MIHOMO，跳过真实内核校验。")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("ss://YWVzLTEyOC1nY206eA@192.0.2.9:8388#n\n".utf8).base64EncodedData().write(to: home.appendingPathComponent("p.txt"))
        let gate = NetworkFilterPreferences.defaultAddresses + ["203.0.113.7", "2001:4860::1"]
        let node = "proxies:\n  - {name: a, type: ss, server: 192.0.2.1, port: 8388, cipher: aes-128-gcm, password: x}\n"
        let profiles = [
            node + "proxy-groups:\n  - {name: PROXY, type: select, proxies: [a]}\nrules:\n  - MATCH,PROXY\n",
            node + "rules: [\"MATCH,a\"]\n",
            node,
            #"{"proxies":[{"name":"a","type":"direct"}],"rules":["MATCH,a"]}"#
        ]
        var configs = try profiles.map { try ProfileComposer.compose(profile: $0, runtime: runtime(gate)) }
        configs.append(ProfileComposer.compose(providerPath: "./p.txt", runtime: runtime(gate)))
        for (index, config) in configs.enumerated() {
            let url = home.appendingPathComponent("config-\(index).yaml")
            try Data(config.utf8).write(to: url)
            let result = Command.run(path, ["-t", "-d", home.path, "-f", url.path])
            XCTAssertEqual(result.status, 0, "config \(index): \(result.output)")
        }
    }
}
