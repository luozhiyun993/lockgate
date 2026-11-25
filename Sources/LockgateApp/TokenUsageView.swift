import AppKit
import Charts
import SwiftUI
import LockgateCore

@MainActor
final class TokenUsageModel: ObservableObject {
    enum Range: String, CaseIterable {
        case today = "今天"
        case week = "近 7 天"
        case month = "近 30 天"
        case all = "全部"

        var days: Int? {
            switch self {
            case .today: return 1
            case .week: return 7
            case .month: return 30
            case .all: return nil
            }
        }
    }

    enum Metric: String, CaseIterable {
        case cost = "估算费用"
        case tokens = "Token"
    }

    @Published var range: Range = .week { didSet { summarize() } }
    @Published var metric: Metric = .cost
    @Published private(set) var summary = UsageSummary()
    /// 全部历史的逐日用量，供趋势图和日历使用，不随时间范围变化。
    @Published private(set) var allDays: [UsageDay] = []
    @Published private(set) var loading = false
    @Published private(set) var updated: Date?
    @Published private(set) var pricesFetched: Date?
    @Published private(set) var updatingPrices = false
    @Published private(set) var priceNotice = ""
    /// LiteLLM 项目公开维护的价格文件；只在用户点击「更新价格表」时请求，不带任何凭据。
    static let priceSource = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private let scanner = TokenUsageScanner(
        cache: StateStore.defaultDirectory.appendingPathComponent(TokenUsageScanner.cacheFileName))
    private var ledger = UsageLedger()

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        ledger = await scanner.refresh()
        updated = Date()
        summarize()
    }

    /// 丢弃本地缓存并从现存日志重新统计。
    func clearCache() async {
        await scanner.clearCache()
        // 正在进行的刷新会在清空后的状态上继续，这里等它结束再完整重扫一遍。
        while loading { try? await Task.sleep(nanoseconds: 100_000_000) }
        await refresh()
    }

    func updatePrices() async {
        guard !updatingPrices else { return }
        updatingPrices = true
        defer { updatingPrices = false }
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            let (data, response) = try await URLSession(configuration: configuration).data(from: Self.priceSource)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                priceNotice = "更新失败：服务器没有返回价格文件，仍使用原有价格。"
                return
            }
            let prices = await Task.detached { PriceTable.parseLiteLLM(data) }.value
            // 条目过少说明文件格式变了，不拿它覆盖现有价格。
            guard prices.count >= 20 else {
                priceNotice = "更新失败：价格文件格式无法识别，仍使用原有价格。"
                return
            }
            let file = StateStore.defaultDirectory.appendingPathComponent(PriceTable.remoteFileName)
            try FileManager.default.createDirectory(at: StateStore.defaultDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(PriceTable.RemoteSnapshot(fetched: Date(), prices: prices)).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            priceNotice = "已更新 \(prices.count) 个型号的价格。"
            summarize()
        } catch {
            priceNotice = "更新失败：\(error.localizedDescription) 仍使用原有价格。"
        }
    }

    /// 某一天的完整汇总，供日历的当日详情使用。
    func detail(for day: Date) -> UsageSummary {
        ledger.summary(since: day, until: day, prices: PriceTable(directory: StateStore.defaultDirectory))
    }

    private func summarize() {
        let today = Calendar.current.startOfDay(for: Date())
        let since = range.days.flatMap { Calendar.current.date(byAdding: .day, value: 1 - $0, to: today) }
        // 联网更新的快照和用户价格文件都是可选的，每次汇总时重新读取。
        let prices = PriceTable(directory: StateStore.defaultDirectory)
        summary = ledger.summary(since: since, prices: prices)
        allDays = since == nil ? summary.days : ledger.summary(prices: prices).days
        pricesFetched = PriceTable.remoteSnapshot(in: StateStore.defaultDirectory)?.fetched
    }
}

private extension UsageAgent {
    /// 颜色按 agent 固定，不随排序或筛选变化。Codex 用墨色，随明暗模式自动反转。
    var color: Color {
        switch self {
        case .claudeCode: return Color(red: 0.851, green: 0.467, blue: 0.341)
        case .codex: return Color.primary
        }
    }
}

private func compact(_ tokens: Int) -> String {
    let value = Double(tokens)
    switch tokens {
    case 1_000_000_000...: return String(format: "%.2fB", value / 1e9)
    case 1_000_000...: return String(format: "%.1fM", value / 1e6)
    case 10_000...: return String(format: "%.0fK", value / 1e3)
    case 1_000...: return String(format: "%.1fK", value / 1e3)
    default: return "\(tokens)"
    }
}

