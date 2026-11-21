import XCTest
@testable import LockgateCore

final class OverrideEngineTests: XCTestCase {
    private let runtime = CoreRuntime(mixedPort: 17890, controllerPort: 51234, secret: "secret-value", mode: .rule, tun: false)

    private let profile = """
    mixed-port: 7890
    allow-lan: true
    external-controller: 0.0.0.0:9090
    dns:
      enable: false
    defaults: &node {type: ss, port: 8388, cipher: aes-128-gcm, password: x}
    proxies:
      - {<<: *node, name: "节点 A", server: 192.0.2.1}
      - {<<: *node, name: "节点 B", server: 192.0.2.2}
    proxy-groups:
      - {name: PROXY, type: select, proxies: ["节点 A", "节点 B"]}
    rules:
      - DOMAIN-SUFFIX,example.org,DIRECT
      - MATCH,PROXY
    sniffer:
      enable: false
      sniff: {TLS: {ports: [443]}}
    """

    private func run(_ steps: [OverrideStep], runtime: CoreRuntime? = nil, profile: String? = nil,
                     kind: SubscriptionKind = .profile) throws -> (config: [String: Any], logs: [String]) {
        let output = try OverrideEngine.run(OverrideRequest(profile: profile ?? self.profile, kind: kind,
            providerPath: "./providers/subscription.txt", steps: steps, runtime: runtime ?? self.runtime))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.config.utf8)) as? [String: Any])
        return (object, output.logs)
    }

    private func yaml(_ content: String) -> OverrideStep { OverrideStep(name: "测试 YAML", kind: .yaml, content: content) }
    private func script(_ content: String) -> OverrideStep { OverrideStep(name: "测试脚本", kind: .script, content: content) }

    func testWithoutStepsMatchesManagedSettingsAndResolvesAnchors() throws {
        let config = try run([]).config
        XCTAssertEqual(config["mixed-port"] as? Int, 17890)
        XCTAssertEqual(config["allow-lan"] as? Bool, false)
        XCTAssertEqual(config["external-controller"] as? String, "127.0.0.1:51234")
        XCTAssertEqual((config["dns"] as? [String: Any])?["enable"] as? Bool, true, "订阅自带的 DNS 不生效")
        let proxies = try XCTUnwrap(config["proxies"] as? [[String: Any]])
        XCTAssertEqual(proxies.map { $0["name"] as? String }, ["节点 A", "节点 B"])
        XCTAssertEqual(proxies[1]["cipher"] as? String, "aes-128-gcm", "YAML 锚点和合并键需要展开")
        XCTAssertEqual(proxies[1]["server"] as? String, "192.0.2.2")
    }

    func testYAMLMergeFollowsClashPartyRules() throws {
        let config = try run([yaml("""
        +rules:
          - DOMAIN,first.example,DIRECT
        rules+:
          - DOMAIN,last.example,DIRECT
        sniffer:
          enable: true
        proxy-groups!:
          - {name: ONLY, type: select, proxies: [DIRECT]}
        unified-delay: true
        +missing: [a]
        """)]).config
        XCTAssertEqual(config["rules"] as? [String], ["DOMAIN,first.example,DIRECT", "DOMAIN-SUFFIX,example.org,DIRECT",
                                                      "MATCH,PROXY", "DOMAIN,last.example,DIRECT"])
        let sniffer = try XCTUnwrap(config["sniffer"] as? [String: Any])
        XCTAssertEqual(sniffer["enable"] as? Bool, true)
        XCTAssertNotNil(sniffer["sniff"], "映射递归合并，未提到的键保留")
        XCTAssertEqual((config["proxy-groups"] as? [[String: Any]])?.map { $0["name"] as? String }, ["ONLY"])
        XCTAssertEqual(config["unified-delay"] as? Bool, true)
        XCTAssertEqual(config["missing"] as? [String], ["a"])
        XCTAssertNil(config["+rules"])
        XCTAssertNil(config["proxy-groups!"])
    }

    func testPlainListReplacesAndBangReplacesWholeMap() throws {
        let config = try run([yaml("rules:\n  - MATCH,DIRECT\nsniffer!:\n  enable: true\n")]).config
        XCTAssertEqual(config["rules"] as? [String], ["MATCH,DIRECT"])
        XCTAssertEqual(config["sniffer"] as? [String: Bool], ["enable": true])
    }

    func testUserMayOverrideDNSButNotLockgateManagedSecurityKeys() throws {
        let config = try run([
            yaml("""
            dns:
              enhanced-mode: redir-host
              nameserver!: [9.9.9.9]
            tun:
              enable: true
              stack: gvisor
            mixed-port: 1
            allow-lan: true
            external-controller: 0.0.0.0:9090
            secret: mine
            mode: global
            port: 8080
            """),
            script("function main(config) { config['allow-lan'] = true; config['external-controller'] = '0.0.0.0:1'; config['external-ui'] = '/tmp'; return config; }")
        ]).config
        let dns = try XCTUnwrap(config["dns"] as? [String: Any])
        XCTAssertEqual(dns["enhanced-mode"] as? String, "redir-host")
        XCTAssertEqual(dns["nameserver"] as? [String], ["9.9.9.9"])
        XCTAssertEqual(dns["enable"] as? Bool, true)
        let tun = try XCTUnwrap(config["tun"] as? [String: Any])
        XCTAssertEqual(tun["enable"] as? Bool, false, "TUN 开关以 Lockgate 的设置为准")
        XCTAssertEqual(tun["stack"] as? String, "gvisor")
        XCTAssertEqual(tun["auto-route"] as? Bool, true)
        XCTAssertEqual(config["mixed-port"] as? Int, 17890)
        XCTAssertEqual(config["allow-lan"] as? Bool, false)
        XCTAssertEqual(config["external-controller"] as? String, "127.0.0.1:51234")
        XCTAssertEqual(config["secret"] as? String, "secret-value")
        XCTAssertEqual(config["mode"] as? String, "rule")
        XCTAssertNil(config["port"])
        XCTAssertNil(config["external-ui"])
    }

    func testScriptReceivesPreparedConfigAndStepsRunInOrder() throws {
        let result = try run([
            yaml("+rules: [\"DOMAIN,yaml.example,DIRECT\"]"),
            script("""
            function main(config) {
              console.log('rules', config.rules.length, { port: config['mixed-port'] });
              config.rules.unshift('DOMAIN,script.example,DIRECT');
              config.proxies = config.proxies.filter(function (p) { return p.name !== '节点 B'; });
              return config;
            }
            """)
        ])
        XCTAssertEqual((result.config["rules"] as? [String])?.prefix(2).map { $0 }, ["DOMAIN,script.example,DIRECT", "DOMAIN,yaml.example,DIRECT"])
        XCTAssertEqual((result.config["proxies"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(result.logs, [#"rules 3 {"port":17890}"#])
    }

    func testGateIsInjectedAfterOverridesAndCannotBeRemovedByScripts() throws {
        var gated = runtime
        gated.gate = ["claude.ai"]
        let config = try run([script("function main(config) { config.rules = ['MATCH,DIRECT']; config['proxy-groups'] = []; return config; }")],
                             runtime: gated).config
        XCTAssertEqual(config["rules"] as? [String], ["DOMAIN,claude.ai,LOCKGATE-GATE", "MATCH,DIRECT"])
        XCTAssertEqual((config["proxy-groups"] as? [[String: Any]])?.first?["name"] as? String, ProfileComposer.gateGroup)
    }

    func testProviderSubscriptionsCanBeOverridden() throws {
        let config = try run([yaml("+rules: [\"DOMAIN,direct.example,DIRECT\"]")], profile: "ignored", kind: .provider).config
        XCTAssertEqual((config["rules"] as? [String])?.first, "DOMAIN,direct.example,DIRECT")
        XCTAssertEqual((config["rules"] as? [String])?.last, "MATCH,PROXY")
        XCTAssertNotNil(config["proxy-providers"])
    }

    func testErrorsNameTheFailingOverride() {
        func message(_ steps: [OverrideStep], profile: String? = nil) -> String {
            do { _ = try run(steps, profile: profile); return "" } catch { return error.localizedDescription }
        }
        XCTAssertTrue(message([yaml("rules: [unclosed")]).hasPrefix("覆写「测试 YAML」出错"))
        XCTAssertTrue(message([yaml("- just\n- a list")]).contains("必须是键值映射"))
        XCTAssertTrue(message([script("var x = 1;")]).contains("需要定义 main(config)"))
        XCTAssertTrue(message([script("function main(config) { return 1; }")]).contains("必须返回配置对象"))
        XCTAssertTrue(message([script("function main(config) { return Promise.resolve(config); }")]).contains("不支持异步"))
        XCTAssertTrue(message([script("function main(config) { return missing.value; }")]).contains("missing"))
        XCTAssertTrue(message([script("function main(config) {")]).hasPrefix("覆写「测试脚本」出错"))
        let runtimeError = message([script("function main(config) {\n  var a = 1;\n  return config.missing.value;\n}")])
        XCTAssertTrue(runtimeError.contains("TypeError") && runtimeError.hasSuffix("（脚本第 3 行）"), runtimeError)
        XCTAssertTrue(message([], profile: "- a\n- b").hasPrefix("订阅配置"))
        XCTAssertTrue(message([], profile: "a: [").hasPrefix("订阅配置解析失败"))
        XCTAssertEqual(message([yaml("# 只有注释\n"), yaml("")]), "")
    }

    func testScriptsHaveNoFileOrNetworkAccess() throws {
        let result = try run([script("""
        function main(config) {
          console.log([typeof require, typeof process, typeof fetch, typeof XMLHttpRequest, typeof importScripts].join(','));
          return config;
        }
        """)])
        XCTAssertEqual(result.logs, ["undefined,undefined,undefined,undefined,undefined"])
    }

    func testTemplatesAreValidNoOps() throws {
        let baseline = try run([]).config
        let templated = try run([yaml(OverrideEngine.yamlTemplate), script(OverrideEngine.scriptTemplate)]).config
        XCTAssertEqual(NSDictionary(dictionary: baseline), NSDictionary(dictionary: templated))
    }

    func testOverrideSettingsPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProxyStore(directory: directory)
        let item = OverrideItem(name: "规则", kind: .script)
        var settings = try JSONDecoder().decode(ProxySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.overrides, [])
        settings.overrides = [item]
        try store.save(settings)
        try store.saveOverride("function main(c) { return c; }", item: item)
        XCTAssertEqual(try store.load().overrides.map(\.id), [item.id])
        XCTAssertEqual(store.loadOverride(item), "function main(c) { return c; }")
        XCTAssertEqual(store.overrideURL(item).pathExtension, "js")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.overrideURL(item).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        store.removeOverride(item)
        XCTAssertEqual(store.loadOverride(item), "")
    }

    /// 设置 LOCKGATE_MIHOMO 为内核路径时，用真实内核校验覆写后的配置。
    func testOverriddenConfigPassesRealCoreValidation() throws {
        guard let path = ProcessInfo.processInfo.environment["LOCKGATE_MIHOMO"] else {
            throw XCTSkip("未设置 LOCKGATE_MIHOMO，跳过真实内核校验。")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        var gated = runtime
        gated.gate = NetworkFilterPreferences.defaultAddresses
        let output = try OverrideEngine.run(OverrideRequest(profile: profile, kind: .profile, providerPath: "", steps: [
            yaml("+rules: [\"DOMAIN,first.example,DIRECT\"]\ndns:\n  enhanced-mode: redir-host\n"),
            script("function main(config) { config['proxy-groups'].push({name: 'EXTRA', type: 'select', proxies: ['DIRECT']}); return config; }")
        ], runtime: gated))
        let url = home.appendingPathComponent("config.yaml")
        try Data(output.config.utf8).write(to: url)
        let result = Command.run(path, ["-t", "-d", home.path, "-f", url.path])
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testReadableYAMLMasksSecretAndKeepsContent() throws {
        let json = #"{"mixed-port":17890,"secret":"abc123","proxies":[{"name":"节点 A","type":"ss","server":"example.com","port":443}],"rules":["MATCH,PROXY"]}"#
        let yaml = try OverrideEngine.readableYAML(json)
        XCTAssertFalse(yaml.contains("abc123"))
        XCTAssertTrue(yaml.contains("secret: （已隐藏）"))
        XCTAssertTrue(yaml.contains("mixed-port: 17890"))
        XCTAssertTrue(yaml.contains("name: 节点 A"))
        XCTAssertTrue(yaml.contains("- MATCH,PROXY"))
        XCTAssertGreaterThan(yaml.split(separator: "\n").count, 8)
    }

    func testReadableNodeListDecodesBase64() {
        let plain = "ss://YWVzLTI1Ni1nY206cHc=@example.com:443#A\nss://YWVzLTI1Ni1nY206cHc=@example.org:443#B\n"
        let encoded = Data(plain.utf8).base64EncodedString()
        XCTAssertEqual(ProfileComposer.readableNodeList(encoded).trimmingCharacters(in: .whitespacesAndNewlines),
                       plain.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(ProfileComposer.readableNodeList(plain) + "\n", plain)
    }
}
