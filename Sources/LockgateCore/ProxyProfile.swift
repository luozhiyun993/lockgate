import Foundation

// MARK: - 设置与订阅

public enum ProxyMode: String, Codable, CaseIterable {
    case rule, global, direct

    public var title: String {
        switch self {
        case .rule: return "规则"
        case .global: return "全局"
        case .direct: return "直连"
        }
    }
}

public enum SubscriptionKind: String, Codable {
    /// 完整的 Clash / mihomo 配置，沿用其中的策略组和规则。
    case profile
    /// 只有节点列表（常见为 base64 的分享链接），由 Lockgate 生成策略组和规则。
    case provider
}

public struct SubscriptionUsage: Codable, Equatable {
    public var upload: Int64
    public var download: Int64
    public var total: Int64
    public var expire: Date?

    public init(upload: Int64 = 0, download: Int64 = 0, total: Int64 = 0, expire: Date? = nil) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

    /// 解析订阅响应头 `subscription-userinfo: upload=1; download=2; total=3; expire=1700000000`。
    public static func parse(_ header: String?) -> SubscriptionUsage? {
        guard let header else { return nil }
        var fields: [String: Int64] = [:]
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let value = Int64(pair[1]) ?? Double(pair[1]).map({ Int64($0) }) else { continue }
            fields[pair[0].lowercased()] = value
        }
        guard !fields.isEmpty else { return nil }
        let expire = fields["expire"].flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return SubscriptionUsage(upload: max(0, fields["upload"] ?? 0), download: max(0, fields["download"] ?? 0),
                                 total: max(0, fields["total"] ?? 0), expire: expire)
    }

    public var summary: String {
        var parts: [String] = []
        if total > 0 {
            parts.append("已用 \(Self.format(upload + download)) / \(Self.format(total))")
        }
        if let expire {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            parts.append("到期 \(formatter.string(from: expire))")
        }
        return parts.joined(separator: " · ")
    }

    public static func format(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[index])
    }
}

public struct Subscription: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var url: String
    public var kind: SubscriptionKind
    public var updatedAt: Date?
    public var usage: SubscriptionUsage?
    public var lastError: String?

    public init(id: UUID = UUID(), name: String, url: String, kind: SubscriptionKind = .profile,
                updatedAt: Date? = nil, usage: SubscriptionUsage? = nil, lastError: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.updatedAt = updatedAt
        self.usage = usage
        self.lastError = lastError
    }

    /// 仅接受带主机名的 http / https 地址。
    public static func validatedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// 订阅地址通常带令牌，界面和日志只显示主机名。
    public var displayHost: String {
        URL(string: url)?.host ?? "未知地址"
    }
}

public struct ProxySettings: Codable, Equatable {
    public var coreEnabled = false
    public var systemProxy = true
    public var tun = false
    public var mode = ProxyMode.rule
    public var mixedPort = 17890
    public var autoUpdateHours = 24
    public var activeSubscription: UUID?
    public var subscriptions: [Subscription] = []
    /// 订阅 ID → 策略组 → 选中的节点。
    public var selections: [String: [String: String]] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case coreEnabled, systemProxy, tun, mode, mixedPort, autoUpdateHours, activeSubscription, subscriptions, selections
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        coreEnabled = try values.decodeIfPresent(Bool.self, forKey: .coreEnabled) ?? false
        systemProxy = try values.decodeIfPresent(Bool.self, forKey: .systemProxy) ?? true
        tun = try values.decodeIfPresent(Bool.self, forKey: .tun) ?? false
        mode = try values.decodeIfPresent(ProxyMode.self, forKey: .mode) ?? .rule
        mixedPort = try values.decodeIfPresent(Int.self, forKey: .mixedPort) ?? 17890
        autoUpdateHours = try values.decodeIfPresent(Int.self, forKey: .autoUpdateHours) ?? 24
        activeSubscription = try values.decodeIfPresent(UUID.self, forKey: .activeSubscription)
        subscriptions = try values.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        selections = try values.decodeIfPresent([String: [String: String]].self, forKey: .selections) ?? [:]
    }

    public var active: Subscription? {
        subscriptions.first { $0.id == activeSubscription }
    }

    public static func isValidPort(_ port: Int) -> Bool { (1024...65535).contains(port) }
}

