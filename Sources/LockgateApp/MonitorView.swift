import SwiftUI
import LockgateCore

private enum MonitorFilter: String, CaseIterable {
    case all = "全部"
    case proxied = "代理"
    case direct = "直连"
    case rejected = "拒绝"

    var route: ConnectionRoute? {
        switch self {
        case .all: return nil
        case .proxied: return .proxied
        case .direct: return .direct
        case .rejected: return .rejected
        }
    }
}

private enum MonitorSort: String, CaseIterable {
    case speed = "按速率"
    case traffic = "按流量"
    case recent = "按时间"
}

private func routeColor(_ route: ConnectionRoute) -> Color {
    switch route {
    case .proxied: return .green
    case .direct: return .orange
    case .rejected: return .red
    }
}

private struct RouteTag: View {
    let route: ConnectionRoute

    var body: some View {
        Text(route.title).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(routeColor(route).opacity(0.14), in: Capsule()).foregroundStyle(routeColor(route))
    }
}

/// 最近一分钟的上下行速率曲线。
private struct TrafficChart: View {
    let history: [TrafficSample]

    private func path(_ values: [Double], in size: CGSize, peak: Double) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let step = size.width / CGFloat(TrafficMonitor.historyLength - 1)
        let offset = CGFloat(TrafficMonitor.historyLength - values.count) * step
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: offset + CGFloat(index) * step, y: size.height - CGFloat(value / peak) * size.height)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    var body: some View {
        GeometryReader { geometry in
            let peak = max(1024, history.map { max($0.upload, $0.download) }.max() ?? 0)
            ZStack {
                path(history.map(\.download), in: geometry.size, peak: peak).stroke(Color.green, lineWidth: 1.5)
                path(history.map(\.upload), in: geometry.size, peak: peak).stroke(Color.blue, lineWidth: 1.5)
            }
        }.frame(height: 56)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 「实时监控」页：总速率、各出口的占用，以及每条连接的来源、规则和出口。
struct MonitorPage: View {
    @ObservedObject var monitor: TrafficMonitor
    let running: Bool
    @State private var filter = MonitorFilter.all
    @State private var sort = MonitorSort.speed
    @State private var search = ""
    private static let rowLimit = 300

    private var filtered: [ConnectionRow] {
        let keyword = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = monitor.rows.filter { row in
            if let route = filter.route, row.record.route != route { return false }
            guard !keyword.isEmpty else { return true }
            let record = row.record
            return [record.host, record.process, record.chainText, record.ruleText]
                .contains { $0.lowercased().contains(keyword) }
        }
        switch sort {
        case .speed:
            return rows.sorted { ($0.speed, $0.record.download + $0.record.upload, $0.id) > ($1.speed, $1.record.download + $1.record.upload, $1.id) }
        case .traffic:
            return rows.sorted { ($0.record.download + $0.record.upload, $0.id) > ($1.record.download + $1.record.upload, $1.id) }
        case .recent:
            return rows.sorted { ($0.record.start ?? .distantPast, $0.id) > ($1.record.start ?? .distantPast, $1.id) }
        }
    }

    var body: some View {
        Group {
            if !running {
                ProxyCard(title: "实时监控", icon: "waveform.path.ecg") {
                    Text("内置代理没有运行。").font(.system(size: 14, weight: .medium))
                    Text("监控数据来自 Lockgate 内置的 mihomo 内核。使用其他代理软件时，这里看不到它们的流量。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                summary
                outbounds
                connections
            }
        }
        .onAppear { monitor.setVisible(true) }
        .onDisappear { monitor.setVisible(false) }
    }

    private func figure(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .medium, design: .monospaced)).foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        ProxyCard(title: "流量概览", icon: "speedometer") {
            HStack(alignment: .top) {
                figure("下载", ConnectionParser.speed(monitor.downloadSpeed), color: .green)
                figure("上传", ConnectionParser.speed(monitor.uploadSpeed), color: .blue)
                figure("本次累计", "↓ \(SubscriptionUsage.format(monitor.downloadTotal))  ↑ \(SubscriptionUsage.format(monitor.uploadTotal))")
            }
            TrafficChart(history: monitor.history)
            HStack(spacing: 14) {
                Text("当前连接 \(monitor.rows.count)").font(.caption)
                ForEach(ConnectionRoute.allCases, id: \.self) { route in
                    HStack(spacing: 5) {
                        Circle().fill(routeColor(route)).frame(width: 6, height: 6)
                        Text("\(route.title) \(monitor.count(route))").font(.caption)
                    }
                }
                Spacer()
                Text("仅统计经过内置代理的流量 · 每秒刷新").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var outbounds: some View {
        ProxyCard(title: "流量从哪里出去", icon: "arrow.up.right.circle") {
            if monitor.usage.isEmpty {
                Text("当前没有活动连接。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(monitor.usage) { item in
                HStack(spacing: 10) {
                    RouteTag(route: item.route)
                    Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("\(item.connections) 条连接").font(.caption).foregroundStyle(.secondary)
                    Text("↓ \(SubscriptionUsage.format(item.download))  ↑ \(SubscriptionUsage.format(item.upload))")
                        .font(.system(size: 11, design: .monospaced)).frame(width: 190, alignment: .trailing)
                }
                if item.id != monitor.usage.last?.id { Divider() }
            }
            Text("「代理」表示流量经该节点转发；「直连」表示没有经过代理，直接从本机网络出去；「拒绝」表示被规则拦下。数字是当前仍打开的连接的累计流量。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connections: some View {
        let rows = filtered
        return ProxyCard(title: "连接", icon: "list.bullet.indent") {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(MonitorFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Picker("", selection: $sort) {
                    ForEach(MonitorSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 100)
                TextField("搜索域名、进程、节点或规则", text: $search).textFieldStyle(.roundedBorder)
                Button("断开全部") { monitor.closeAll() }.disabled(monitor.rows.isEmpty)
            }
            if rows.isEmpty {
                Text(monitor.rows.isEmpty ? "当前没有活动连接。" : "没有符合条件的连接。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.prefix(Self.rowLimit)) { row in
                    ConnectionRowView(row: row) { monitor.close(row.id) }
                    Divider()
                }
            }
            if rows.count > Self.rowLimit {
                Text("仅显示前 \(Self.rowLimit) 条，共 \(rows.count) 条。可用搜索或筛选缩小范围。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ConnectionRowView: View {
    let row: ConnectionRow
    let close: () -> Void

    var body: some View {
        let record = row.record
        HStack(alignment: .top, spacing: 10) {
            RouteTag(route: record.route).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.destination).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text(record.network.uppercased()).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(detail(record)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(record.processPath.isEmpty ? detail(record) : record.processPath)
                Text("出口：\(record.chainText.isEmpty ? "未知" : record.chainText)")
                    .font(.caption).foregroundStyle(routeColor(record.route)).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text("↓ \(ConnectionParser.speed(row.downloadSpeed))  ↑ \(ConnectionParser.speed(row.uploadSpeed))")
                    .font(.system(size: 11, design: .monospaced))
                Text("↓ \(SubscriptionUsage.format(record.download))  ↑ \(SubscriptionUsage.format(record.upload))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Button(action: close) { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("断开这条连接")
        }.padding(.vertical, 7)
    }

    private func detail(_ record: ConnectionRecord) -> String {
        var parts = [record.process.isEmpty ? "未知进程" : record.process]
        if !record.inboundTitle.isEmpty { parts.append("经 \(record.inboundTitle)") }
        if !record.ruleText.isEmpty { parts.append("规则 \(record.ruleText)") }
        if let start = record.start { parts.append(start.formatted(date: .omitted, time: .standard)) }
        return parts.joined(separator: " · ")
    }
}
