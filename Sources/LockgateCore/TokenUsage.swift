import Foundation

/// 本机会话日志里能读到 token 用量的 agent。
public enum UsageAgent: String, CaseIterable, Codable, Sendable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// 四类 token 互不重叠：`input` 不含缓存读写，相加即总量。
public struct TokenCounts: Equatable, Codable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    /// `cacheWrite` 中按长时效（Claude 的 1 小时缓存）计价的部分，只影响费用，不另计入总量。
    public var cacheWriteLong: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWriteLong: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWriteLong = cacheWriteLong
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                    cacheRead: lhs.cacheRead + rhs.cacheRead, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
                    cacheWriteLong: lhs.cacheWriteLong + rhs.cacheWriteLong)
    }

    public static func - (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input - rhs.input, output: lhs.output - rhs.output,
                    cacheRead: lhs.cacheRead - rhs.cacheRead, cacheWrite: lhs.cacheWrite - rhs.cacheWrite,
                    cacheWriteLong: lhs.cacheWriteLong - rhs.cacheWriteLong)
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }
}

public struct UsageBucketKey: Hashable, Codable, Sendable {
    public var agent: UsageAgent
    public var model: String
    /// 会话的工作目录；日志里没有时为空字符串。
    public var project: String
    public var session: String
    /// Claude Code 子代理类型；主会话为 nil。
    public var subagent: String?
    /// 所在自然日的零点（按解析时传入的日历）。
    public var day: Date
}

public struct UsageSample: Sendable {
    public var key: UsageBucketKey
    public var counts: TokenCounts
    /// 同一次请求可能在日志里出现多行，或被恢复的会话复制到另一个文件；有此标识时只计一次。
    public var dedupeID: String?
}

private func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

private func parseTimestamp(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

private func jsonObject(_ line: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
}

public enum ClaudeCodeUsageParser {
    /// 解析 `~/.claude/projects/**/*.jsonl` 的一行；只有带用量的助手消息才返回结果。
    public static func sample(line: Data, calendar: Calendar = .current) -> UsageSample? {
        guard let object = jsonObject(line), object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let time = parseTimestamp(object["timestamp"]) else { return nil }
        let counts = TokenCounts(input: int(usage["input_tokens"]), output: int(usage["output_tokens"]),
                                 cacheRead: int(usage["cache_read_input_tokens"]),
                                 cacheWrite: int(usage["cache_creation_input_tokens"]),
                                 cacheWriteLong: int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]))
        guard counts.total > 0 else { return nil }
        var model = (message["model"] as? String) ?? "unknown"
        if usage["speed"] as? String == "fast" { model += PriceTable.fastSuffix }
        var subagent: String?
        if object["isSidechain"] as? Bool == true {
            subagent = (object["attributionAgent"] as? String) ?? "subagent"
        }
        let key = UsageBucketKey(agent: .claudeCode, model: model,
                                 project: (object["cwd"] as? String) ?? "",
                                 session: (object["sessionId"] as? String) ?? "",
                                 subagent: subagent, day: calendar.startOfDay(for: time))
        var dedupeID = message["id"] as? String
        if let id = dedupeID, let request = object["requestId"] as? String { dedupeID = "\(id):\(request)" }
        return UsageSample(key: key, counts: counts, dedupeID: dedupeID)
    }
}

/// 解析 `~/.codex/sessions/**/*.jsonl`。模型和工作目录写在别的行里，所以每个文件要按顺序喂给同一个解析器。
public struct CodexUsageParser: Codable, Sendable {
    private var model = "unknown"
    private var project = ""
    private var session = ""
    private var previousTotal: TokenCounts?

    public init() {}