public struct ProxyStore {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("proxy.json") }
    public var profiles: URL { directory.appendingPathComponent("profiles") }

    public init(directory: URL = StateStore.defaultDirectory) {
        self.directory = directory
    }

    public func profileURL(_ id: UUID) -> URL {
        profiles.appendingPathComponent("\(id.uuidString).txt")
    }

    public func load() throws -> ProxySettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return ProxySettings() }
        return try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: url))
    }

    public func save(_ settings: ProxySettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Self.writePrivate(JSONEncoder().encode(settings), to: url)
    }

    public func saveProfile(_ data: Data, id: UUID) throws {
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Self.writePrivate(data, to: profileURL(id))
    }

    public func removeProfile(_ id: UUID) {
        try? FileManager.default.removeItem(at: profileURL(id))
    }

    /// 订阅和配置含有节点凭据，统一按 0600 写入。
    public static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - 配置合成

public struct CoreRuntime: Equatable {
    public var mixedPort: Int
    public var controllerPort: Int
    public var secret: String
    public var mode: ProxyMode
    public var tun: Bool
    /// 内核阻断要管控的地址；nil 表示不启用。
    public var gate: [String]?

    public init(mixedPort: Int, controllerPort: Int, secret: String, mode: ProxyMode, tun: Bool, gate: [String]? = nil) {
        self.mixedPort = mixedPort
        self.controllerPort = controllerPort
        self.secret = secret
        self.mode = mode
        self.tun = tun
        self.gate = gate
    }
}

public enum ProfileError: Error, Equatable, LocalizedError {
    case unrecognized
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .unrecognized: return "订阅内容无法识别：既不是 Clash / mihomo 配置，也不是节点分享链接列表。"
        case .invalidJSON: return "订阅内容是 JSON 格式但无法解析。"
        }
    }
}

/// 不引入 YAML 解析库：按顶层键整块删除订阅里由 Lockgate 接管的配置，再追加 Lockgate 的值。
/// 追加的值写成单行 JSON，JSON 是合法的 YAML 流式写法。
public enum ProfileComposer {
    public static let testURL = "https://www.gstatic.com/generate_204"

    /// 订阅中这些顶层键一律丢弃：监听端口、局域网访问、控制接口、TUN、DNS 等由 Lockgate 决定，
    /// 避免订阅把控制接口或代理端口暴露到局域网。
    public static let managedKeys: Set<String> = [
        "port", "socks-port", "mixed-port", "redir-port", "tproxy-port", "allow-lan", "bind-address",
        "lan-allowed-ips", "lan-disallowed-ips", "authentication", "skip-auth-prefixes",
        "external-controller", "external-controller-tls", "external-controller-unix",
        "external-controller-pipe", "external-controller-cors", "external-ui", "external-ui-name",
        "external-ui-url", "external-doh-server", "secret", "tun", "listeners", "tunnels",
        "mode", "log-level", "ipv6", "interface-name", "routing-mark", "profile", "dns", "find-process-mode"
    ]

    private static let privateRules = [
        "DOMAIN-SUFFIX,local,DIRECT", "DOMAIN,localhost,DIRECT",
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve", "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve", "IP-CIDR6,::1/128,DIRECT,no-resolve",
        "IP-CIDR6,fc00::/7,DIRECT,no-resolve", "IP-CIDR6,fe80::/10,DIRECT,no-resolve"
    ]

    // MARK: 内核阻断

    /// 阻断开关组。成员顺序决定默认值：内核启动或重载后先处于「拒绝」，由 Lockgate 确认后才切到「放行」。
    /// 选中 PASS 时这条规则视为未命中，继续按订阅自己的规则分流。
    public static let gateGroup = "LOCKGATE-GATE"
    public static let gateBlock = "REJECT"
    public static let gateAllow = "PASS"

    private static var gateGroupObject: [String: Any] {
        ["name": gateGroup, "type": "select", "proxies": [gateBlock, gateAllow]]
    }

    /// 把地址规则转成 mihomo 规则。`*.example.com` 只匹配子域名，与系统扩展方式的语义一致。
    public static func gateRules(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.compactMap(NetworkAddressRule.init).compactMap { rule -> String? in
            let text: String
            if IPAddress.normalized(rule.value) != nil {
                text = rule.value.contains(":") ? "IP-CIDR6,\(rule.value)/128,\(gateGroup),no-resolve"
                    : "IP-CIDR,\(rule.value)/32,\(gateGroup),no-resolve"
            } else if rule.subdomains {
                text = "DOMAIN-REGEX,^.+\\.\(rule.value.replacingOccurrences(of: ".", with: "\\."))$,\(gateGroup)"
            } else {
                text = "DOMAIN,\(rule.value),\(gateGroup)"
            }
            return seen.insert(text).inserted ? text : nil
        }
    }

