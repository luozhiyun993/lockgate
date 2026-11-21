import Foundation
import LockgateCore

struct ConnectionRow: Identifiable, Equatable {
    var id: String { record.id }
    let record: ConnectionRecord
    let uploadSpeed: Double
    let downloadSpeed: Double

    var speed: Double { uploadSpeed + downloadSpeed }
}

/// 已经结束的连接：最后一次看到它时的状态，加上发现它消失的时间。
struct ClosedConnection: Identifiable, Equatable {
    var id: String { record.id }
    let record: ConnectionRecord
    let closedAt: Date

    var duration: TimeInterval? { record.start.map { max(0, closedAt.timeIntervalSince($0)) } }
}

struct TrafficSample: Equatable {
    let upload: Double
    let download: Double
}

/// 每秒读取一次内核的连接列表，算出总速率、每条连接的速率和各出口的占用，并把消失的连接记入日志。
/// 内核运行期间持续轮询，这样不打开「实时监控」页时结束的连接也会进日志；数据只在内存中，不落盘。
@MainActor
final class TrafficMonitor: ObservableObject {
    @Published private(set) var rows: [ConnectionRow] = []
    /// 连接日志，最新结束的在前，最多保留 `logLimit` 条。
    @Published private(set) var closed: [ClosedConnection] = []
    @Published private(set) var usage: [OutboundUsage] = []
    @Published private(set) var uploadSpeed: Double = 0
    @Published private(set) var downloadSpeed: Double = 0
    @Published private(set) var uploadTotal: Int64 = 0
    @Published private(set) var downloadTotal: Int64 = 0
    @Published private(set) var history: [TrafficSample] = []
    @Published private(set) var updated: Date?

    static let historyLength = 60
    static let logLimit = 1000
    private var api: MihomoAPI?
    private var task: Task<Void, Never>?
    private var previous: [String: ConnectionRecord] = [:]
    private var previousTotals: (upload: Int64, download: Int64, time: Date)?

    func count(_ route: ConnectionRoute) -> Int {
        rows.reduce(0) { $0 + ($1.record.route == route ? 1 : 0) }
    }

    func attach(_ api: MihomoAPI?) {
        self.api = api
        reset()
        restart()
    }

    func clearLog() { closed = [] }

    private func reset() {
        rows = []
        closed = []
        usage = []
        uploadSpeed = 0
        downloadSpeed = 0
        uploadTotal = 0
        downloadTotal = 0
        history = []
        updated = nil
        previous = [:]
        previousTotals = nil
    }

    private func restart() {
        task?.cancel()
        task = nil
        guard let api else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let snapshot = try? await api.connections(), !Task.isCancelled { self?.apply(snapshot) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func apply(_ snapshot: ConnectionSnapshot) {
        let now = Date()
        let interval = previousTotals.map { max(0.2, now.timeIntervalSince($0.time)) } ?? 0
        if let last = previousTotals, interval > 0 {
            // 内核重载配置后累计值会归零，出现负数时按 0 处理。
            uploadSpeed = Double(max(0, snapshot.uploadTotal - last.upload)) / interval
            downloadSpeed = Double(max(0, snapshot.downloadTotal - last.download)) / interval
            history = Array((history + [TrafficSample(upload: uploadSpeed, download: downloadSpeed)]).suffix(Self.historyLength))
        }
        rows = snapshot.connections.map { record in
            guard interval > 0, let old = previous[record.id] else {
                return ConnectionRow(record: record, uploadSpeed: 0, downloadSpeed: 0)
            }
            return ConnectionRow(record: record,
                                 uploadSpeed: Double(max(0, record.upload - old.upload)) / interval,
                                 downloadSpeed: Double(max(0, record.download - old.download)) / interval)
        }
        let alive = Set(snapshot.connections.map(\.id))
        let ended = previous.values.filter { !alive.contains($0.id) }
            .sorted { ($0.start ?? .distantPast, $0.id) > ($1.start ?? .distantPast, $1.id) }
            .map { ClosedConnection(record: $0, closedAt: now) }
        if !ended.isEmpty { closed = Array((ended + closed).prefix(Self.logLimit)) }
        usage = ConnectionParser.usage(snapshot.connections)
        uploadTotal = snapshot.uploadTotal
        downloadTotal = snapshot.downloadTotal
        previous = Dictionary(snapshot.connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        previousTotals = (snapshot.uploadTotal, snapshot.downloadTotal, now)
        updated = now
    }

    func close(_ id: String) {
        guard let api else { return }
        Task { await api.closeConnection(id) }
    }

    func closeAll() {
        guard let api else { return }
        Task { await api.closeConnections() }
    }
}
