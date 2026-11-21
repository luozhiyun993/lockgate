import Foundation
import LockgateCore

struct ProxyGroup: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let type: String
    let now: String
    let all: [String]

    var typeTitle: String {
        switch type {
        case "Selector": return "手动选择"
        case "URLTest": return "自动测速"
        case "Fallback": return "故障转移"
        case "LoadBalance": return "负载均衡"
        default: return type
        }
    }

    /// 负载均衡组没有「当前节点」，不提供手动选择。
    var selectable: Bool { type != "LoadBalance" }
}

struct ProxySnapshot: Equatable {
    var groups: [ProxyGroup] = []
    var delays: [String: Int] = [:]
}

/// mihomo 控制接口客户端。只连本机回环地址，并显式禁用代理，避免请求被系统代理转回内核自身。
struct MihomoAPI {
    let port: Int
    let secret: String

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private static func segment(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [],
                         body: [String: Any]? = nil, timeout: TimeInterval = 8) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.percentEncodedPath = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CoreError("控制接口地址无效。") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw CoreError(message ?? "内核控制接口返回 \(status)。")
        }
        return data
    }

    func version() async throws -> String {
        let data = try await request("GET", "/version", timeout: 2)
        guard let version = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String else {
            throw CoreError("内核未返回版本信息。")
        }
        return version
    }

    /// 策略组按配置中的顺序排列（取自内置 GLOBAL 组的成员顺序）。
    func snapshot() async throws -> ProxySnapshot {
        let data = try await request("GET", "/proxies")
        guard let proxies = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["proxies"] as? [String: [String: Any]] else {
            throw CoreError("内核未返回节点信息。")
        }
        var groups: [String: ProxyGroup] = [:]
        var delays: [String: Int] = [:]
        for (name, value) in proxies {
            if let last = (value["history"] as? [[String: Any]])?.last, let delay = last["delay"] as? Int, delay > 0 {
                delays[name] = delay
            }
            guard name != "GLOBAL", name != ProfileComposer.gateGroup, let all = value["all"] as? [String], let type = value["type"] as? String else { continue }
            groups[name] = ProxyGroup(name: name, type: type, now: value["now"] as? String ?? "", all: all)
        }
        let order = proxies["GLOBAL"]?["all"] as? [String] ?? []
        var ordered = order.compactMap { groups[$0] }
        let listed = Set(ordered.map(\.name))
        ordered += groups.values.filter { !listed.contains($0.name) }.sorted { $0.name < $1.name }
        return ProxySnapshot(groups: ordered, delays: delays)
    }

    /// 策略组当前选中的成员。
    func selected(group: String) async throws -> String {
        let data = try await request("GET", "/proxies/\(Self.segment(group))", timeout: 3)
        guard let now = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["now"] as? String else {
            throw CoreError("内核未返回策略组状态。")
        }
        return now
    }

    func select(group: String, node: String) async throws {
        _ = try await request("PUT", "/proxies/\(Self.segment(group))", body: ["name": node])
    }

    func setMode(_ mode: ProxyMode) async throws {
        _ = try await request("PATCH", "/configs", body: ["mode": mode.rawValue])
    }

    func reload(configPath: String) async throws {
        _ = try await request("PUT", "/configs", query: [URLQueryItem(name: "force", value: "true")],
                              body: ["path": configPath], timeout: 30)
    }

    func connections() async throws -> ConnectionSnapshot {
        guard let snapshot = ConnectionParser.parse(try await request("GET", "/connections", timeout: 4)) else {
            throw CoreError("内核未返回连接信息。")
        }
        return snapshot
    }

    func closeConnection(_ id: String) async {
        _ = try? await request("DELETE", "/connections/\(Self.segment(id))")
    }

    func closeConnections() async {
        _ = try? await request("DELETE", "/connections")
    }

    /// 对策略组内全部节点测速。全部超时时内核返回错误，这里视为没有结果。
    func testDelay(group: String) async -> [String: Int] {
        let query = [URLQueryItem(name: "url", value: ProfileComposer.testURL), URLQueryItem(name: "timeout", value: "5000")]
        guard let data = try? await request("GET", "/group/\(Self.segment(group))/delay", query: query, timeout: 20),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return [:] }
        return result
    }
}
