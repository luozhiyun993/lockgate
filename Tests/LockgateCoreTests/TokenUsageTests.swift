import XCTest
@testable import LockgateCore

final class TokenUsageTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func claudeLine(id: String = "msg_1", time: String = "2026-11-24T06:20:34.807Z", output: Int = 239,
                            sidechain: Bool = false, type: String = "assistant") -> Data {
        Data("""
        {"isSidechain":\(sidechain),"attributionAgent":"Explore","message":{"id":"\(id)","model":"claude-fable-5-2",\
        "usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":\(output)}},\
        "requestId":"req_1","type":"\(type)","timestamp":"\(time)","cwd":"/work/app","sessionId":"s1"}
        """.utf8)
    }

    private func codexCount(total input: Int, cached: Int, output: Int, time: String = "2026-11-23T09:48:49.659Z") -> Data {
        Data("""
        {"timestamp":"\(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\
        {"input_tokens":\(input),"cached_input_tokens":\(cached),"cache_write_input_tokens":0,"output_tokens":\(output),\
        "reasoning_output_tokens":5,"total_tokens":\(input + output)},"last_token_usage":{"input_tokens":7,\
        "cached_input_tokens":3,"output_tokens":1}}}}
        """.utf8)
    }

    func testClaudeLineSplitsTokenKindsAndMarksSubagents() throws {
        let main = try XCTUnwrap(ClaudeCodeUsageParser.sample(line: claudeLine(), calendar: calendar))
        XCTAssertEqual(main.counts, TokenCounts(input: 2, output: 239, cacheRead: 1000, cacheWrite: 100))
        XCTAssertEqual(main.counts.total, 1341)
        XCTAssertEqual(main.key.model, "claude-fable-5-2")
        XCTAssertEqual(main.key.project, "/work/app")
        XCTAssertNil(main.key.subagent)
        XCTAssertEqual(main.key.day, calendar.date(from: DateComponents(year: 2026, month: 11, day: 24)))
        let side = try XCTUnwrap(ClaudeCodeUsageParser.sample(line: claudeLine(sidechain: true), calendar: calendar))
        XCTAssertEqual(side.key.subagent, "Explore")
    }

    func testClaudeIgnoresLinesWithoutBillableUsage() {
        XCTAssertNil(ClaudeCodeUsageParser.sample(line: claudeLine(type: "user"), calendar: calendar))
        XCTAssertNil(ClaudeCodeUsageParser.sample(line: Data("not json".utf8), calendar: calendar))
        XCTAssertNil(ClaudeCodeUsageParser.sample(line: Data(#"{"type":"assistant","message":{}}"#.utf8)))
    }

    func testLedgerCountsRepeatedRequestOnce() throws {
        var ledger = UsageLedger()
        let first = try XCTUnwrap(ClaudeCodeUsageParser.sample(line: claudeLine(output: 10), calendar: calendar))
        let final = try XCTUnwrap(ClaudeCodeUsageParser.sample(line: claudeLine(output: 239), calendar: calendar))
        ledger.add(first, source: "a")
        ledger.add(final, source: "a")   // 同一请求的后续行：以最后一次为准
        ledger.add(final, source: "a")
        ledger.add(first, source: "b")   // 恢复会话复制出的副本：忽略
        XCTAssertEqual(ledger.summary().total, final.counts)
        XCTAssertEqual(ledger.summary().sessions, 1)
    }

    func testCodexUsesCumulativeDeltasAndSeparatesCachedInput() throws {
        var parser = CodexUsageParser()
        XCTAssertNil(parser.consume(line: Data(#"{"type":"session_meta","payload":{"id":"c1","cwd":"/work/api"}}"#.utf8)))
        XCTAssertNil(parser.consume(line: Data(#"{"type":"turn_context","payload":{"model":"gpt-x"}}"#.utf8)))
        let first = try XCTUnwrap(parser.consume(line: codexCount(total: 1000, cached: 400, output: 20), calendar: calendar))
        XCTAssertEqual(first.counts, TokenCounts(input: 600, output: 20, cacheRead: 400))
        XCTAssertEqual(first.key.model, "gpt-x")
        XCTAssertEqual(first.key.project, "/work/api")
        XCTAssertEqual(first.key.session, "c1")
        // 累计值没变的重复事件不重复计数。
        XCTAssertNil(parser.consume(line: codexCount(total: 1000, cached: 400, output: 20), calendar: calendar))
        let second = try XCTUnwrap(parser.consume(line: codexCount(total: 2500, cached: 1400, output: 50), calendar: calendar))
        XCTAssertEqual(second.counts, TokenCounts(input: 500, output: 30, cacheRead: 1000))
        // 累计值回退时改用本次请求用量。
        let reset = try XCTUnwrap(parser.consume(line: codexCount(total: 100, cached: 0, output: 1), calendar: calendar))
        XCTAssertEqual(reset.counts, TokenCounts(input: 4, output: 1, cacheRead: 3))
    }

    func testSummaryGroupsByAgentModelProjectAndFiltersByDay() throws {
        var ledger = UsageLedger()
        ledger.add(try XCTUnwrap(ClaudeCodeUsageParser.sample(line: claudeLine(id: "a"), calendar: calendar)), source: "f")
        ledger.add(try XCTUnwrap(ClaudeCodeUsageParser.sample(
            line: claudeLine(id: "b", time: "2026-11-20T01:00:00Z", sidechain: true), calendar: calendar)), source: "f")
        var parser = CodexUsageParser()
        ledger.add(try XCTUnwrap(parser.consume(line: codexCount(total: 5000, cached: 0, output: 0), calendar: calendar)),
                   source: "g")

        let all = ledger.summary()
        XCTAssertEqual(all.total.total, 1341 * 2 + 5000)
        XCTAssertEqual(all.agents.map(\.name), ["Codex", "Claude Code"])
        XCTAssertEqual(all.agents.map(\.counts.total), [5000, 2682])
        XCTAssertEqual(all.subagents.map(\.name).sorted(), ["", "Explore"])
        XCTAssertEqual(all.days.count, 3)
        XCTAssertEqual(all.sessions, 2)

        let recent = ledger.summary(since: calendar.date(from: DateComponents(year: 2026, month: 11, day: 23)))
        XCTAssertEqual(recent.total.total, 1341 + 5000)
        XCTAssertEqual(recent.subagents.map(\.name), [""])

        let oneDay = calendar.date(from: DateComponents(year: 2026, month: 11, day: 23))
        let single = ledger.summary(since: oneDay, until: oneDay)
        XCTAssertEqual(single.total.total, 5000)
        XCTAssertEqual(single.agents.map(\.name), ["Codex"])
    }

    private func assertCost(_ cost: Double?, _ expected: Double) throws {
        let value = try XCTUnwrap(cost)
        XCTAssertEqual(value, expected, accuracy: 1e-9)
    }

    func testCostUsesPerModelPricesAndCacheWriteTiers() throws {
        let prices = PriceTable()
        // 100 万输入 $4 + 100 万输出 $20 + 100 万缓存读取 $0.20 + 100 万写入（其中 40 万为 1 小时：0.6×5 + 0.4×8）
        let counts = TokenCounts(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
                                 cacheWrite: 1_000_000, cacheWriteLong: 400_000)
        try assertCost(prices.cost(model: "claude-opus-5-5", counts: counts), 30.4)
        try assertCost(prices.cost(model: "claude-opus-5-5 (fast)", counts: counts), 60.8)
        try assertCost(prices.cost(model: "claude-opus-4-6-20260101", counts: TokenCounts(input: 1_000_000)), 5)
        try assertCost(prices.cost(model: "gpt-6.2-sol", counts: TokenCounts(output: 500_000, cacheRead: 2_000_000)), 5.2)
        // 未知型号不按系列猜价。
        XCTAssertNil(prices.cost(model: "claude-opus-5-9", counts: counts))
        XCTAssertNil(prices.cost(model: "gpt-x", counts: counts))
        let custom = PriceTable(overrides: ["gpt-x": ModelPrice(input: 1, output: 2, cacheRead: 0)])
        try assertCost(custom.cost(model: "gpt-x", counts: counts), 1 + 2 + 0.75 + 0.8)
    }

    func testRemotePriceSnapshotParsesAndRanksBelowUserFile() throws {
        let parsed = PriceTable.parseLiteLLM(Data("""
        {"sample_spec":{"input_cost_per_token":0,"litellm_provider":"openai"},
         "claude-new":{"litellm_provider":"anthropic","input_cost_per_token":3e-06,"output_cost_per_token":1.5e-05,
          "cache_read_input_token_cost":3e-07,"cache_creation_input_token_cost":3.75e-06,
          "cache_creation_input_token_cost_above_1hr":6e-06},
         "gpt-new":{"litellm_provider":"openai","input_cost_per_token":1e-06,"output_cost_per_token":2e-06},
         "bedrock/claude-new":{"litellm_provider":"anthropic","input_cost_per_token":9e-06,"output_cost_per_token":9e-06},
         "other":{"litellm_provider":"azure","input_cost_per_token":1e-06,"output_cost_per_token":2e-06},
         "image":{"litellm_provider":"openai","output_cost_per_image":0.04}}
        """.utf8))
        XCTAssertEqual(parsed.keys.sorted(), ["claude-new", "gpt-new"])
        let claude = try XCTUnwrap(parsed["claude-new"])
        try assertCost(claude.input, 3)
        try assertCost(claude.cacheWriteLong, 6)
        try assertCost(parsed["gpt-new"]?.cacheRead, 1)   // 没有缓存价时按输入价
        XCTAssertEqual(PriceTable.parseLiteLLM(Data("oops".utf8)).count, 0)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lockgate-prices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let million = TokenCounts(input: 1_000_000)
        try assertCost(PriceTable(directory: directory).cost(model: "claude-opus-5-5", counts: million), 4)
        let snapshot = PriceTable.RemoteSnapshot(fetched: Date(timeIntervalSince1970: 0), prices: [
            "claude-opus-5-5": ModelPrice(input: 3, output: 15, cacheRead: 0.1), "claude-new": claude])
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent(PriceTable.remoteFileName))
        try assertCost(PriceTable(directory: directory).cost(model: "claude-opus-5-5", counts: million), 3)
        try assertCost(PriceTable(directory: directory).cost(model: "claude-new", counts: million), 3)
        XCTAssertEqual(PriceTable.remoteSnapshot(in: directory), snapshot)
        try Data(#"{"claude-opus-5-5":{"input":7,"output":7,"cacheRead":7}}"#.utf8)
            .write(to: directory.appendingPathComponent(PriceTable.overridesFileName))
        try assertCost(PriceTable(directory: directory).cost(model: "claude-opus-5-5", counts: million), 7)
    }

    func testSummaryReportsCostAndTokensWithoutKnownPrice() throws {
        var ledger = UsageLedger()
        ledger.add(try XCTUnwrap(ClaudeCodeUsageParser.sample(line: claudeLine(), calendar: calendar)), source: "f")
        var parser = CodexUsageParser()
        _ = parser.consume(line: Data(#"{"type":"turn_context","payload":{"model":"gpt-x"}}"#.utf8))
        ledger.add(try XCTUnwrap(parser.consume(line: codexCount(total: 5000, cached: 0, output: 0), calendar: calendar)),
                   source: "g")
        let summary = ledger.summary()
        // claude-fable-5-2：2 输入 $8 + 239 输出 $40 + 1000 读取 $0.20 + 100 写入（5 分钟档）$10，均为每百万。
        let expected = 0.010776   // (16 + 9560 + 200 + 1000) / 1_000_000
        XCTAssertEqual(summary.cost, expected, accuracy: 1e-12)
        XCTAssertEqual(summary.unpriced, 5000)
        XCTAssertEqual(summary.agents.first { $0.agent == .codex }?.unpriced, 5000)
        try assertCost(summary.agents.first { $0.agent == .claudeCode }?.cost, expected)
    }

    func testScannerReadsOnlyAppendedCompleteLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lockgate-usage-\(UUID().uuidString)")
        let file = root.appendingPathComponent("project/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let newline = Data("\n".utf8)
        let partial = claudeLine(id: "b")
        try (claudeLine(id: "a") + newline + partial.prefix(40)).write(to: file)

        let scanner = TokenUsageScanner(roots: [(.claudeCode, root)], calendar: calendar)
        var total = await scanner.refresh().summary().total.total
        XCTAssertEqual(total, 1341, "写到一半的行要等写完再计入")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: partial.dropFirst(40) + newline)
        try handle.close()
        total = await scanner.refresh().summary().total.total
        XCTAssertEqual(total, 2682)
        total = await scanner.refresh().summary().total.total
        XCTAssertEqual(total, 2682, "没有新增内容时不重复计数")

        try (claudeLine(id: "c") + newline).write(to: file)
        total = await scanner.refresh().summary().total.total
        XCTAssertEqual(total, 1341, "文件被改写后整体重算")
    }
}