    /// 在顶层列表（`rules` / `proxy-groups`）的最前面插入条目，保持原有缩进；列表不存在时新建。
    static func inserting(_ items: [Any], intoList key: String, of text: String) -> String {
        guard !items.isEmpty else { return text }
        var lines = normalized(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rendered = items.map(json)
        guard let index = lines.firstIndex(where: { topLevelKey(of: Substring($0)) == key }) else {
            return lines.joined(separator: "\n") + "\n\(key):\n" + rendered.map { "  - \($0)" }.joined(separator: "\n") + "\n"
        }
        let line = lines[index]
        if let colon = line.firstIndex(of: ":") {
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("[") {
                let open = line[line.index(after: colon)...].firstIndex(of: "[")!
                let rest = String(line[line.index(after: open)...])
                let empty = rest.trimmingCharacters(in: .whitespaces).hasPrefix("]")
                lines[index] = String(line[...open]) + rendered.joined(separator: ", ") + (empty ? "" : ", ") + rest
                return lines.joined(separator: "\n")
            }
            if !value.isEmpty, !value.hasPrefix("#") {
                // `rules: null` 之类的空值：改写成块式列表。
                lines[index] = "\(key):"
            }
        }
        var indent = "  "
        var cursor = index + 1
        while cursor < lines.count, topLevelKey(of: Substring(lines[cursor])) == nil,
              !lines[cursor].hasPrefix("---"), !lines[cursor].hasPrefix("...") {
            let trimmed = lines[cursor].drop { $0 == " " || $0 == "\t" }
            if trimmed == "-" || trimmed.hasPrefix("- ") {
                indent = String(lines[cursor].prefix(lines[cursor].count - trimmed.count))
                break
            }
            cursor += 1
        }
        lines.insert(contentsOf: rendered.map { "\(indent)- \($0)" }, at: index + 1)
        return lines.joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// 顶格书写的 `key:` 行。YAML 块式映射的顶层键必然从第 0 列开始。
    static func topLevelKey(of line: Substring) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#", first != "-" else { return nil }
        var rest = line
        var quote: Character?
        if first == "\"" || first == "'" {
            quote = first
            rest = rest.dropFirst()
        }
        var key = ""
        for character in rest {
            if let quote, character == quote { break }
            if quote == nil, character == ":" { break }
            guard character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." else { return nil }
            key.append(character)
        }
        guard !key.isEmpty else { return nil }
        var tail = rest.dropFirst(key.count)
        if quote != nil { tail = tail.dropFirst() }
        tail = tail.drop { $0 == " " || $0 == "\t" }
        guard tail.first == ":" else { return nil }
        let after = tail.dropFirst()
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return key
    }

    public static func topLevelKeys(in text: String) -> [String] {
        normalized(text).split(separator: "\n", omittingEmptySubsequences: false).compactMap(topLevelKey)
    }

    /// 删除指定顶层键及其整块内容（到下一个顶层键或文档分隔符为止）。
    public static func stripping(_ text: String, keys: Set<String>) -> String {
        var output: [Substring] = []
        var dropping = false
        for line in normalized(text).split(separator: "\n", omittingEmptySubsequences: false) {
            if let key = topLevelKey(of: line) {
                dropping = keys.contains(key)
            } else if line.hasPrefix("---") || line.hasPrefix("...") {
                dropping = false
            }
            if !dropping { output.append(line) }
        }
        return output.joined(separator: "\n")
    }

    private static func decodedNodeList(_ text: String) -> String? {
        if text.contains("://") { return text }
        var compact = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !compact.isEmpty else { return nil }
        while compact.count % 4 != 0 { compact.append("=") }
        guard let data = Data(base64Encoded: compact), let decoded = String(data: data, encoding: .utf8),
              decoded.contains("://") else { return nil }
        return decoded
    }

    /// 判断订阅内容的类型；无法识别（例如返回了 HTML 错误页）时为 nil。
    public static func kind(of text: String) -> SubscriptionKind? {
        let text = normalized(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        if text.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
            return object["proxies"] != nil || object["proxy-providers"] != nil ? .profile : nil
        }
        let keys = Set(topLevelKeys(in: text))
        if keys.contains("proxies") || keys.contains("proxy-providers") { return .profile }
        return decodedNodeList(text) != nil ? .provider : nil
    }

    public static func overrides(_ runtime: CoreRuntime) -> [(String, Any)] {
        [
            ("mixed-port", runtime.mixedPort),
            ("allow-lan", false),
            ("bind-address", "127.0.0.1"),
            // 全局和直连模式不经过规则，阻断开启时固定为规则模式。
            ("mode", (runtime.gate == nil ? runtime.mode : .rule).rawValue),
            ("log-level", "info"),
            ("ipv6", false),
            // 实时监控需要知道每条连接来自哪个进程。
            ("find-process-mode", "always"),
            ("external-controller", "127.0.0.1:\(runtime.controllerPort)"),
            ("secret", runtime.secret),
            ("profile", ["store-selected": false, "store-fake-ip": false]),
            ("tun", ["enable": runtime.tun, "stack": "mixed", "auto-route": true,
                     "auto-detect-interface": true, "dns-hijack": ["any:53"]] as [String: Any]),
            ("dns", ["enable": true, "ipv6": false, "enhanced-mode": "fake-ip",
                     "fake-ip-range": "198.18.0.1/16",
                     "fake-ip-filter": ["*.lan", "*.local", "localhost", "time.*.com", "ntp.*.com"],
                     "default-nameserver": ["223.5.5.5", "119.29.29.29", "1.1.1.1"],
                     "nameserver": ["https://doh.pub/dns-query", "https://dns.alidns.com/dns-query",
                                    "https://1.1.1.1/dns-query"]] as [String: Any])
        ]
    }

    private static func json(_ value: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value,
                                               options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// 以完整配置订阅为基础，套用 Lockgate 接管的配置项。
    public static func compose(profile text: String, runtime: CoreRuntime) throws -> String {
        let text = normalized(text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            guard var object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
                throw ProfileError.invalidJSON
            }
            for key in managedKeys { object.removeValue(forKey: key) }
            for (key, value) in overrides(runtime) { object[key] = value }
            if let gate = runtime.gate {
                object["proxy-groups"] = [gateGroupObject] + (object["proxy-groups"] as? [Any] ?? [])
                object["rules"] = gateRules(gate) + (object["rules"] as? [Any] ?? [])
            }
            return json(object) + "\n"
        }
        guard kind(of: text) == .profile else { throw ProfileError.unrecognized }
        let lines = overrides(runtime).map { "\($0.0): \(json($0.1))" }
        var body = stripping(text, keys: managedKeys)
        if let gate = runtime.gate {
            body = inserting([gateGroupObject], intoList: "proxy-groups", of: body)
            body = inserting(gateRules(gate), intoList: "rules", of: body)
        }
        return body + "\n\n# ---- Lockgate 接管的配置 ----\n"
            + lines.joined(separator: "\n") + "\n"
    }

    /// 节点列表订阅：以本地文件作为节点来源，生成选择组、自动测速组和「除私有地址外全部走代理」的规则。
    public static func compose(providerPath: String, runtime: CoreRuntime) -> String {
        var object: [String: Any] = [
            "proxy-providers": ["subscription": [
                "type": "file", "path": providerPath,
                "health-check": ["enable": true, "url": testURL, "interval": 600, "lazy": true]
            ] as [String: Any]],
            "proxy-groups": [
                ["name": "PROXY", "type": "select", "proxies": ["AUTO", "DIRECT"], "use": ["subscription"]] as [String: Any],
                ["name": "AUTO", "type": "url-test", "use": ["subscription"], "url": testURL,
                 "interval": 300, "tolerance": 50] as [String: Any]
            ],
            "rules": privateRules + ["MATCH,PROXY"]
        ]
        for (key, value) in overrides(runtime) { object[key] = value }
        if let gate = runtime.gate {
            object["proxy-groups"] = [gateGroupObject] + (object["proxy-groups"] as? [Any] ?? [])
            object["rules"] = gateRules(gate) + (object["rules"] as? [Any] ?? [])
        }
        return json(object) + "\n"
    }
}

// MARK: - 系统代理

public enum SystemProxyPlan {
    public static let host = "127.0.0.1"