    public mutating func consume(line: Data, calendar: Calendar = .current) -> UsageSample? {
        guard let object = jsonObject(line), let payload = object["payload"] as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "session_meta":
            if let cwd = payload["cwd"] as? String { project = cwd }
            if let id = (payload["id"] ?? payload["session_id"]) as? String { session = id }
            if let name = payload["model"] as? String { model = name }
            return nil
        case "turn_context":
            if let name = payload["model"] as? String { model = name }
            if let cwd = payload["cwd"] as? String { project = cwd }
            return nil
        case "event_msg":
            guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                  let total = (info["total_token_usage"] as? [String: Any]).map(Self.counts),
                  let time = parseTimestamp(object["timestamp"]) else { return nil }
            // 日志记的是会话累计值，按差值计入；同一累计值重复出现时差值为零。
            var delta = total - (previousTotal ?? TokenCounts())
            if delta.input < 0 || delta.output < 0 || delta.cacheRead < 0 || delta.cacheWrite < 0 {
                // 累计值回退（会话被重置）时改用本次请求的用量。
                delta = (info["last_token_usage"] as? [String: Any]).map(Self.counts) ?? TokenCounts()
            }
            previousTotal = total
            guard delta.total > 0 else { return nil }
            let key = UsageBucketKey(agent: .codex, model: model, project: project, session: session,
                                     subagent: nil, day: calendar.startOfDay(for: time))
            return UsageSample(key: key, counts: delta, dedupeID: nil)
        default:
            return nil
        }
    }

    /// Codex 的 input_tokens 包含缓存部分，这里拆成互不重叠的四类。
    private static func counts(_ usage: [String: Any]) -> TokenCounts {
        let cached = int(usage["cached_input_tokens"])
        let written = int(usage["cache_write_input_tokens"])
        return TokenCounts(input: max(0, int(usage["input_tokens"]) - cached - written),
                           output: int(usage["output_tokens"]), cacheRead: cached, cacheWrite: written)
    }
}

/// 每百万 token 的美元单价。
public struct ModelPrice: Codable, Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// 缺省按输入价的 1.25 倍。
    public var cacheWrite: Double?
    /// 长时效缓存写入；缺省按输入价的 2 倍。
    public var cacheWriteLong: Double?

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double? = nil, cacheWriteLong: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWriteLong = cacheWriteLong
    }

    public func cost(of counts: TokenCounts) -> Double {
        let short = Double(counts.cacheWrite - counts.cacheWriteLong) * (cacheWrite ?? input * 1.25)
        let long = Double(counts.cacheWriteLong) * (cacheWriteLong ?? input * 2)
        return (Double(counts.input) * input + Double(counts.output) * output
                + Double(counts.cacheRead) * cacheRead + short + long) / 1_000_000
    }
}

/// 按公开 API 标准价估算费用的价格表。订阅套餐、第三方转发和长上下文加价不在此列，所以结果只是估算。
public struct PriceTable: Sendable {
    /// Claude 快速模式的请求在模型名后带此后缀，按标准价的 2 倍计。
    static let fastSuffix = " (fast)"
    /// 内置价格的核对日期。
    public static let builtInDate = "2026-11-24"

