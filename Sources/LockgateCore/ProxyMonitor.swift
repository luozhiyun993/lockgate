import Foundation

/// 一条连接最终的去向。
public enum ConnectionRoute: String, CaseIterable {
    /// 经代理节点转发，也就是被托管的流量。
    case proxied
    /// 未经代理，直接从本机网络出去。
    case direct
    /// 被规则拒绝，没有发出。
    case rejected

    public var title: String {
        switch self {
        case .proxied: return "代理"
        case .direct: return "直连"
        case .rejected: return "拒绝"
        }
    }

    public init(outbound: String) {
        let name = outbound.uppercased()
        if name == "DIRECT" || name == "COMPATIBLE" || name == "PASS" {
            self = .direct
        } else if name.hasPrefix("REJECT") {
            self = .rejected
        } else {
            self = .proxied
        }
    }
}

public struct ConnectionRecord: Equatable, Identifiable {
    public let id: String
    public let host: String
    public let port: String
    public let network: String
    public let inbound: String
    public let process: String
    public let processPath: String
    /// 从实际出口到最外层策略组，例如 `["节点 A", "PROXY"]`。
    public let chains: [String]
    public let rule: String
    public let rulePayload: String
    public let upload: Int64
    public let download: Int64
    public let start: Date?

    public init(id: String, host: String, port: String = "", network: String = "tcp", inbound: String = "",
                process: String = "", processPath: String = "", chains: [String], rule: String = "",
                rulePayload: String = "", upload: Int64 = 0, download: Int64 = 0, start: Date? = nil) {
        self.id = id
        self.host = host
        self.port = port
        self.network = network
        self.inbound = inbound
        self.process = process
        self.processPath = processPath
        self.chains = chains
        self.rule = rule
        self.rulePayload = rulePayload
        self.upload = upload
        self.download = download
        self.start = start
    }

    /// 流量实际出去的节点；直连时为 DIRECT。
    public var outbound: String { chains.first ?? "未知" }

    public var route: ConnectionRoute { ConnectionRoute(outbound: outbound) }

    public var destination: String { port.isEmpty ? host : "\(host):\(port)" }

    /// 按匹配顺序展示：策略组 → … → 出口节点。
    public var chainText: String { chains.reversed().joined(separator: " → ") }

    public var ruleText: String { rulePayload.isEmpty ? rule : "\(rule)（\(rulePayload)）" }

    public var inboundTitle: String {
        switch inbound.lowercased() {
        case "tun": return "TUN"
        case "http", "https": return "HTTP 代理"
        case "socks4", "socks5": return "SOCKS 代理"
        default: return inbound
        }
    }
}

public struct ConnectionSnapshot: Equatable {
    public var uploadTotal: Int64 = 0
    public var downloadTotal: Int64 = 0
    public var connections: [ConnectionRecord] = []

    public init(uploadTotal: Int64 = 0, downloadTotal: Int64 = 0, connections: [ConnectionRecord] = []) {
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
        self.connections = connections
    }
}

/// 某个出口上当前连接的汇总。
public struct OutboundUsage: Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let route: ConnectionRoute
    public var connections: Int
    public var upload: Int64
    public var download: Int64

    public var total: Int64 { upload + download }
}

public enum ConnectionParser {
    private static func integer(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }

    /// mihomo 的时间带纳秒级小数，先去掉小数部分再按 ISO 8601 解析。
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let trimmed = text.replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    /// 解析控制接口 `GET /connections` 的返回。
    public static func parse(_ data: Data) -> ConnectionSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let items = object["connections"] as? [[String: Any]] ?? []
        let connections = items.compactMap { item -> ConnectionRecord? in
            guard let id = item["id"] as? String else { return nil }
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            func text(_ key: String) -> String { metadata[key] as? String ?? "" }
            let host = [text("host"), text("sniffHost"), text("destinationIP"), text("remoteDestination")]
                .first { !$0.isEmpty } ?? "未知目标"
            return ConnectionRecord(
                id: id, host: host, port: text("destinationPort"), network: text("network"), inbound: text("type"),
                process: text("process"), processPath: text("processPath"),
                chains: (item["chains"] as? [String] ?? []).filter { !$0.isEmpty },
                rule: item["rule"] as? String ?? "", rulePayload: item["rulePayload"] as? String ?? "",
                upload: integer(item["upload"]), download: integer(item["download"]),
                start: date(item["start"] as? String))
        }
        return ConnectionSnapshot(uploadTotal: integer(object["uploadTotal"]),
                                  downloadTotal: integer(object["downloadTotal"]), connections: connections)
    }

    /// 按出口汇总当前连接，流量多的排在前面。
    public static func usage(_ connections: [ConnectionRecord]) -> [OutboundUsage] {
        var result: [String: OutboundUsage] = [:]
        for connection in connections {
            var entry = result[connection.outbound]
                ?? OutboundUsage(name: connection.outbound, route: connection.route, connections: 0, upload: 0, download: 0)
            entry.connections += 1
            entry.upload += connection.upload
            entry.download += connection.download
            result[connection.outbound] = entry
        }
        return result.values.sorted { ($0.total, $1.name) > ($1.total, $0.name) }
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        "\(SubscriptionUsage.format(Int64(max(0, bytesPerSecond))))/s"
    }
}