    /// 只绕过本机和私有网段。出口检查同样认可这些条目，它们不可能绕过 Claude 的公网域名。
    public static let bypass = ["localhost", "*.local", "127.0.0.1", "10.0.0.0/8", "172.16.0.0/12",
                                "192.168.0.0/16", "169.254.0.0/16"]

    private static let safeNetworks: Set<String> = [
        "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
        "::1/128", "fc00::/7", "fe80::/10"
    ]

    /// 仅覆盖本机、链路本地或私有地址的绕过条目：固定的私有网段，或落在这些网段内的单个地址。
    /// 其他网段（包括 Fake-IP 使用的 198.18.0.0/15）一律不算。
    public static func isLocalBypass(_ pattern: String) -> Bool {
        let pattern = pattern.lowercased().trimmingCharacters(in: .whitespaces)
        if safeNetworks.contains(pattern) { return true }
        guard !pattern.contains("/"), !pattern.contains("*"), let address = IPAddress.normalized(pattern) else { return false }
        if address.contains(":") {
            guard address != "::1" else { return true }
            guard let first = address.split(separator: ":").first, let prefix = UInt16(first, radix: 16) else { return false }
            return (0xfc00...0xfdff).contains(prefix) || (0xfe80...0xfebf).contains(prefix)
        }
        let bytes = address.split(separator: ".").compactMap { Int($0) }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 127 || bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
    }