    public static let builtIn: [String: ModelPrice] = {
        var prices: [String: ModelPrice] = [
            "claude-fable-5-2": ModelPrice(input: 8, output: 40, cacheRead: 0.20),
            "claude-fable-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
            "claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1),
            "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.20),
            "claude-opus-5": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
            "claude-opus-4-8": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
            "claude-opus-4-7": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
            "claude-opus-4-6": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
            "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.10),
            "claude-sonnet-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20),
            "claude-sonnet-4-6": ModelPrice(input: 3, output: 15, cacheRead: 0.30),
            "claude-haiku-5-5": ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01),
            "claude-haiku-4-5": ModelPrice(input: 1, output: 5, cacheRead: 0.10),
            "gpt-6.2-astra": ModelPrice(input: 8, output: 40, cacheRead: 0.40),
            "gpt-6.2-sol": ModelPrice(input: 2, output: 10, cacheRead: 0.10),
            "gpt-6.1-sol": ModelPrice(input: 2, output: 10, cacheRead: 0.10),
            "gpt-6.1-terra": ModelPrice(input: 1, output: 5, cacheRead: 0.05),
            "gpt-6-astra": ModelPrice(input: 10, output: 50, cacheRead: 1),
            "gpt-6-sol": ModelPrice(input: 2, output: 10, cacheRead: 0.20),
            "gpt-6-luna": ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01),
            "gpt-5.3-codex": ModelPrice(input: 1.75, output: 14, cacheRead: 0.175),
        ]
        for name in ["5-2", "5-1", "5"] { prices["claude-mythos-\(name)"] = prices["claude-fable-\(name)"] }
        return prices
    }()

    private let prices: [String: ModelPrice]

    /// `overrides` 里的同名模型覆盖内置价格，也可以补充内置表没有的模型。
    public init(overrides: [String: ModelPrice] = [:]) {
        prices = Self.builtIn.merging(overrides) { _, custom in custom }
    }

    /// 用户手动联网更新得到的价格快照。
    public struct RemoteSnapshot: Codable, Equatable, Sendable {
        public var fetched: Date
        public var prices: [String: ModelPrice]

        public init(fetched: Date, prices: [String: ModelPrice]) {
            self.fetched = fetched
            self.prices = prices
        }
    }

    public static let remoteFileName = "model-prices-remote.json"
    public static let overridesFileName = "model-prices.json"

    public static func remoteSnapshot(in directory: URL) -> RemoteSnapshot? {
        (try? Data(contentsOf: directory.appendingPathComponent(remoteFileName)))
            .flatMap { try? JSONDecoder().decode(RemoteSnapshot.self, from: $0) }
    }

    /// 优先级从低到高：内置价格 < 联网更新的快照 < 用户价格文件
    /// （`{"模型名": {"input": 1, "output": 2, "cacheRead": 0.1}}`）。文件不存在或格式不对时跳过。
    public init(directory: URL) {
        let custom = (try? Data(contentsOf: directory.appendingPathComponent(Self.overridesFileName)))
            .flatMap { try? JSONDecoder().decode([String: ModelPrice].self, from: $0) }
        let remote = Self.remoteSnapshot(in: directory)?.prices ?? [:]
        self.init(overrides: remote.merging(custom ?? [:]) { _, custom in custom })
    }

    /// 解析 LiteLLM 公开的 `model_prices_and_context_window.json`，只取 Anthropic 与 OpenAI 直连型号的标准价。
    public static func parseLiteLLM(_ data: Data) -> [String: ModelPrice] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        func perMillion(_ value: Any?) -> Double? {
            guard let number = (value as? NSNumber)?.doubleValue, number >= 0, number.isFinite else { return nil }
            return number * 1_000_000
        }
        var prices: [String: ModelPrice] = [:]
        for (name, value) in root where !name.contains("/") {
            guard let entry = value as? [String: Any],
                  ["anthropic", "openai"].contains(entry["litellm_provider"] as? String ?? ""),
                  let input = perMillion(entry["input_cost_per_token"]), input > 0,
                  let output = perMillion(entry["output_cost_per_token"]) else { continue }
            prices[name] = ModelPrice(input: input, output: output,
                                      cacheRead: perMillion(entry["cache_read_input_token_cost"]) ?? input,
                                      cacheWrite: perMillion(entry["cache_creation_input_token_cost"]),
                                      cacheWriteLong: perMillion(entry["cache_creation_input_token_cost_above_1hr"]))
        }
        return prices
    }

    /// 精确匹配，或模型名只多出日期 / 上下文后缀（`-20251101`、`[1m]`）；不按系列猜测未知型号的价格。
    public func price(for model: String) -> (price: ModelPrice, multiplier: Double)? {
        let fast = model.hasSuffix(Self.fastSuffix)
        let name = fast ? String(model.dropLast(Self.fastSuffix.count)) : model
        let match = prices[name] ?? prices.filter { entry in
            guard name.hasPrefix(entry.key) else { return false }
            let rest = name.dropFirst(entry.key.count)
            return rest.hasPrefix("-20") || rest.hasPrefix("[") || rest.hasPrefix("@")
        }.max { $0.key.count < $1.key.count }?.value
        return match.map { ($0, fast ? 2 : 1) }
    }

    public func cost(model: String, counts: TokenCounts) -> Double? {
        price(for: model).map { $0.price.cost(of: counts) * $0.multiplier }
    }
}

