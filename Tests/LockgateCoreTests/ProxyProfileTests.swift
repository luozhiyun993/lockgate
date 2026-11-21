import XCTest
@testable import LockgateCore

final class ProxyProfileTests: XCTestCase {
    private let runtime = CoreRuntime(mixedPort: 17890, controllerPort: 51234, secret: "secret-value", mode: .rule, tun: true)

    private let profile = """
    # 订阅示例
    port: 7890
    "socks-port": 7891
    allow-lan: true
    external-controller: 0.0.0.0:9090
    secret: leaked
    tun:
      enable: false
      dns-hijack:
        - any:53
    dns:
      enable: true
      nameserver:
      - 8.8.8.8
    proxies:
      - {name: "节点 A", type: ss, server: 192.0.2.1, port: 8388, cipher: aes-128-gcm, password: "mode: x"}
    proxy-groups:
    - name: PROXY
      type: select
      proxies: ["节点 A"]
    rules:
      - MATCH,PROXY
    """

    func testStrippingRemovesWholeManagedBlocksAndKeepsTheRest() {
        let stripped = ProfileComposer.stripping(profile, keys: ProfileComposer.managedKeys)
        XCTAssertEqual(ProfileComposer.topLevelKeys(in: stripped), ["proxies", "proxy-groups", "rules"])
        XCTAssertFalse(stripped.contains("9090"))
        XCTAssertFalse(stripped.contains("leaked"))
        XCTAssertFalse(stripped.contains("8.8.8.8"))
        XCTAssertFalse(stripped.contains("any:53"))
        XCTAssertTrue(stripped.contains("password: \"mode: x\""))
        XCTAssertTrue(stripped.contains("- name: PROXY"))
        XCTAssertTrue(stripped.contains("- MATCH,PROXY"))
    }

    func testComposeAppendsEachManagedKeyExactlyOnce() throws {
        let composed = try ProfileComposer.compose(profile: profile, runtime: runtime)
        let keys = ProfileComposer.topLevelKeys(in: composed)
        XCTAssertEqual(Set(keys).count, keys.count, "顶层键重复会让内核拒绝加载")
        XCTAssertTrue(composed.contains("mixed-port: 17890"))
        XCTAssertTrue(composed.contains("allow-lan: false"))
        XCTAssertTrue(composed.contains("external-controller: \"127.0.0.1:51234\""))
        XCTAssertTrue(composed.contains("secret: \"secret-value\""))
        XCTAssertTrue(composed.contains("\"enable\":true"))
        XCTAssertFalse(composed.contains("0.0.0.0"))
    }