    /// 解析 `networksetup -listallnetworkservices`：首行为说明，`*` 开头表示已停用的服务。
    public static func services(from output: String) -> [String] {
        output.split(separator: "\n").dropFirst().map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public static func enableCommands(service: String, port: Int) -> [[String]] {
        [
            ["-setautoproxystate", service, "off"],
            ["-setproxyautodiscovery", service, "off"],
            ["-setwebproxy", service, host, String(port)],
            ["-setsecurewebproxy", service, host, String(port)],
            ["-setsocksfirewallproxy", service, host, String(port)],
            ["-setproxybypassdomains", service] + bypass
        ]
    }

    public static func disableCommands(service: String) -> [[String]] {
        [
            ["-setwebproxystate", service, "off"],
            ["-setsecurewebproxystate", service, "off"],
            ["-setsocksfirewallproxystate", service, "off"]
        ]
    }

    /// 系统当前的 HTTPS 代理是否正指向 Lockgate 的端口。
    public static func pointsToCore(_ values: [String: Any], port: Int) -> Bool {
        (values["HTTPSEnable"] as? NSNumber)?.intValue == 1
            && (values["HTTPSProxy"] as? String) == host
            && (values["HTTPSPort"] as? NSNumber)?.intValue == port
    }
}

// MARK: - 内核版本

public struct CoreAsset: Equatable {
    public let version: String
    public let name: String
    public let url: URL
    public let sha256: String
}

public enum CoreRelease {
    public static let latestURL = URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")!
    private static let downloadPrefix = "https://github.com/MetaCubeX/mihomo/releases/download/"

    /// 从 `mihomo -v` 的输出中取版本号，例如 `Mihomo Meta v1.19.34 darwin arm64 …`。
    public static func version(fromOutput output: String) -> String? {
        output.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .first { components($0) != nil && $0.hasPrefix("v") }
    }

    static func components(_ version: String) -> [Int]? {
        let body = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count >= 2, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.compactMap { $0 }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let left = components(candidate), let right = components(current) else { return false }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    public static func assetName(version: String, architecture: String) -> String {
        architecture == "arm64" ? "mihomo-darwin-arm64-\(version).gz" : "mihomo-darwin-amd64-compatible-\(version).gz"
    }

    /// 从 GitHub Release 的 JSON 中选出本机架构的内核。必须带 SHA256 摘要，且下载地址属于官方仓库。
    public static func parse(_ data: Data, architecture: String) -> CoreAsset? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, components(tag) != nil,
              object["prerelease"] as? Bool != true, object["draft"] as? Bool != true,
              let assets = object["assets"] as? [[String: Any]] else { return nil }
        let wanted = assetName(version: tag, architecture: architecture)
        guard let asset = assets.first(where: { $0["name"] as? String == wanted }),
              let link = asset["browser_download_url"] as? String, link.hasPrefix(downloadPrefix),
              let url = URL(string: link), let digest = asset["digest"] as? String,
              digest.hasPrefix("sha256:") else { return nil }
        let hash = String(digest.dropFirst("sha256:".count)).lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return CoreAsset(version: tag, name: wanted, url: url, sha256: hash)
    }
}