public struct UsageRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var agent: UsageAgent
    public var counts: TokenCounts
    public var sessions: Int
    /// 估算费用（美元），只含价格已知的模型。
    public var cost: Double
    /// 价格未知、未计入费用的 token 数。
    public var unpriced: Int
}

public struct UsageDay: Identifiable, Equatable, Sendable {
    public var day: Date
    public var agent: UsageAgent
    public var tokens: Int
    public var cost: Double
    public var id: String { "\(agent.rawValue)-\(day.timeIntervalSince1970)" }
}

public struct UsageSummary: Equatable, Sendable {
    public var total = TokenCounts()
    public var sessions = 0
    public var cost = 0.0
    public var unpriced = 0
    public var agents: [UsageRow] = []
    public var models: [UsageRow] = []
    public var projects: [UsageRow] = []
    /// Claude Code 主会话与各类子代理。
    public var subagents: [UsageRow] = []
    public var days: [UsageDay] = []

    public init() {}
}

/// 所有日志汇总后的用量账本。
public struct UsageLedger: Sendable {
    private struct Seen: Sendable {
        var source: String
        var key: UsageBucketKey
        var counts: TokenCounts
    }

    public private(set) var buckets: [UsageBucketKey: TokenCounts] = [:]
    private var seen: [String: Seen] = [:]

    public init() {}

    /// `source` 标识样本来自哪个文件：同一文件内重复的请求以后出现的为准，其他文件里的副本忽略。
    public mutating func add(_ sample: UsageSample, source: String) {
        if let id = sample.dedupeID {
            if let previous = seen[id] {
                guard previous.source == source, previous.counts != sample.counts else { return }
                buckets[previous.key, default: TokenCounts()] += TokenCounts() - previous.counts
            }
            seen[id] = Seen(source: source, key: sample.key, counts: sample.counts)
        }
        buckets[sample.key, default: TokenCounts()] += sample.counts
    }

    /// 只统计 `since` 当日及之后、`until` 当日及之前；为 nil 的一端不设限。
    public func summary(since: Date? = nil, until: Date? = nil, prices: PriceTable = PriceTable()) -> UsageSummary {
        struct Group {
            var name: String
            var agent: UsageAgent
            var counts = TokenCounts()
            var sessions = Set<String>()
            var cost = 0.0
            var unpriced = 0
        }
        var agents: [String: Group] = [:], models: [String: Group] = [:]
        var projects: [String: Group] = [:], subagents: [String: Group] = [:]
        var days: [UsageDay.ID: UsageDay] = [:]
        var sessions = Set<String>()
        var summary = UsageSummary()

        var cost: Double?

        func add(_ groups: inout [String: Group], id: String, name: String, key: UsageBucketKey, counts: TokenCounts) {
            var group = groups[id] ?? Group(name: name, agent: key.agent)
            group.counts += counts
            if let cost { group.cost += cost } else { group.unpriced += counts.total }
            group.sessions.insert(key.agent.rawValue + key.session)
            groups[id] = group
        }

        for (key, counts) in buckets where key.day >= since ?? key.day && key.day <= until ?? key.day {
            cost = prices.cost(model: key.model, counts: counts)
            summary.total += counts
            if let cost { summary.cost += cost } else { summary.unpriced += counts.total }
            sessions.insert(key.agent.rawValue + key.session)
            add(&agents, id: key.agent.rawValue, name: key.agent.displayName, key: key, counts: counts)
            add(&models, id: "\(key.agent.rawValue)/\(key.model)", name: key.model, key: key, counts: counts)
            add(&projects, id: "\(key.agent.rawValue)/\(key.project)", name: key.project, key: key, counts: counts)
            if key.agent == .claudeCode {
                add(&subagents, id: key.subagent ?? "", name: key.subagent ?? "", key: key, counts: counts)
            }
            var day = UsageDay(day: key.day, agent: key.agent, tokens: 0, cost: 0)
            day = days[day.id] ?? day
            day.tokens += counts.total
            day.cost += cost ?? 0
            days[day.id] = day
        }

        func rows(_ groups: [String: Group]) -> [UsageRow] {
            groups.map { UsageRow(id: $0.key, name: $0.value.name, agent: $0.value.agent,
                                  counts: $0.value.counts, sessions: $0.value.sessions.count,
                                  cost: $0.value.cost, unpriced: $0.value.unpriced) }
                .sorted { ($0.counts.total, $1.id) > ($1.counts.total, $0.id) }
        }
        summary.sessions = sessions.count
        summary.agents = rows(agents)
        summary.models = rows(models)
        summary.projects = rows(projects)
        summary.subagents = rows(subagents)
        summary.days = days.values.sorted { ($0.day, $0.agent.rawValue) < ($1.day, $1.agent.rawValue) }
        return summary
    }
}