    func testComposeHandlesCRLFAndByteOrderMark() throws {
        let windows = "\u{FEFF}" + profile.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try ProfileComposer.compose(profile: windows, runtime: runtime),
                       try ProfileComposer.compose(profile: profile, runtime: runtime))
    }

    func testComposeMergesFlowStyleJSONProfile() throws {
        let source = #"{"port":7890,"external-controller":"0.0.0.0:9090","proxies":[{"name":"a","type":"direct"}],"rules":["MATCH,a"]}"#
        let composed = try ProfileComposer.compose(profile: source, runtime: runtime)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(composed.utf8)) as? [String: Any])
        XCTAssertNil(object["port"])
        XCTAssertEqual(object["external-controller"] as? String, "127.0.0.1:51234")
        XCTAssertEqual(object["mixed-port"] as? Int, 17890)
        XCTAssertEqual((object["proxies"] as? [[String: Any]])?.count, 1)
    }

    func testKindDetection() {
        XCTAssertEqual(ProfileComposer.kind(of: profile), .profile)
        XCTAssertEqual(ProfileComposer.kind(of: "proxy-providers:\n  a: {type: http}\n"), .profile)
        XCTAssertEqual(ProfileComposer.kind(of: "ss://YWVzLTEyOC1nY206eA@192.0.2.9:8388#n\nvmess://abc"), .provider)
        let encoded = Data("ss://YWVzLTEyOC1nY206eA@192.0.2.9:8388#n\n".utf8).base64EncodedString()
        XCTAssertEqual(ProfileComposer.kind(of: encoded + "\n"), .provider)
        XCTAssertNil(ProfileComposer.kind(of: "<html><body>403</body></html>"))
        XCTAssertNil(ProfileComposer.kind(of: "   \n"))
        XCTAssertNil(ProfileComposer.kind(of: "just some text"))
        XCTAssertNil(ProfileComposer.kind(of: #"{"message":"token invalid"}"#))
        XCTAssertThrowsError(try ProfileComposer.compose(profile: "rules:\n  - MATCH,DIRECT\n", runtime: runtime))
    }

    func testProviderConfigRoutesEverythingExceptPrivateAddresses() throws {
        let composed = ProfileComposer.compose(providerPath: "./providers/subscription.txt", runtime: runtime)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(composed.utf8)) as? [String: Any])
        let rules = try XCTUnwrap(object["rules"] as? [String])
        XCTAssertEqual(rules.last, "MATCH,PROXY")
        XCTAssertTrue(rules.contains("IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"))
        XCTAssertEqual((object["proxy-groups"] as? [[String: Any]])?.first?["name"] as? String, "PROXY")
        XCTAssertEqual(object["allow-lan"] as? Bool, false)
    }

    func testSubscriptionUsageHeader() {
        let usage = SubscriptionUsage.parse("upload=1024; download=2048; total=1073741824; expire=1900000000")
        XCTAssertEqual(usage?.upload, 1024)
        XCTAssertEqual(usage?.download, 2048)
        XCTAssertEqual(usage?.total, 1_073_741_824)
        XCTAssertEqual(usage?.expire, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertTrue(usage?.summary.contains("3.0 KB / 1.0 GB") ?? false)
        XCTAssertNil(SubscriptionUsage.parse("upload=1; total=2; expire=0")?.expire)
        XCTAssertNil(SubscriptionUsage.parse(nil))
        XCTAssertNil(SubscriptionUsage.parse("garbage"))
    }

    func testSubscriptionURLValidation() {
        XCTAssertNotNil(Subscription.validatedURL(" https://example.com/sub?token=abc "))
        XCTAssertNotNil(Subscription.validatedURL("http://example.com/sub"))
        XCTAssertNil(Subscription.validatedURL("file:///etc/passwd"))
        XCTAssertNil(Subscription.validatedURL("https://"))
        XCTAssertNil(Subscription.validatedURL("example.com/sub"))
        XCTAssertNil(Subscription.validatedURL("https://example.com/a b"))
        XCTAssertEqual(Subscription(name: "a", url: "https://example.com/sub?token=abc").displayHost, "example.com")
    }

    func testSettingsDecodeFillsDefaultsAndRoundTrips() throws {
        let decoded = try JSONDecoder().decode(ProxySettings.self, from: Data(#"{"tun":true}"#.utf8))
        XCTAssertTrue(decoded.tun)
        XCTAssertTrue(decoded.systemProxy)
        XCTAssertEqual(decoded.mixedPort, 17890)
        XCTAssertEqual(decoded.mode, .rule)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(directory: directory)
        var settings = ProxySettings()
        let subscription = Subscription(name: "测试", url: "https://example.com/sub?token=abc", kind: .provider)
        settings.subscriptions = [subscription]
        settings.activeSubscription = subscription.id
        settings.selections[subscription.id.uuidString] = ["PROXY": "节点 A"]
        try store.save(settings)
        try store.saveProfile(Data("x".utf8), id: subscription.id)
        XCTAssertEqual(try store.load(), settings)
        XCTAssertEqual(try store.load().active, subscription)
        for path in [store.url.path, store.profileURL(subscription.id).path] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testSystemProxyPlan() {
        let listing = "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Thunderbolt Bridge\nUSB 10/100/1000 LAN\n"
        XCTAssertEqual(SystemProxyPlan.services(from: listing), ["Wi-Fi", "USB 10/100/1000 LAN"])
        XCTAssertTrue(SystemProxyPlan.enableCommands(service: "Wi-Fi", port: 17890)
            .contains(["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "17890"]))
        XCTAssertTrue(SystemProxyPlan.pointsToCore(["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 17890], port: 17890))
        XCTAssertFalse(SystemProxyPlan.pointsToCore(["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890], port: 17890))
        XCTAssertFalse(SystemProxyPlan.pointsToCore(["HTTPSEnable": 0, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 17890], port: 17890))
        for pattern in SystemProxyPlan.bypass where pattern != "localhost" && pattern != "*.local" {
            XCTAssertTrue(SystemProxyPlan.isLocalBypass(pattern), pattern)
        }
        for pattern in ["0.0.0.0/0", "8.8.8.8", "160.79.104.0/23", "10.0.0.0/4", "*.anthropic.com", "192.168.*",
                        "198.18.0.1", "198.18.0.0/15", "0.0.0.0", "172.32.0.1", "2001:db8::1"] {
            XCTAssertFalse(SystemProxyPlan.isLocalBypass(pattern), pattern)
        }
    }

    func testLockgateSystemProxyIsAcceptedByTheGuard() {
        let values: [String: Any] = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 17890,
                                     "ExceptionsList": SystemProxyPlan.bypass]
        XCTAssertEqual(SystemProxyParser.parse(values), .https(ProxyEndpoint(host: "127.0.0.1", port: 17890)!))
        var risky = values
        risky["ExceptionsList"] = SystemProxyPlan.bypass + ["160.79.104.0/23"]
        guard case .unsupported = SystemProxyParser.parse(risky) else { return XCTFail("公网网段绕过必须保持不可确认") }
    }

    func testCoreReleaseSelection() throws {
        func release(_ assets: [[String: Any]], extra: [String: Any] = [:]) -> Data {
            var object: [String: Any] = ["tag_name": "v1.19.34", "assets": assets]
            for (key, value) in extra { object[key] = value }
            return try! JSONSerialization.data(withJSONObject: object)
        }
        let hash = String(repeating: "ab", count: 32)
        let base = "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.34/"
        let arm = ["name": "mihomo-darwin-arm64-v1.19.34.gz", "browser_download_url": base + "mihomo-darwin-arm64-v1.19.34.gz",
                   "digest": "sha256:" + hash.uppercased()]
        let intel = ["name": "mihomo-darwin-amd64-compatible-v1.19.34.gz",
                     "browser_download_url": base + "mihomo-darwin-amd64-compatible-v1.19.34.gz", "digest": "sha256:" + hash]
        let go = ["name": "mihomo-darwin-arm64-go124-v1.19.34.gz", "browser_download_url": base + "x.gz", "digest": "sha256:" + hash]

        let selected = try XCTUnwrap(CoreRelease.parse(release([go, intel, arm]), architecture: "arm64"))
        XCTAssertEqual(selected.name, "mihomo-darwin-arm64-v1.19.34.gz")
        XCTAssertEqual(selected.sha256, hash)
        XCTAssertEqual(CoreRelease.parse(release([go, intel, arm]), architecture: "x86_64")?.name,
                       "mihomo-darwin-amd64-compatible-v1.19.34.gz")
        XCTAssertNil(CoreRelease.parse(release([go, intel]), architecture: "arm64"))
        XCTAssertNil(CoreRelease.parse(release([arm], extra: ["prerelease": true]), architecture: "arm64"))
        var unsigned = arm
        unsigned["digest"] = nil
        XCTAssertNil(CoreRelease.parse(release([unsigned]), architecture: "arm64"), "没有校验值的内核不能安装")
        var foreign = arm
        foreign["browser_download_url"] = "https://example.com/mihomo-darwin-arm64-v1.19.34.gz"
        XCTAssertNil(CoreRelease.parse(release([foreign]), architecture: "arm64"))
    }

    func testCoreVersionParsingAndComparison() {
        XCTAssertEqual(CoreRelease.version(fromOutput: "Mihomo Meta v1.19.34 darwin arm64 with go1.26.11 Wed Nov 11\nUse tags: with_gvisor"), "v1.19.34")
        XCTAssertNil(CoreRelease.version(fromOutput: "command not found"))
        XCTAssertTrue(CoreRelease.isNewer("v1.19.34", than: "v1.19.9"))
        XCTAssertTrue(CoreRelease.isNewer("v1.20.0", than: "v1.19.34"))
        XCTAssertFalse(CoreRelease.isNewer("v1.19.34", than: "v1.19.34"))
        XCTAssertFalse(CoreRelease.isNewer("v1.19.3", than: "v1.19.34"))
        XCTAssertFalse(CoreRelease.isNewer("nightly", than: "v1.19.34"))
    }

    /// 设置 LOCKGATE_MIHOMO 为内核路径时，用真实内核校验合成出的配置。
    func testComposedConfigsPassRealCoreValidation() throws {
        guard let path = ProcessInfo.processInfo.environment["LOCKGATE_MIHOMO"] else {
            throw XCTSkip("未设置 LOCKGATE_MIHOMO，跳过真实内核校验。")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("providers"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let nodes = Data("ss://YWVzLTEyOC1nY206eA@192.0.2.9:8388#n\n".utf8).base64EncodedData()
        try nodes.write(to: home.appendingPathComponent("providers/subscription.txt"))
        let configs = [try ProfileComposer.compose(profile: profile, runtime: runtime),
                       ProfileComposer.compose(providerPath: "./providers/subscription.txt", runtime: runtime)]
        for (index, config) in configs.enumerated() {
            let url = home.appendingPathComponent("config-\(index).yaml")
            try Data(config.utf8).write(to: url)
            let result = Command.run(path, ["-t", "-d", home.path, "-f", url.path])
            XCTAssertEqual(result.status, 0, result.output)
        }
    }
}