private func dollars(_ cost: Double) -> String {
    cost > 0 && cost < 0.01 ? "<$0.01" : String(format: "$%.2f", cost)
}

private func exact(_ tokens: Int) -> String { tokens.formatted(.number.grouping(.automatic)) }

private func breakdown(_ counts: TokenCounts) -> String {
    "输入 \(exact(counts.input)) · 输出 \(exact(counts.output)) · 缓存读取 \(exact(counts.cacheRead)) · 缓存写入 \(exact(counts.cacheWrite))"
}

private func percent(_ part: Double, of whole: Double) -> String {
    whole > 0 ? String(format: "%.0f%%", part / whole * 100) : "0%"
}

struct TokenUsageView: View {
    private enum Breakdown: String, CaseIterable {
        case models = "模型"
        case directories = "项目目录"
        case subagents = "子代理"
        case days = "按天"
    }

    private struct Entry: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var color: Color?
        var cost: Double
        var tokens: Int
        var unpriced: Int
        var help: String
    }

    @ObservedObject var model: TokenUsageModel
    @State private var hoveredDay: Date?
    @State private var selectedDay: Date?
    @State private var tab: Breakdown = .models
    @State private var expanded = false
    @State private var confirmingClear = false

    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var usesCost: Bool { model.metric == .cost }

    var body: some View {
        Group {
            HStack(spacing: 12) {
                Picker("指标", selection: $model.metric) {
                    ForEach(TokenUsageModel.Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Picker("时间范围", selection: $model.range) {
                    ForEach(TokenUsageModel.Range.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                if let updated = model.updated {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.loading)
            }

            if model.updated == nil {
                panel {
                    Text("正在读取本机会话日志…").font(.system(size: 14, weight: .medium))
                    Text("首次读取需要扫描全部日志，通常几秒内完成。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                hero
                HStack(alignment: .top, spacing: 16) {
                    trend.frame(maxHeight: .infinity)
                    heatmap.frame(width: 348)
                }.fixedSize(horizontal: false, vertical: true)
                section("各 Agent", detail: model.range.rawValue)
                programs
                section("明细", detail: model.range.rawValue)
                Picker("明细维度", selection: $tab) {
                    ForEach(Breakdown.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                    .onChange(of: tab) { _ in expanded = false }
                list(entries(for: tab))
            }
            footer
        }
        .task {
            // 页面打开期间自动增量统计；只读本机文件。
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    // MARK: 顶部总览

    private var hero: some View {
        let summary = model.summary
        return VStack(alignment: .leading, spacing: 4) {
            Text(usesCost ? "按 API 价估算的费用 · \(model.range.rawValue)" : "Token 用量 · \(model.range.rawValue)")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text(usesCost ? dollars(summary.cost) + (summary.unpriced > 0 ? "+" : "") : compact(summary.total.total))
                .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                .help(usesCost ? (summary.unpriced > 0 ? "另有 \(exact(summary.unpriced)) token 价格未知，未计入" : "按公开 API 标准价估算")
                               : "\(exact(summary.total.total)) token")
            Text(usesCost ? "\(compact(summary.total.total)) token · \(summary.sessions) 个会话"
                          : "估算 \(dollars(summary.cost)) · \(summary.sessions) 个会话")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text(breakdown(summary.total)).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
        }.padding(.horizontal, 4)
    }

    // MARK: 趋势图

    /// 趋势图覆盖的日期：至少最近 7 天，随时间范围放宽。
    private var trendDates: [Date] {
        var count = max(model.range.days ?? 0, 7)
        if model.range == .all, let first = model.allDays.first?.day {
            count = max(7, (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1)
        }
        return (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    private func amount(_ day: UsageDay?) -> Double {
        guard let day else { return 0 }
        return usesCost ? day.cost : Double(day.tokens)
    }

    private func label(_ amount: Double) -> String {
        usesCost ? (amount >= 10 || amount == 0 ? String(format: "$%.0f", amount) : dollars(amount)) : compact(Int(amount))
    }

    private var trend: some View {
        let dates = trendDates
        var lookup: [UsageAgent: [Date: UsageDay]] = [:]
        for day in model.allDays { lookup[day.agent, default: [:]][day.day] = day }
        let agents = UsageAgent.allCases
        func day(_ agent: UsageAgent, _ date: Date) -> UsageDay? { lookup[agent]?[date] }
        return panel {
            HStack(spacing: 16) {
                ForEach(agents, id: \.self) { agent in
                    HStack(spacing: 6) {
                        Circle().fill(agent.color).frame(width: 8, height: 8)
                        Text(agent.displayName).font(.system(size: 13))
                    }
                }
                Spacer()
                Text("悬停查看当日").font(.caption).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(agents, id: \.self) { agent in
                    ForEach(dates, id: \.self) { date in
                        AreaMark(x: .value("日期", date), y: .value("用量", amount(day(agent, date))),
                                 series: .value("Agent", agent.displayName), stacking: .unstacked)
                            .interpolationMethod(.monotone)
                            .foregroundStyle(agent.color.opacity(agent == .claudeCode ? 0.16 : 0.08))
                        LineMark(x: .value("日期", date), y: .value("用量", amount(day(agent, date))),
                                 series: .value("Agent", agent.displayName))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .foregroundStyle(agent.color)
                    }
                }
                if let hoveredDay {
                    RuleMark(x: .value("日期", hoveredDay))
                        .foregroundStyle(Color.primary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
                    ForEach(agents, id: \.self) { agent in
                        PointMark(x: .value("日期", hoveredDay), y: .value("用量", amount(day(agent, hoveredDay))))
                            .symbol {
                                Circle().fill(Color(nsColor: .controlBackgroundColor)).frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(agent.color, lineWidth: 2))
                            }
                    }
                }
            }
            .chartLegend(.hidden)
            // 首尾留出余量，让两端的日期标签完整落在图内。
            .chartXScale(domain: (dates.first ?? today)...(dates.last ?? today), range: .plotDimension(padding: 22))
            .chartXAxis {
                AxisMarks(values: stride(from: dates.count - 1, through: 0, by: -max(1, (dates.count + 2) / 4)).map { dates[$0] }) { _ in
                    // 标签居中对齐到当天的数据点，否则末尾一个会被挤出图外。
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), anchor: .top).foregroundStyle(Color.secondary)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.10))
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(label(amount)) } }
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let x = location.x - geometry[proxy.plotAreaFrame].origin.x
                                // 取离指针最近的一天。
                                hoveredDay = (proxy.value(atX: x) as Date?)
                                    .map { calendar.startOfDay(for: $0.addingTimeInterval(12 * 3600)) }
                                    .map { min(max($0, dates.first ?? $0), dates.last ?? $0) }
                            case .ended:
                                hoveredDay = nil
                            }
                        }
                    if let hoveredDay, let x = proxy.position(forX: hoveredDay) {
                        let width: CGFloat = 236
                        let plot = geometry[proxy.plotAreaFrame]
                        // 提示卡浮在图表上方、跟随所指日期，不遮住曲线；贴边时收回到图内。
                        tooltip(hoveredDay, rows: agents.map { ($0, day($0, hoveredDay)) })
                            .frame(width: width)
                            .offset(x: min(max(plot.origin.x + x - width / 2, 0), max(geometry.size.width - width, 0)), y: -84)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(minHeight: 212, maxHeight: .infinity)
        }
    }

    private func tooltip(_ date: Date, rows: [(agent: UsageAgent, day: UsageDay?)]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text(date.formatted(.dateTime.month().day().weekday(.abbreviated)))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading).gridColumnAlignment(.leading)
                Text("估算费用")
                Text("Token")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(rows, id: \.agent) { row in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(row.agent.color).frame(width: 7, height: 7)
                        Text(row.agent.displayName).font(.system(size: 12))
                    }
                    Text(dollars(row.day?.cost ?? 0)).font(.system(size: 12, weight: .semibold))
                    Text(compact(row.day?.tokens ?? 0)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    // MARK: 日历热力图

    private var heatmap: some View {
        let start = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let first = calendar.date(byAdding: .day, value: -28, to: start) ?? start
        let dates = (0..<35).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
        var totals: [Date: (cost: Double, tokens: Int)] = [:]
        for day in model.allDays {
            let current = totals[day.day] ?? (0, 0)
            totals[day.day] = (current.cost + day.cost, current.tokens + day.tokens)
        }
        func value(_ date: Date) -> Double { usesCost ? (totals[date]?.cost ?? 0) : Double(totals[date]?.tokens ?? 0) }
        let peak = max(dates.map(value).max() ?? 0, .leastNonzeroMagnitude)
        let recordedFrom = model.allDays.first?.day ?? today
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let weekdays = (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
        let shades = [0.06, 0.16, 0.32, 0.55, 0.85]

        return panel {
            HStack(alignment: .firstTextBaseline) {
                Text("\(first.formatted(.dateTime.month().day())) – \(today.formatted(.dateTime.month().day()))")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(usesCost ? "每日估算费用 · 点击看详情" : "每日 token · 点击看详情").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                ForEach(dates, id: \.self) { date in
                    let future = date > today
                    let unrecorded = date < recordedFrom
                    let amount = value(date)
                    let level = amount <= 0 ? 0 : min(4, 1 + Int(amount / peak * 3.999))
                    let number = calendar.component(.day, from: date)
                    ZStack {
                        if unrecorded {
                            Hatch().stroke(Color.primary.opacity(0.10), lineWidth: 1)
                                .background(Color.primary.opacity(0.03))
                        } else {
                            Color.primary.opacity(future ? 0.025 : shades[level])
                        }
                        Text(number == 1 || date == first ? date.formatted(.dateTime.month(.defaultDigits).day()) : "\(number)")
                            .font(.system(size: 11)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                            .foregroundStyle(level >= 3 ? Color(nsColor: .windowBackgroundColor)
                                             : Color.primary.opacity(future || unrecorded ? 0.25 : 0.9))
                    }
                    .frame(height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: date == today ? 2 : 0))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.7),
                                                                           lineWidth: date == selectedDay && date != today ? 2 : 0))
                    .contentShape(Rectangle())
                    .onTapGesture { if !future && !unrecorded { selectedDay = date } }
                    .popover(isPresented: Binding(get: { selectedDay == date },
                                                  set: { if !$0 && selectedDay == date { selectedDay = nil } }),
                             arrowEdge: .leading) {
                        dayDetail(date, range: recordedFrom...today)
                    }
                    .help(future ? date.formatted(date: .abbreviated, time: .omitted)
                          : unrecorded ? "\(date.formatted(date: .abbreviated, time: .omitted)) · 无记录"
                          : "\(date.formatted(date: .abbreviated, time: .omitted))\n估算 \(dollars(totals[date]?.cost ?? 0)) · \(exact(totals[date]?.tokens ?? 0)) token")
                }
            }
            HStack(spacing: 4) {
                Text("少")
                ForEach(shades, id: \.self) { shade in
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(shade)).frame(width: 9, height: 9)
                }
                Text("多")
                Spacer()
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 1.5).frame(width: 9, height: 9)
                Text("今天").padding(.trailing, 6)
                Hatch().stroke(Color.primary.opacity(0.3), lineWidth: 1).frame(width: 9, height: 9)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Text("无记录")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    /// 点击日历某天后弹出的当日详情。
    private func dayDetail(_ date: Date, range: ClosedRange<Date>) -> some View {
        let detail = model.detail(for: date)
        let previous = calendar.date(byAdding: .day, value: -1, to: date).flatMap { range.contains($0) ? $0 : nil }
        let next = calendar.date(byAdding: .day, value: 1, to: date).flatMap { range.contains($0) ? $0 : nil }
        let kinds: [(name: String, shade: Double, value: (TokenCounts) -> Int)] = [
            ("输入", 0.55, { $0.input }), ("缓存读取", 0.22, { $0.cacheRead }),
            ("缓存写入", 0.75, { $0.cacheWrite }), ("输出", 0.95, { $0.output })]
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(date.formatted(.dateTime.month().day().weekday(.wide))).font(.system(size: 17, weight: .bold))
                    Text("本机记录的用量").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { selectedDay = previous } label: { Image(systemName: "chevron.left") }
                    .disabled(previous == nil).help("前一天")
                Button { selectedDay = next } label: { Image(systemName: "chevron.right") }
                    .disabled(next == nil).help("后一天")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(dollars(detail.cost) + (detail.unpriced > 0 ? "+" : ""))
                    .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                Text("估算费用 · \(compact(detail.total.total)) token · \(detail.sessions) 个会话")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if detail.total.total == 0 {
                Text("这一天没有用量记录。").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("按 Agent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(ranked(detail.agents)) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 7) {
                                Circle().fill(row.agent.color).frame(width: 8, height: 8)
                                Text(row.name).font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(dollars(row.cost) + (row.unpriced > 0 ? "+" : "")).font(.system(size: 13, weight: .semibold))
                                Text("\(compact(row.counts.total)) token").font(.system(size: 11)).foregroundStyle(.secondary)
                            }.monospacedDigit()
                            // 四类 token 的构成，段间留 2pt 间隙。
                            GeometryReader { proxy in
                                let present = kinds.filter { $0.value(row.counts) > 0 }
                                let usable = proxy.size.width - CGFloat(max(present.count - 1, 0)) * 2
                                HStack(spacing: 2) {
                                    ForEach(present, id: \.name) { kind in
                                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(kind.shade))
                                            .frame(width: max(2, usable * CGFloat(kind.value(row.counts)) / CGFloat(max(row.counts.total, 1))))
                                    }
                                }
                            }.frame(height: 7).help(breakdown(row.counts))
                        }
                    }
                    HStack(spacing: 10) {
                        ForEach(kinds, id: \.name) { kind in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(kind.shade)).frame(width: 9, height: 9)
                                Text(kind.name)
                            }
                        }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("当日模型").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(ranked(detail.models).prefix(5)) { row in
                        HStack(spacing: 7) {
                            Circle().fill(row.agent.color).frame(width: 6, height: 6)
                            Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(row.unpriced == row.counts.total ? "价格未知" : dollars(row.cost)).font(.system(size: 12, weight: .medium))
                            Text(compact(row.counts.total)).font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }.monospacedDigit()
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("当日项目").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(ranked(detail.projects).prefix(5)) { row in
                        HStack(spacing: 7) {
                            Circle().fill(row.agent.color).frame(width: 6, height: 6)
                            Text(row.name.isEmpty ? "未记录目录" : (row.name as NSString).lastPathComponent)
                                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(row.name)
                            Spacer()
                            Text(row.unpriced == row.counts.total ? "价格未知" : dollars(row.cost)).font(.system(size: 12, weight: .medium))
                            Text(compact(row.counts.total)).font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }.monospacedDigit()
                    }
                }
            }
        }
        .padding(18).frame(width: 340)
    }

    // MARK: 列表

    private var programs: some View {
        let summary = model.summary
        // 两个 agent 始终都列出，没有用量时显示为零。
        return list(UsageAgent.allCases.map { agent in
            let row = summary.agents.first { $0.agent == agent }
            return Entry(id: agent.rawValue, title: agent.displayName,
                         subtitle: "\(row?.sessions ?? 0) 个会话 · \(breakdown(row?.counts ?? TokenCounts()))",
                         color: agent.color, cost: row?.cost ?? 0, tokens: row?.counts.total ?? 0,
                         unpriced: row?.unpriced ?? 0, help: "")
        }, limit: nil)
    }

    /// 列表按当前视图的主数值排序：费用视图按费用，Token 视图按 token。
    private func ranked(_ rows: [UsageRow]) -> [UsageRow] {
        usesCost ? rows.sorted { ($0.cost, $0.counts.total) > ($1.cost, $1.counts.total) } : rows
    }

    private func entries(for tab: Breakdown) -> [Entry] {
        let summary = model.summary
        func entry(_ row: UsageRow, title: String, subtitle: String) -> Entry {
            Entry(id: row.id, title: title, subtitle: subtitle, color: row.agent.color, cost: row.cost,
                  tokens: row.counts.total, unpriced: row.unpriced,
                  help: "\(row.sessions) 个会话\n\(breakdown(row.counts))")
        }
        switch tab {
        case .models:
            return ranked(summary.models).map { entry($0, title: $0.name, subtitle: $0.agent.displayName) }
        case .directories:
            return ranked(summary.projects).map {
                entry($0, title: $0.name.isEmpty ? "未记录目录" : ($0.name as NSString).lastPathComponent,
                      subtitle: $0.name.isEmpty ? $0.agent.displayName : "\($0.agent.displayName) · \($0.name)")
            }
        case .subagents:
            return ranked(summary.subagents).map {
                entry($0, title: $0.name.isEmpty ? "主会话" : $0.name,
                      subtitle: $0.name.isEmpty ? "Claude Code" : "Claude Code 子代理")
            }
        case .days:
            var days: [Date: Entry] = [:]
            for day in summary.days {
                var entry = days[day.day] ?? Entry(
                    id: "\(day.day.timeIntervalSince1970)",
                    title: day.day.formatted(.dateTime.month().day().weekday(.wide)), subtitle: "",
                    color: nil, cost: 0, tokens: 0, unpriced: 0, help: "")
                entry.cost += day.cost
                entry.tokens += day.tokens
                entry.subtitle += (entry.subtitle.isEmpty ? "" : " · ")
                    + "\(day.agent.displayName) \(usesCost ? dollars(day.cost) : compact(day.tokens))"
                days[day.day] = entry
            }
            return days.sorted { $0.key > $1.key }.map(\.value)
        }
    }

    private func list(_ entries: [Entry], limit: Int? = 6) -> some View {
        let wholeCost = max(model.summary.cost, 0)
        let wholeTokens = Double(model.summary.total.total)
        let shown = limit.map { expanded ? entries : Array(entries.prefix($0)) } ?? entries
        return panel(spacing: 0) {
            if entries.isEmpty {
                Text("这段时间没有用量记录。").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(shown) { entry in
                let unknown = entry.tokens > 0 && entry.unpriced == entry.tokens
                let spend = unknown ? "价格未知" : dollars(entry.cost) + (entry.unpriced > 0 ? "+" : "")
                HStack(alignment: .center, spacing: 12) {
                    Circle().fill(entry.color ?? Color.clear).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if !entry.subtitle.isEmpty {
                            Text(entry.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(usesCost ? spend : compact(entry.tokens))
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(usesCost ? "\(percent(entry.cost, of: wholeCost)) · \(compact(entry.tokens)) token"
                                      : "\(percent(Double(entry.tokens), of: wholeTokens)) · \(spend)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .help(entry.help)
                if entry.id != shown.last?.id || shown.count < entries.count { Divider().padding(.leading, 20) }
            }
            if let limit, entries.count > limit {
                Button { expanded.toggle() } label: {
                    HStack {
                        Text(expanded ? "收起" : "显示全部 \(entries.count) 项")
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.right").font(.caption)
                    }.padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 13))
            }
        }
    }

    // MARK: 页脚

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { Task { await model.updatePrices() } } label: {
                    Label("更新价格表", systemImage: "arrow.down.circle")
                }
                .disabled(model.updatingPrices)
                .help("点击后才联网：从 GitHub 下载 LiteLLM 项目公开维护的价格文件，不带任何登录凭据。\n\(TokenUsageModel.priceSource.absoluteString)")
                if model.updatingPrices { ProgressView().controlSize(.small) }
                Text(model.pricesFetched.map { "价格表：联网更新于 \($0.formatted(date: .numeric, time: .shortened))" }
                     ?? "价格表：内置（\(PriceTable.builtInDate) 核对）")
                if !model.priceNotice.isEmpty { Text(model.priceNotice) }
                Spacer()
                Button(role: .destructive) { confirmingClear = true } label: {
                    Label("清空用量缓存", systemImage: "trash")
                }
                .disabled(model.loading)
                .help("已统计的用量缓存在本机，之后只读日志里新增的部分。清空后从现存日志重新统计。")
                .confirmationDialog("清空用量缓存？", isPresented: $confirmingClear) {
                    Button("清空并重新统计", role: .destructive) { Task { await model.clearCache() } }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("会从本机现存的会话日志重新统计。日志已被 agent 清理的旧用量只存在缓存里，清空后无法恢复。")
                }
            }
            Text("估算费用按公开 API 标准价由本机记录的 token 用量折算，不是订阅账单，也不含长上下文加价；带「+」表示还有价格未知的模型未计入。")
            Text("用量只来自本机 ~/.claude 与 ~/.codex 的会话日志：只读解析，不请求任何官方接口、不读取对话内容；只有点击「更新价格表」时才联网。"
                 + (model.allDays.first.map { "本机记录始于 \($0.day.formatted(date: .abbreviated, time: .omitted))，" } ?? "")
                 + "日期按 \(calendar.timeZone.identifier) 划分。")
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }

    // MARK: 容器

    private func section(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text("· \(detail)").font(.system(size: 15)).foregroundStyle(.secondary)
        }.padding(.horizontal, 4).padding(.top, 6)
    }

    private func panel<Content: View>(spacing: CGFloat = 14, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }
}

/// 斜线填充，标记日历里还没有记录的日子。
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var offset = -rect.height
        while offset < rect.width {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += 4
        }
        return path
    }
}