/// 账本落盘时把重复出现的分组和来源文件换成下标，避免每条去重记录都带一份完整路径。
extension UsageLedger: Codable {
    private struct Stored: Codable {
        var keys: [UsageBucketKey] = []
        var counts: [TokenCounts] = []
        var sources: [String] = []
        var seenIDs: [String] = []
        var seenKeys: [Int] = []
        var seenSources: [Int] = []
        var seenCounts: [TokenCounts] = []
    }

    public init(from decoder: Decoder) throws {
        let stored = try Stored(from: decoder)
        let count = stored.seenIDs.count
        guard stored.counts.count == stored.keys.count, stored.seenKeys.count == count,
              stored.seenSources.count == count, stored.seenCounts.count == count,
              stored.seenKeys.allSatisfy(stored.keys.indices.contains),
              stored.seenSources.allSatisfy(stored.sources.indices.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "账本缓存不一致"))
        }
        buckets = Dictionary(zip(stored.keys, stored.counts)) { $0 + $1 }
        for index in 0..<count {
            seen[stored.seenIDs[index]] = Seen(source: stored.sources[stored.seenSources[index]],
                                               key: stored.keys[stored.seenKeys[index]], counts: stored.seenCounts[index])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var stored = Stored()
        var keyIndex: [UsageBucketKey: Int] = [:], sourceIndex: [String: Int] = [:]
        for (key, counts) in buckets {
            keyIndex[key] = stored.keys.count
            stored.keys.append(key)
            stored.counts.append(counts)
        }
        for (id, entry) in seen {
            guard let key = keyIndex[entry.key] else { continue }
            if sourceIndex[entry.source] == nil {
                sourceIndex[entry.source] = stored.sources.count
                stored.sources.append(entry.source)
            }
            stored.seenIDs.append(id)
            stored.seenKeys.append(key)
            stored.seenSources.append(sourceIndex[entry.source] ?? 0)
            stored.seenCounts.append(entry.counts)
        }
        try stored.encode(to: encoder)
    }
}

