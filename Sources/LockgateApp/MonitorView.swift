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

private enum MonitorTab: String, CaseIterable {
    case live = "实时连接"
    case log = "连接日志"
}

private enum LiveSort {
    case host, downloadSpeed, uploadSpeed, download, upload, start
}

private enum LogSort {
    case host, download, upload, duration, closed
}

private enum Column {
    static let speed: CGFloat = 82
    static let amount: CGFloat = 74
    static let time: CGFloat = 70
    static let action: CGFloat = 18
}

/// 可点击的列标题：点一下按该列从大到小排，再点一下反向。
private struct SortHeader<Key: Equatable>: View {
    let title: String
    let key: Key
    @Binding var current: Key
    @Binding var ascending: Bool
    var width: CGFloat?
    var textual = false

    var body: some View {
        let active = current == key
        Button {
            if active { ascending.toggle() } else {
                current = key
                ascending = textual
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if active { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .font(.system(size: 11, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: width == nil ? .leading : .trailing)
            .frame(width: width, alignment: .trailing)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("按「\(title)」排序")
    }
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

/// 「实时监控」页：总速率、各出口的占用，以及实时连接和连接日志两个列表。
struct MonitorPage: View {
    @ObservedObject var monitor: TrafficMonitor
    let running: Bool
    @State private var tab = MonitorTab.live
    @State private var filter = MonitorFilter.all
    @State private var search = ""
    @State private var liveSort = LiveSort.downloadSpeed
    @State private var liveAscending = false
    @State private var logSort = LogSort.closed
    @State private var logAscending = false
    private static let rowLimit = 300

    private func matches(_ record: ConnectionRecord) -> Bool {
        if let route = filter.route, record.route != route { return false }
        let keyword = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !keyword.isEmpty else { return true }
        return [record.host, record.process, record.chainText, record.ruleText].contains { $0.lowercased().contains(keyword) }
    }

    /// 先按所选列排，数值相同时按累计流量，再按 ID，保证每秒刷新时顺序稳定。
    private var liveRows: [ConnectionRow] {
        func value(_ row: ConnectionRow) -> Double {
            switch liveSort {
            case .host: return 0
            case .downloadSpeed: return row.downloadSpeed
            case .uploadSpeed: return row.uploadSpeed
            case .download: return Double(row.record.download)
            case .upload: return Double(row.record.upload)
            case .start: return row.record.start?.timeIntervalSince1970 ?? 0
            }
        }
        let sorted = monitor.rows.filter { matches($0.record) }.sorted { left, right in
            if liveSort == .host, left.record.host != right.record.host {
                return left.record.host.localizedStandardCompare(right.record.host) == .orderedAscending
            }
            let (a, b) = (value(left), value(right))
            if a != b { return a < b }
            let (c, d) = (left.record.download + left.record.upload, right.record.download + right.record.upload)
            return c != d ? c < d : left.id < right.id
        }
        return liveAscending ? sorted : sorted.reversed()
    }

    private var logRows: [ClosedConnection] {
        func value(_ item: ClosedConnection) -> Double {
            switch logSort {
            case .host: return 0
            case .download: return Double(item.record.download)
            case .upload: return Double(item.record.upload)
            case .duration: return item.duration ?? 0
            case .closed: return item.closedAt.timeIntervalSince1970
            }
        }
        let sorted = monitor.closed.filter { matches($0.record) }.sorted { left, right in
            if logSort == .host, left.record.host != right.record.host {
                return left.record.host.localizedStandardCompare(right.record.host) == .orderedAscending
            }
            let (a, b) = (value(left), value(right))
            if a != b { return a < b }
            let (c, d) = (left.record.start ?? .distantPast, right.record.start ?? .distantPast)
            return c != d ? c < d : left.id < right.id
        }
        return logAscending ? sorted : sorted.reversed()
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
        ProxyCard(title: "连接", icon: "list.bullet.indent") {
            HStack {
                Picker("", selection: $tab) {
                    Text("实时连接 \(monitor.rows.count)").tag(MonitorTab.live)
                    Text("连接日志 \(monitor.closed.count)").tag(MonitorTab.log)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
                Spacer()
                if tab == .live {
                    Button("断开全部") { monitor.closeAll() }.disabled(monitor.rows.isEmpty)
                } else {
                    Button("清空日志") { monitor.clearLog() }.disabled(monitor.closed.isEmpty)
                }
            }
            HStack {
                Picker("", selection: $filter) {
                    ForEach(MonitorFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                TextField("搜索域名、进程、节点或规则", text: $search).textFieldStyle(.roundedBorder)
            }
            if tab == .live { liveList } else { logList }
        }
    }

    @ViewBuilder private var liveList: some View {
        let rows = liveRows
        HStack(spacing: 8) {
            SortHeader(title: "目标", key: LiveSort.host, current: $liveSort, ascending: $liveAscending, textual: true)
            SortHeader(title: "下载速率", key: LiveSort.downloadSpeed, current: $liveSort, ascending: $liveAscending, width: Column.speed)
            SortHeader(title: "上传速率", key: LiveSort.uploadSpeed, current: $liveSort, ascending: $liveAscending, width: Column.speed)
            SortHeader(title: "已下载", key: LiveSort.download, current: $liveSort, ascending: $liveAscending, width: Column.amount)
            SortHeader(title: "已上传", key: LiveSort.upload, current: $liveSort, ascending: $liveAscending, width: Column.amount)
            SortHeader(title: "开始时间", key: LiveSort.start, current: $liveSort, ascending: $liveAscending, width: Column.time)
            Color.clear.frame(width: Column.action, height: 1)
        }.padding(.top, 4)
        Divider()
        if rows.isEmpty {
            Text(monitor.rows.isEmpty ? "当前没有活动连接。" : "没有符合条件的连接。").font(.caption).foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows.prefix(Self.rowLimit)) { row in
                LiveRowView(row: row) { monitor.close(row.id) }
                Divider()
            }
        }
        if rows.count > Self.rowLimit {
            Text("仅显示前 \(Self.rowLimit) 条，共 \(rows.count) 条。可用搜索或筛选缩小范围。").font(.caption).foregroundStyle(.secondary)
        }
        Text("这里只有仍然打开的连接。点列标题排序，再点一次反向；默认按下载速率从大到小。")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var logList: some View {
        let rows = logRows
        HStack(spacing: 8) {
            SortHeader(title: "目标", key: LogSort.host, current: $logSort, ascending: $logAscending, textual: true)
            SortHeader(title: "下载", key: LogSort.download, current: $logSort, ascending: $logAscending, width: Column.amount)
            SortHeader(title: "上传", key: LogSort.upload, current: $logSort, ascending: $logAscending, width: Column.amount)
            SortHeader(title: "持续", key: LogSort.duration, current: $logSort, ascending: $logAscending, width: Column.time)
            SortHeader(title: "结束时间", key: LogSort.closed, current: $logSort, ascending: $logAscending, width: Column.time)
        }.padding(.top, 4)
        Divider()
        if rows.isEmpty {
            Text(monitor.closed.isEmpty ? "还没有已结束的连接。" : "没有符合条件的记录。").font(.caption).foregroundStyle(.secondary)
        }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows.prefix(Self.rowLimit)) { item in
                LogRowView(item: item)
                Divider()
            }
        }
        if rows.count > Self.rowLimit {
            Text("仅显示前 \(Self.rowLimit) 条，共 \(rows.count) 条。可用搜索或筛选缩小范围。").font(.caption).foregroundStyle(.secondary)
        }
        Text("已经结束的连接，自代理本次启动起记录，最多保留 \(TrafficMonitor.logLimit) 条，只在内存中、不写入磁盘。每秒采样一次，不到一秒就结束的连接可能记不到。")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private func connectionDetail(_ record: ConnectionRecord) -> String {
    var parts = [record.process.isEmpty ? "未知进程" : record.process]
    if !record.inboundTitle.isEmpty { parts.append("经 \(record.inboundTitle)") }
    if !record.ruleText.isEmpty { parts.append("规则 \(record.ruleText)") }
    return parts.joined(separator: " · ")
}

private let clockFormat: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

private func durationText(_ seconds: TimeInterval?) -> String {
    guard let seconds else { return "—" }
    if seconds < 60 { return String(format: "%.0f 秒", seconds) }
    if seconds < 3600 { return String(format: "%d 分 %02d 秒", Int(seconds) / 60, Int(seconds) % 60) }
    return String(format: "%d 时 %02d 分", Int(seconds) / 3600, Int(seconds) % 3600 / 60)
}

/// 目标、来源进程、规则和出口，两种列表共用。
private struct ConnectionSummary: View {
    let record: ConnectionRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RouteTag(route: record.route).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.destination).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text(record.network.uppercased()).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(connectionDetail(record)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(record.processPath.isEmpty ? connectionDetail(record) : record.processPath)
                Text("出口：\(record.chainText.isEmpty ? "未知" : record.chainText)")
                    .font(.caption).foregroundStyle(routeColor(record.route)).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func numberCell(_ text: String, width: CGFloat, dim: Bool = false) -> some View {
    Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(dim ? Color.secondary : Color.primary)
        .lineLimit(1).minimumScaleFactor(0.8).frame(width: width, alignment: .trailing)
}

private struct LiveRowView: View {
    let row: ConnectionRow
    let close: () -> Void

    var body: some View {
        let record = row.record
        HStack(alignment: .center, spacing: 8) {
            ConnectionSummary(record: record)
            numberCell(ConnectionParser.speed(row.downloadSpeed), width: Column.speed, dim: row.downloadSpeed == 0)
            numberCell(ConnectionParser.speed(row.uploadSpeed), width: Column.speed, dim: row.uploadSpeed == 0)
            numberCell(SubscriptionUsage.format(record.download), width: Column.amount)
            numberCell(SubscriptionUsage.format(record.upload), width: Column.amount)
            numberCell(record.start.map(clockFormat.string(from:)) ?? "—", width: Column.time, dim: true)
            Button(action: close) { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("断开这条连接").frame(width: Column.action)
        }.padding(.vertical, 7)
    }
}

private struct LogRowView: View {
    let item: ClosedConnection

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ConnectionSummary(record: item.record)
            numberCell(SubscriptionUsage.format(item.record.download), width: Column.amount)
            numberCell(SubscriptionUsage.format(item.record.upload), width: Column.amount)
            numberCell(durationText(item.duration), width: Column.time, dim: true)
            numberCell(clockFormat.string(from: item.closedAt), width: Column.time, dim: true)
        }.padding(.vertical, 7)
    }
}
