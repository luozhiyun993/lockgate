import Foundation
import LockgateCore

struct ConnectionRow: Identifiable, Equatable {
    var id: String { record.id }
    let record: ConnectionRecord
    let uploadSpeed: Double
    let downloadSpeed: Double

    var speed: Double { uploadSpeed + downloadSpeed }
}

struct TrafficSample: Equatable {
    let upload: Double
    let download: Double
}

/// 每秒读取一次内核的连接列表，算出总速率、每条连接的速率和各出口的占用。
/// 只在「实时监控」页可见时轮询；数据只在内存中，不落盘。
@MainActor
final class TrafficMonitor: ObservableObject {
    @Published private(set) var rows: [ConnectionRow] = []
    @Published private(set) var usage: [OutboundUsage] = []
    @Published private(set) var uploadSpeed: Double = 0
    @Published private(set) var downloadSpeed: Double = 0
    @Published private(set) var uploadTotal: Int64 = 0
    @Published private(set) var downloadTotal: Int64 = 0
    @Published private(set) var history: [TrafficSample] = []
    @Published private(set) var updated: Date?

    static let historyLength = 60
    private var api: MihomoAPI?
    private var task: Task<Void, Never>?
    private var visible = false
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

    func setVisible(_ visible: Bool) {
        self.visible = visible
        restart()
    }

    private func reset() {
        rows = []
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
        guard visible, let api else { return }
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