/// 增量扫描本机会话日志。文件只追加，所以每次只读上次之后新增的完整行。
public actor TokenUsageScanner {
    private struct FileState: Codable {
        var offset: UInt64 = 0
        var codex = CodexUsageParser()
    }

    /// 落盘的扫描进度：各文件读到的位置和已汇总的账本。
    private struct Cache: Codable {
        static let currentVersion = 1
        var version = Cache.currentVersion
        /// 账本按自然日分组，换了时区就不能沿用。
        var timeZone: String
        var files: [String: FileState]
        var ledger: UsageLedger
    }

    public static let cacheFileName = "token-usage-cache.plist"

    private let roots: [(agent: UsageAgent, directory: URL)]
    private let calendar: Calendar
    private let cache: URL?
    private var loaded = false
    private var files: [String: FileState] = [:]
    private var ledger = UsageLedger()

    public static var defaultRoots: [(agent: UsageAgent, directory: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [(.claudeCode, home.appendingPathComponent(".claude/projects")),
                (.claudeCode, home.appendingPathComponent(".config/claude/projects")),
                (.codex, home.appendingPathComponent(".codex/sessions")),
                (.codex, home.appendingPathComponent(".codex/archived_sessions"))]
    }

    /// 给了 `cache` 就把扫描进度存到该文件，下次启动接着读，不再重算历史。
    public init(roots: [(agent: UsageAgent, directory: URL)] = TokenUsageScanner.defaultRoots,
                calendar: Calendar = .current, cache: URL? = nil) {
        self.roots = roots
        self.calendar = calendar
        self.cache = cache
    }

    /// 丢弃缓存和已汇总的用量，下次 `refresh` 从头扫描。日志已被 agent 清理的用量随之消失。
    public func clearCache() {
        loaded = true
        files = [:]
        ledger = UsageLedger()
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard let cache, let data = try? Data(contentsOf: cache),
              let stored = try? PropertyListDecoder().decode(Cache.self, from: data),
              stored.version == Cache.currentVersion, stored.timeZone == calendar.timeZone.identifier else { return }
        files = stored.files
        ledger = stored.ledger
    }

    private func saveCache() {
        guard let cache else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Cache(timeZone: calendar.timeZone.identifier, files: files, ledger: ledger))
        else { return }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 缓存里有项目路径，只让当前用户读。
        guard (try? data.write(to: cache, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
    }

    /// 读取新增内容并返回最新账本。已被 agent 清理掉的旧日志，其用量保留在账本（和缓存）里。
    public func refresh() -> UsageLedger {
        loadCache()
        var changed = false
        var listing: [(agent: UsageAgent, url: URL, size: UInt64)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root.directory, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                listing.append((root.agent, url, UInt64(size)))
            }
        }
        // 文件变短说明被改写，已计入的内容无法单独撤销，整体重算。
        if listing.contains(where: { $0.size < (files[$0.url.path]?.offset ?? 0) }) {
            files = [:]
            ledger = UsageLedger()
            changed = true
        }
        for entry in listing {
            if Task.isCancelled { break }
            var state = files[entry.url.path] ?? FileState()
            guard entry.size > state.offset else { continue }
            let before = state.offset
            read(entry.url, agent: entry.agent, state: &state)
            files[entry.url.path] = state
            changed = changed || state.offset != before
        }
        if changed { saveCache() }
        return ledger
    }

    private func read(_ url: URL, agent: UsageAgent, state: inout FileState) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil else { return }
        let source = url.path
        var pending = Data()
        var searched = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            var start = 0
            pending.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                var cursor = searched
                while cursor < buffer.count,
                      let hit = memchr(base + cursor, 0x0A, buffer.count - cursor) {
                    let end = base.distance(to: UnsafeRawPointer(hit))
                    let line = UnsafeRawBufferPointer(rebasing: buffer[start..<end])
                    if let sample = sample(line, agent: agent, parser: &state.codex) {
                        ledger.add(sample, source: source)
                    }
                    start = end + 1
                    cursor = start
                }
            }
            state.offset += UInt64(start)
            pending.removeSubrange(0..<start)
            searched = pending.count
        }
    }

    private func sample(_ line: UnsafeRawBufferPointer, agent: UsageAgent,
                        parser: inout CodexUsageParser) -> UsageSample? {
        // 日志里绝大多数行与用量无关，且可能有数 MB；先按字节筛掉，再做 JSON 解析。
        switch agent {
        case .claudeCode:
            guard Self.contains("\"usage\"", in: line) else { return nil }
            return ClaudeCodeUsageParser.sample(line: Data(line), calendar: calendar)
        case .codex:
            let head = UnsafeRawBufferPointer(rebasing: line.prefix(400))
            guard ["token_count", "turn_context", "session_meta"].contains(where: { Self.contains($0, in: head) })
            else { return nil }
            return parser.consume(line: Data(line), calendar: calendar)
        }
    }

    private static func contains(_ needle: String, in haystack: UnsafeRawBufferPointer) -> Bool {
        guard let base = haystack.baseAddress else { return false }
        return needle.utf8CString.withUnsafeBufferPointer {
            memmem(base, haystack.count, $0.baseAddress, $0.count - 1) != nil
        }
    }
}
