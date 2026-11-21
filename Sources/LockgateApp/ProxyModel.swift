import AppKit
import Darwin
import Foundation
import LockgateCore

enum GateStatus: Equatable {
    case off
    case unavailable(String)
    case blocking
    case allowing

    var summary: String {
        switch self {
        case .off: return "内核阻断未开启"
        case .unavailable(let reason): return "内核阻断未就绪 · \(reason)"
        case .blocking: return "内核阻断已生效 · 正在拒绝访问受保护地址的连接"
        case .allowing: return "内核阻断已就绪 · 当前放行受保护地址"
        }
    }
}

/// 内置代理：管理 mihomo 内核进程、订阅、节点选择、系统代理与 TUN。
@MainActor
final class ProxyModel: ObservableObject {
    @Published private(set) var settings: ProxySettings
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var core: CoreBinary?
    @Published private(set) var bundledVersion: String?
    @Published private(set) var snapshot = ProxySnapshot()
    @Published private(set) var logs: [String] = []
    @Published var error: String?
    @Published private(set) var systemProxyApplied = false
    @Published private(set) var tunAuthorized = false
    @Published private(set) var adding = false
    @Published private(set) var updating: Set<UUID> = []
    @Published private(set) var testing: Set<String> = []
    @Published private(set) var latest: CoreAsset?
    @Published private(set) var coreBusy = false
    @Published private(set) var coreMessage: String?
    var onEvent: (String) -> Void = { _ in }
    let monitor = TrafficMonitor()
    @Published private(set) var gateStatus = GateStatus.off
    @Published private(set) var overrideLogs: [String] = []
    @Published private(set) var tunInterface: String?
    @Published private(set) var geoFiles: [GeoFile] = []
    @Published private(set) var geoUpdating = false
    @Published private(set) var geoMessage: String?
    @Published private(set) var tunInterfaceMissing = false
    @Published private(set) var overrideMessage: String?
    private var gateAddresses: [String]?
    private var gateSyncing = false

    private let store = ProxyStore()
    private var process: Process?
    private var api: MihomoAPI?
    private var runtime: CoreRuntime?
    private var generation = 0
    private var autoUpdateTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    /// 本次运行期间用户手动停止过内核。只影响这一次，下次打开应用内核照常启动。
    @Published private(set) var stoppedByUser = false
    /// 本地文件上一次看到的修改时间和大小；连续两次相同才认为写入已完成。
    private var fileSignatures: [UUID: String] = [:]
    private var pendingSignatures: [UUID: String] = [:]

    init() {
        do {
            settings = try store.load()
        } catch {
            settings = ProxySettings()
            self.error = "无法读取代理设置：\(error.localizedDescription)"
        }
        if !settings.coreFollowsApp {
            settings.migrateToCoreFollowsApp()
            save()
        }
        systemProxyApplied = MihomoCore.systemProxyPointsToCore(port: settings.mixedPort)
        Task {
            await loadCoreInfo()
            // 内核随应用启动；系统代理和 TUN 按各自开关的状态接管。
            if settings.active != nil { await start(interactive: false) }
        }
        autoUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            while !Task.isCancelled {
                await self?.updateStaleSubscriptions()
                try? await Task.sleep(nanoseconds: 900_000_000_000)
            }
        }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkLocalFiles()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: 本地文件监视

    func setWatchLocalFiles(_ enabled: Bool) {
        settings.watchLocalFiles = enabled
        save()
        fileSignatures = [:]
        pendingSignatures = [:]
    }

    /// 每 1.5 秒看一眼已导入的本地文件；修改时间或大小变了、并且内容确实与已保存的不同，就自动重新导入。
    private func checkLocalFiles() async {
        guard settings.watchLocalFiles else { return }
        for subscription in settings.subscriptions {
            guard let path = subscription.localPath, !updating.contains(subscription.id),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            let signature = "\(modified.timeIntervalSince1970)-\((attributes[.size] as? NSNumber)?.int64Value ?? 0)"
            guard fileSignatures[subscription.id] != signature else { continue }
            // 编辑器可能还在写入：等下一轮签名不再变化时再读取。
            guard pendingSignatures[subscription.id] == signature else {
                pendingSignatures[subscription.id] = signature
                continue
            }
            pendingSignatures[subscription.id] = nil
            fileSignatures[subscription.id] = signature
            let id = subscription.id
            let stored = store.profileURL(id)
            let changed = await Task.detached {
                guard let current = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
                return current != (try? Data(contentsOf: stored))
            }.value
            if changed {
                onEvent("检测到本地配置「\(subscription.name)」的文件有改动，自动重新导入。")
                await updateSubscription(id, silent: true)
            }
        }
    }

    var statusSummary: String {
        if busy { return "正在切换…" }
        guard running else { return "代理未运行" }
        var parts = ["代理运行中"]
        if settings.tun { parts.append(tunInterface.map { "TUN（\($0)）" } ?? "TUN") }
        if systemProxyApplied { parts.append("系统代理") }
        return parts.joined(separator: " · ")
    }

    private func save() {
        do { try store.save(settings) } catch { self.error = "无法保存代理设置：\(error.localizedDescription)" }
    }

    private func loadCoreInfo() async {
        let info = await Task.detached {
            (MihomoCore.activeCore(), MihomoCore.bundledCore?.version, MihomoCore.privilegedInstalled)
        }.value
        core = info.0
        bundledVersion = info.1
        tunAuthorized = info.2
    }

    // MARK: 启停

    func start(interactive: Bool = true) async {
        guard !busy, !running else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await launch(interactive: interactive)
            settings.coreEnabled = true
            stoppedByUser = false
            save()
        } catch {
            self.error = error.localizedDescription
            onEvent("代理内核启动失败：\(error.localizedDescription)")
        }
    }

    func stop() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await halt(restoreSystemProxy: true)
        settings.coreEnabled = false
        stoppedByUser = true
        save()
        onEvent("用户停止了内置代理。")
    }

    /// 退出应用时调用：停止内核并恢复系统代理。下次打开应用时内核会再次启动。
    func shutdown() async {
        autoUpdateTask?.cancel()
        watchTask?.cancel()
        await halt(restoreSystemProxy: true)
    }

    private func restart(interactive: Bool) async throws {
        await halt(restoreSystemProxy: false)
        try await launch(interactive: interactive)
    }

    private func writeConfig(_ subscription: Subscription, runtime: CoreRuntime, home: URL,
                             fileName: String = "config.yaml") async throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        MihomoCore.seedGeoData(into: home)
        let source = try Data(contentsOf: store.profileURL(subscription.id))
        let providerPath = "./providers/subscription.txt"
        if subscription.kind == .provider {
            let providers = home.appendingPathComponent("providers")
            try files.createDirectory(at: providers, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ProxyStore.writePrivate(source, to: providers.appendingPathComponent("subscription.txt"))
        }
        let steps = settings.overrides.filter(\.enabled).map {
            OverrideStep(name: $0.name, kind: $0.kind, content: store.loadOverride($0))
        }
        let config: String
        if !steps.isEmpty {
            let output = try await OverrideRunner.run(OverrideRequest(
                profile: String(decoding: source, as: UTF8.self), kind: subscription.kind,
                providerPath: providerPath, steps: steps, runtime: runtime))
            overrideLogs = output.logs
            config = output.config
        } else if subscription.kind == .provider {
            overrideLogs = []
            config = ProfileComposer.compose(providerPath: providerPath, runtime: runtime)
        } else {
            overrideLogs = []
            config = try ProfileComposer.compose(profile: String(decoding: source, as: UTF8.self), runtime: runtime)
        }
        let url = home.appendingPathComponent(fileName)
        try ProxyStore.writePrivate(Data(config.utf8), to: url)
        return url
    }

    /// 用不带特权的内核执行 `mihomo -t`，在真正启动或重载前发现配置错误。
    private func validate(_ config: URL, home: URL, core: CoreBinary) async throws {
        let result = await Task.detached {
            MihomoCore.run(core.url, ["-t", "-d", home.path, "-f", config.path], timeout: 90)
        }.value
        guard result.status == 0 else {
            let lines = result.output.split(separator: "\n").suffix(3).map { Self.compact(String($0)) }
            throw CoreError("订阅配置未通过内核校验：\(lines.joined(separator: "；"))")
        }
    }

    private func launch(interactive: Bool) async throws {
        guard let subscription = settings.active else { throw CoreError("请先在「订阅」中添加并选择一个订阅。") }
        guard FileManager.default.fileExists(atPath: store.profileURL(subscription.id).path) else {
            throw CoreError("订阅「\(subscription.name)」的内容缺失，请先更新订阅。")
        }
        guard let core = await Task.detached(operation: { MihomoCore.activeCore() }).value else {
            throw CoreError("未找到 mihomo 内核。请在「内核版本」中下载。")
        }
        self.core = core
        let tun = settings.tun
        var executable = core.url
        if tun {
            if !(await Task.detached(operation: { MihomoCore.privilegedReady(matching: core) }).value) {
                guard interactive else {
                    throw CoreError("TUN 模式的内核需要重新授权。请在「代理」页重新打开 TUN 模式。")
                }
                try await Task.detached { try MihomoCore.installPrivileged(from: core) }.value
                onEvent("已授权安装 TUN 模式内核（\(core.version)）。")
            }
            tunAuthorized = true
            executable = MihomoCore.privilegedCore
        }
        await Task.detached { MihomoCore.terminateOrphan() }.value
        guard MihomoCore.isPortFree(settings.mixedPort) else {
            throw CoreError("代理端口 \(settings.mixedPort) 已被其他程序占用。请在「代理」页换一个端口，或退出占用它的代理软件。")
        }
        guard let controllerPort = MihomoCore.freePort() else { throw CoreError("无法分配内核控制端口。") }
        let runtime = CoreRuntime(mixedPort: settings.mixedPort, controllerPort: controllerPort,
                                  secret: UUID().uuidString + UUID().uuidString, mode: settings.mode, tun: tun,
                                  gate: gateAddresses, geo: settings.geo)
        let home = MihomoCore.home(tun: tun)
        let config = try await writeConfig(subscription, runtime: runtime, home: home)
        try await validate(config, home: home, core: core)

        generation += 1
        let current = generation
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["-d", home.path, "-f", config.path]
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendLogs(text) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.handleExit(generation: current, status: status) }
        }
        logs = []
        try process.run()
        try? FileManager.default.createDirectory(at: MihomoCore.pidFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? String(process.processIdentifier).write(to: MihomoCore.pidFile, atomically: true, encoding: .utf8)
        self.process = process
        let api = MihomoAPI(port: controllerPort, secret: runtime.secret)

        var ready = false
        for _ in 0..<60 where process.isRunning {
            if (try? await api.version()) != nil { ready = true; break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard ready else {
            let reason = logs.last ?? "没有输出"
            await halt(restoreSystemProxy: false)
            throw CoreError("内核启动后没有就绪：\(reason)")
        }
        self.api = api
        self.runtime = runtime
        running = true
        monitor.attach(api)
        tunInterface = nil
        tunInterfaceMissing = false
        if tun { resolveTunInterface(api, generation: current) }
        await applySelections()
        onEvent("内置代理已启动：mihomo \(core.version)，订阅「\(subscription.name)」\(tun ? "，TUN 模式" : "")。")
        if settings.systemProxy {
            do { try await applySystemProxy(true) } catch { self.error = error.localizedDescription }
        } else if systemProxyApplied {
            try? await applySystemProxy(false)
        }
    }

    private func halt(restoreSystemProxy: Bool) async {
        if restoreSystemProxy, systemProxyApplied || MihomoCore.systemProxyPointsToCore(port: settings.mixedPort) {
            do { try await applySystemProxy(false) } catch { self.error = error.localizedDescription }
        }
        generation += 1
        api = nil
        runtime = nil
        running = false
        tunInterface = nil
        monitor.attach(nil)
        snapshot = ProxySnapshot()
        guard let process else { return }
        self.process = nil
        if process.isRunning {
            process.terminate()
            for _ in 0..<30 where process.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: MihomoCore.pidFile)
    }

    private func handleExit(generation finished: Int, status: Int32) {
        guard finished == generation, process != nil else { return }
        process = nil
        api = nil
        runtime = nil
        running = false
        tunInterface = nil
        monitor.attach(nil)
        snapshot = ProxySnapshot()
        try? FileManager.default.removeItem(at: MihomoCore.pidFile)
        var message = "代理内核意外退出（状态 \(status)）。"
        if let last = logs.last { message += "最后输出：\(last)。" }
        if systemProxyApplied {
            message += "系统代理仍指向 Lockgate 端口，网络保持断开以避免直连；请重新启动代理，或手动关闭系统代理。"
        }
        error = message
        onEvent(message)
    }

    private static func compact(_ line: String) -> String {
        guard let level = line.range(of: "level="), let message = line.range(of: " msg=") else { return line }
        let name = line[level.upperBound..<message.lowerBound]
        let text = line[message.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return "[\(name)] \(text.replacingOccurrences(of: "\\\"", with: "\""))"
    }

    private func appendLogs(_ text: String) {
        let lines = text.split(separator: "\n").map { Self.compact(String($0)) }
        logs = Array((logs + lines).suffix(200))
    }

    // MARK: 接管方式

    private func applySystemProxy(_ enabled: Bool) async throws {
        let port = settings.mixedPort
        try await Task.detached { try MihomoCore.setSystemProxy(port: enabled ? port : nil) }.value
        systemProxyApplied = enabled
    }

    func setSystemProxy(_ enabled: Bool) {
        guard !busy, settings.systemProxy != enabled || systemProxyApplied != enabled else { return }
        settings.systemProxy = enabled
        save()
        // 关闭时只处理确实指向 Lockgate 端口的系统代理，不清除其他代理软件设置的系统代理。
        guard enabled ? running : (systemProxyApplied || MihomoCore.systemProxyPointsToCore(port: settings.mixedPort)) else { return }
        Task {
            do {
                try await applySystemProxy(enabled)
                onEvent(enabled ? "已将系统代理指向内置代理。" : "已关闭系统代理。")
            } catch { self.error = error.localizedDescription }
        }
    }

    func setTun(_ enabled: Bool) {
        guard !busy, settings.tun != enabled else { return }
        settings.tun = enabled
        save()
        guard running else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                try await restart(interactive: true)
                onEvent(enabled ? "已切换到 TUN 模式。" : "已关闭 TUN 模式。")
            } catch {
                self.error = error.localizedDescription
                guard enabled else { return }
                settings.tun = false
                save()
                do { try await launch(interactive: false) } catch { self.error = error.localizedDescription }
            }
        }
    }

    func setMode(_ mode: ProxyMode) {
        guard settings.mode != mode else { return }
        guard gateAddresses == nil else { error = "内核阻断开启时固定使用规则模式。"; return }
        settings.mode = mode
        save()
        guard let api else { return }
        Task {
            do {
                try await api.setMode(mode)
                await api.closeConnections()
                onEvent("代理模式已切换为「\(mode.title)」。")
            } catch { self.error = error.localizedDescription }
        }
    }

    func setPort(_ port: Int) {
        guard !busy, port != settings.mixedPort else { return }
        guard ProxySettings.isValidPort(port) else { error = "端口需在 1024–65535 之间。"; return }
        Task {
            busy = true
            defer { busy = false }
            let wasRunning = running
            if wasRunning { await halt(restoreSystemProxy: true) }
            settings.mixedPort = port
            save()
            guard wasRunning else { return }
            do { try await launch(interactive: true) } catch { self.error = error.localizedDescription }
        }
    }

    // MARK: 节点

    func refresh() async {
        guard let api else { return }
        if let fresh = try? await api.snapshot() { snapshot = fresh }
    }

    private func applySelections() async {
        await refresh()
        guard let api, let id = settings.activeSubscription, let saved = settings.selections[id.uuidString] else { return }
        var changed = false
        for group in snapshot.groups where group.selectable {
            guard let node = saved[group.name], node != group.now, group.all.contains(node) else { continue }
            if (try? await api.select(group: group.name, node: node)) != nil { changed = true }
        }
        if changed { await refresh() }
    }

    func select(group: String, node: String) {
        guard let api, let id = settings.activeSubscription else { return }
        Task {
            do {
                try await api.select(group: group, node: node)
                settings.selections[id.uuidString, default: [:]][group] = node
                save()
                await api.closeConnections()
                await refresh()
            } catch { self.error = "无法切换节点：\(error.localizedDescription)" }
        }
    }

    func testDelay(group: String) {
        guard let api, !testing.contains(group) else { return }
        testing.insert(group)
        Task {
            let result = await api.testDelay(group: group)
            testing.remove(group)
            for (name, delay) in result where delay > 0 { snapshot.delays[name] = delay }
            await refresh()
        }
    }

    // MARK: 订阅

    private struct Fetched {
        let data: Data
        let kind: SubscriptionKind
        let usage: SubscriptionUsage?
        let suggestedName: String?
    }

    private func fetch(_ url: URL) async throws -> Fetched {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // 多数订阅服务按 User-Agent 决定返回的格式，需要表明自己是 Clash Meta（mihomo）内核。
        request.setValue("clash.meta/\(core?.version ?? "v1.19.0") Lockgate", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CoreError("订阅服务器返回 \((response as? HTTPURLResponse)?.statusCode ?? 0)。")
        }
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024 else { throw CoreError("订阅内容为空或过大。") }
        guard let kind = ProfileComposer.kind(of: String(decoding: data, as: UTF8.self)) else {
            throw ProfileError.unrecognized
        }
        var name: String?
        if let disposition = http.value(forHTTPHeaderField: "Content-Disposition") {
            if let range = disposition.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
                name = String(disposition[range.upperBound...].prefix { $0 != ";" }).removingPercentEncoding
            } else if let range = disposition.range(of: "filename=", options: .caseInsensitive) {
                name = String(disposition[range.upperBound...].prefix { $0 != ";" })
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
        }
        return Fetched(data: data, kind: kind,
                       usage: SubscriptionUsage.parse(http.value(forHTTPHeaderField: "subscription-userinfo")),
                       suggestedName: name.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) })
    }

    func addSubscription(name: String, url text: String) {
        guard !adding else { return }
        guard let url = Subscription.validatedURL(text) else { error = "请输入有效的 http / https 订阅地址。"; return }
        guard !settings.subscriptions.contains(where: { $0.url == url.absoluteString }) else {
            error = "这个订阅地址已经添加过了。"; return
        }
        adding = true
        error = nil
        Task {
            defer { adding = false }
            do {
                let fetched = try await fetch(url)
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = trimmed.isEmpty ? (fetched.suggestedName ?? url.host ?? "订阅") : trimmed
                let subscription = Subscription(name: title, url: url.absoluteString, kind: fetched.kind,
                                                updatedAt: Date(), usage: fetched.usage)
                try store.saveProfile(fetched.data, id: subscription.id)
                settings.subscriptions.append(subscription)
                if settings.activeSubscription == nil { settings.activeSubscription = subscription.id }
                save()
                onEvent("已添加订阅「\(title)」。")
                startAfterFirstSubscription()
            } catch { self.error = "添加订阅失败：\(error.localizedDescription)" }
        }
    }

    /// 导入本地配置文件。内容会复制一份保存，之后原文件的改动不会自动生效，需要「重新导入」。
    func importLocal(_ file: URL) {
        error = nil
        do {
            let local = try Subscription.readLocal(file)
            let title = String(file.deletingPathExtension().lastPathComponent.prefix(60))
            let subscription = Subscription(name: title.isEmpty ? "本地配置" : title, url: "", kind: local.kind,
                                            updatedAt: Date(), localPath: file.path)
            try store.saveProfile(local.data, id: subscription.id)
            settings.subscriptions.append(subscription)
            if settings.activeSubscription == nil { settings.activeSubscription = subscription.id }
            save()
            onEvent("已导入本地配置「\(subscription.name)」。")
            startAfterFirstSubscription()
        } catch { self.error = "导入本地配置失败：\(error.localizedDescription)" }
    }

    /// 有了第一条订阅后内核就可以运行了，不用再手动启动。用户手动停止过则不打扰。
    private func startAfterFirstSubscription() {
        guard settings.subscriptions.count == 1, !running, !stoppedByUser else { return }
        Task { await start(interactive: false) }
    }

    func updateSubscription(_ id: UUID, silent: Bool = false) async {
        guard !updating.contains(id), let index = settings.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let subscription = settings.subscriptions[index]
        let url = Subscription.validatedURL(subscription.url)
        guard subscription.isLocal || url != nil else { return }
        updating.insert(id)
        defer { updating.remove(id) }
        let name = subscription.name
        let previous = try? Data(contentsOf: store.profileURL(id))
        var replaced = false
        do {
            let fetched: Fetched
            if let url {
                fetched = try await fetch(url)
            } else {
                guard let path = subscription.localPath, FileManager.default.fileExists(atPath: path) else {
                    throw CoreError("原文件已不存在，无法重新导入。当前保存的内容不受影响。")
                }
                let local = try Subscription.readLocal(URL(fileURLWithPath: path))
                fetched = Fetched(data: local.data, kind: local.kind, usage: nil, suggestedName: nil)
            }
            try store.saveProfile(fetched.data, id: id)
            replaced = true
            guard let index = settings.subscriptions.firstIndex(where: { $0.id == id }) else { return }
            settings.subscriptions[index].kind = fetched.kind
            settings.subscriptions[index].updatedAt = Date()
            settings.subscriptions[index].usage = fetched.usage ?? settings.subscriptions[index].usage
            settings.subscriptions[index].lastError = nil
            save()
            if id == settings.activeSubscription, running { try await reloadConfig() }
            onEvent(subscription.isLocal ? "本地配置「\(name)」已重新导入。" : "订阅「\(name)」已更新。")
        } catch {
            // 新内容没能通过校验或重载时退回上一份，避免留下一份下次启动不了的配置。
            if replaced, let previous {
                try? store.saveProfile(previous, id: id)
                if let index = settings.subscriptions.firstIndex(where: { $0.id == id }) {
                    settings.subscriptions[index].kind = subscription.kind
                    settings.subscriptions[index].updatedAt = subscription.updatedAt
                }
            }
            if let index = settings.subscriptions.firstIndex(where: { $0.id == id }) {
                settings.subscriptions[index].lastError = error.localizedDescription
                save()
            }
            if silent { onEvent("\(subscription.isLocal ? "重新导入" : "更新订阅")「\(name)」失败，继续使用原来的配置：\(error.localizedDescription)") }
            if !silent { self.error = "\(subscription.isLocal ? "重新导入" : "更新订阅")「\(name)」失败：\(error.localizedDescription)" }
        }
    }

    private func updateStaleSubscriptions() async {
        guard settings.autoUpdateHours > 0 else { return }
        let limit = TimeInterval(settings.autoUpdateHours) * 3600
        for subscription in settings.subscriptions
        where !subscription.isLocal && Date().timeIntervalSince(subscription.updatedAt ?? .distantPast) >= limit {
            await updateSubscription(subscription.id, silent: true)
        }
    }

    func setAutoUpdateHours(_ hours: Int) {
        settings.autoUpdateHours = max(0, hours)
        save()
    }

    func activate(_ id: UUID) {
        guard !busy, settings.activeSubscription != id, settings.subscriptions.contains(where: { $0.id == id }) else { return }
        let previous = settings.activeSubscription
        settings.activeSubscription = id
        save()
        guard running else { return }
        Task {
            busy = true
            defer { busy = false }
            do {
                try await reloadConfig()
                onEvent("已切换到订阅「\(settings.active?.name ?? "")」。")
            } catch {
                self.error = "切换订阅失败：\(error.localizedDescription)"
                settings.activeSubscription = previous
                save()
                try? await reloadConfig()
            }
        }
    }

    func removeSubscription(_ id: UUID) {
        if id == settings.activeSubscription, running {
            error = "这个订阅正在使用。请先切换到其他订阅，或停止代理后再删除。"
            return
        }
        settings.subscriptions.removeAll { $0.id == id }
        settings.selections.removeValue(forKey: id.uuidString)
        if settings.activeSubscription == id { settings.activeSubscription = settings.subscriptions.first?.id }
        store.removeProfile(id)
        save()
    }

    /// 不重启内核，直接让它重新读取配置；用于订阅更新和切换订阅。
    private func reloadConfig() async throws {
        guard let api, let runtime, let core, let subscription = settings.active else { return }
        let home = MihomoCore.home(tun: runtime.tun)
        var current = runtime
        current.mode = settings.mode
        current.gate = gateAddresses
        current.geo = settings.geo
        let config = try await writeConfig(subscription, runtime: current, home: home)
        try await validate(config, home: home, core: core)
        try await api.reload(configPath: config.path)
        self.runtime = current
        await applySelections()
        await api.closeConnections()
    }

    /// TUN 网卡在内核启动后稍晚才创建，这里等最多约 10 秒。
    private func resolveTunInterface(_ api: MihomoAPI, generation current: Int) {
        Task {
            for _ in 0..<20 {
                guard current == generation, running else { return }
                if let name = await api.tunDevice() {
                    guard current == generation, running else { return }
                    tunInterface = name
                    onEvent("TUN 网卡：\(name)。")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if current == generation, running { tunInterfaceMissing = true }
        }
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: 地理数据

    private var geoHome: URL { MihomoCore.home(tun: runtime?.tun ?? settings.tun) }

    func refreshGeoFiles() {
        let home = geoHome
        Task {
            let files = await Task.detached { () -> [GeoFile] in
                MihomoCore.seedGeoData(into: home)
                return MihomoCore.geoFiles(in: home)
            }.value
            geoFiles = files
        }
    }

    /// 保存地理数据设置；代理运行中会重载配置使其生效。
    func applyGeo(_ geo: GeoSettings) {
        guard geo != settings.geo else { return }
        if let problem = geo.problem { error = problem; return }
        let previous = settings.geo
        settings.geo = geo
        save()
        geoMessage = nil
        guard running else { return }
        Task {
            do {
                try await reloadConfig()
                onEvent("地理数据设置已更新并重载配置。")
            } catch {
                settings.geo = previous
                save()
                self.error = "地理数据设置未生效，已恢复原设置：\(error.localizedDescription)"
            }
            refreshGeoFiles()
        }
    }

    /// 让内核立即重新下载地理数据库。下载由内核完成，因此需要代理正在运行。
    func updateGeoData() {
        guard let api, running, !geoUpdating else { return }
        geoUpdating = true
        geoMessage = "正在下载…"
        Task {
            do {
                try await api.updateGeo()
                geoMessage = "已检查更新（\(Self.clock.string(from: Date()))）。内核只下载当前规则用到的数据库，内容没有变化的文件不会重新写入。"
                onEvent("地理数据库已更新。")
            } catch {
                geoMessage = "更新失败：\(error.localizedDescription)"
            }
            geoUpdating = false
            refreshGeoFiles()
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    // MARK: 查看配置

    /// 订阅保存在本机的原始内容；节点列表若是 base64 则解码后显示。
    func subscriptionContent(_ subscription: Subscription) -> String {
        guard let data = try? Data(contentsOf: store.profileURL(subscription.id)) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return subscription.kind == .provider ? ProfileComposer.readableNodeList(text) : text
    }

    /// 订阅、覆写和 Lockgate 接管项合并后的最终配置，整理成 YAML。
    /// 代理运行中返回内核正在使用的配置；未运行时按当前设置生成一份预览。
    func finalConfig() async throws -> (text: String, live: Bool) {
        let raw: String
        let live: Bool
        if running, let runtime {
            raw = try String(contentsOf: MihomoCore.home(tun: runtime.tun).appendingPathComponent("config.yaml"), encoding: .utf8)
            live = true
        } else {
            guard let subscription = settings.active,
                  FileManager.default.fileExists(atPath: store.profileURL(subscription.id).path) else {
                throw CoreError("还没有可用的订阅，无法生成配置。")
            }
            let home = MihomoCore.home(tun: settings.tun)
            let preview = CoreRuntime(mixedPort: settings.mixedPort, controllerPort: 9, secret: "preview",
                                      mode: settings.mode, tun: settings.tun, gate: gateAddresses, geo: settings.geo)
            let file = try await writeConfig(subscription, runtime: preview, home: home, fileName: "preview.yaml")
            defer { try? FileManager.default.removeItem(at: file) }
            raw = try String(contentsOf: file, encoding: .utf8)
            live = false
        }
        return (try await Task.detached { try OverrideEngine.readableYAML(raw) }.value, live)
    }

    // MARK: 覆写

    func overrideContent(_ item: OverrideItem) -> String {
        store.loadOverride(item)
    }

    func addOverride(_ kind: OverrideKind) -> OverrideItem? {
        let count = settings.overrides.filter { $0.kind == kind }.count + 1
        let item = OverrideItem(name: "\(kind.title) \(count)", kind: kind)
        do {
            try store.saveOverride(kind == .yaml ? OverrideEngine.yamlTemplate : OverrideEngine.scriptTemplate, item: item)
        } catch {
            self.error = "无法创建覆写：\(error.localizedDescription)"
            return nil
        }
        settings.overrides.append(item)
        save()
        return item
    }

    func saveOverride(_ id: UUID, name: String, content: String) {
        guard let index = settings.overrides.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { settings.overrides[index].name = String(trimmed.prefix(60)) }
        settings.overrides[index].updatedAt = Date()
        do { try store.saveOverride(content, item: settings.overrides[index]) } catch {
            self.error = "无法保存覆写：\(error.localizedDescription)"
            return
        }
        save()
        applyOverrides()
    }

    func setOverrideEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = settings.overrides.firstIndex(where: { $0.id == id }), settings.overrides[index].enabled != enabled else { return }
        settings.overrides[index].enabled = enabled
        save()
        applyOverrides()
    }

    func moveOverride(_ id: UUID, by offset: Int) {
        guard let index = settings.overrides.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard settings.overrides.indices.contains(target) else { return }
        settings.overrides.swapAt(index, target)
        save()
        if settings.overrides[index].enabled, settings.overrides[target].enabled { applyOverrides() }
    }

    func removeOverride(_ id: UUID) {
        guard let index = settings.overrides.firstIndex(where: { $0.id == id }) else { return }
        let item = settings.overrides.remove(at: index)
        store.removeOverride(item)
        save()
        if item.enabled { applyOverrides() }
    }

    /// 覆写变化后：代理运行中则让内核重载配置；未运行则只做一次完整校验，下次启动时生效。
    /// 校验或重载失败时内核继续使用之前的配置。
    private func applyOverrides() {
        guard !busy else {
            overrideMessage = "代理正在切换，覆写已保存，稍后重新保存即可应用。"
            return
        }
        Task {
            busy = true
            defer { busy = false }
            overrideMessage = "正在应用覆写…"
            do {
                if running {
                    try await reloadConfig()
                    overrideMessage = "覆写已应用，内核已重新读取配置。"
                    onEvent("覆写已更新并应用。")
                } else if let subscription = settings.active, let core,
                          FileManager.default.fileExists(atPath: store.profileURL(subscription.id).path) {
                    let home = MihomoCore.home(tun: false)
                    let runtime = CoreRuntime(mixedPort: settings.mixedPort, controllerPort: 9, secret: "check",
                                              mode: settings.mode, tun: false, gate: gateAddresses)
                    let config = try await writeConfig(subscription, runtime: runtime, home: home, fileName: "check.yaml")
                    defer { try? FileManager.default.removeItem(at: config) }
                    try await validate(config, home: home, core: core)
                    overrideMessage = "覆写校验通过，下次启动代理时生效。"
                } else {
                    overrideMessage = "覆写已保存。添加订阅并启动代理后生效。"
                }
            } catch {
                overrideMessage = nil
                self.error = running ? "覆写没有生效，内核仍在使用之前的配置：\(error.localizedDescription)"
                    : "覆写校验未通过：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 内核阻断

    var gateAllowing: Bool { gateStatus == .allowing }

    /// 由门禁每秒调用：让内核里的阻断开关与门禁状态一致，并读回内核确认。
    /// `addresses` 为 nil 表示不启用；`blocked` 为 true 时拒绝访问这些地址的连接。
    func syncGate(addresses: [String]?, blocked: Bool) async {
        guard !gateSyncing else { return }
        gateSyncing = true
        defer { gateSyncing = false }
        gateAddresses = addresses
        if running, !busy, runtime?.gate != addresses {
            busy = true
            do { try await reloadConfig() } catch { self.error = "更新内核阻断规则失败：\(error.localizedDescription)" }
            busy = false
        }
        guard let addresses else { gateStatus = .off; return }
        guard running, let api, runtime?.gate == addresses else {
            gateStatus = .unavailable("内置代理没有运行，内核阻断不生效。")
            return
        }
        guard settings.tun || systemProxyApplied else {
            gateStatus = .unavailable("内置代理没有接管流量：系统代理和 TUN 模式都未开启。")
            return
        }
        let target = blocked ? ProfileComposer.gateBlock : ProfileComposer.gateAllow
        do {
            var now = try await api.selected(group: ProfileComposer.gateGroup)
            if now != target {
                try await api.select(group: ProfileComposer.gateGroup, node: target)
                now = try await api.selected(group: ProfileComposer.gateGroup)
                if blocked {
                    await closeGatedConnections(api, addresses: addresses)
                    onEvent("内核阻断已生效：拒绝访问受保护地址的连接。")
                } else {
                    onEvent("内核阻断已放行受保护地址。")
                }
            }
            guard now == target else {
                gateStatus = .unavailable("内核没有确认阻断开关的状态。")
                return
            }
            gateStatus = blocked ? .blocking : .allowing
        } catch {
            gateStatus = .unavailable("无法确认内核阻断状态：\(error.localizedDescription)")
        }
    }

    /// 切到拒绝只影响新连接，已有的连接要主动断开。
    private func closeGatedConnections(_ api: MihomoAPI, addresses: [String]) async {
        let rules = addresses.compactMap(NetworkAddressRule.init)
        guard let snapshot = try? await api.connections() else { return }
        for connection in snapshot.connections where rules.contains(where: { $0.matches(connection.host) }) {
            await api.closeConnection(connection.id)
        }
    }

    // MARK: 内核版本

    func checkUpdate() {
        guard !coreBusy else { return }
        coreBusy = true
        coreMessage = "正在查询最新版本…"
        Task {
            defer { coreBusy = false }
            do {
                let asset = try await MihomoCore.latestRelease()
                if let core, !CoreRelease.isNewer(asset.version, than: core.version) {
                    latest = nil
                    coreMessage = "已是最新版本（\(core.version)）。"
                } else {
                    latest = asset
                    coreMessage = "发现新版本 \(asset.version)。"
                }
            } catch {
                coreMessage = nil
                self.error = error.localizedDescription
            }
        }
    }

    func upgradeCore() {
        guard !coreBusy, !busy, let asset = latest else { return }
        coreBusy = true
        coreMessage = "正在下载并校验 \(asset.version)…"
        Task {
            defer { coreBusy = false }
            do {
                _ = try await MihomoCore.install(asset)
                latest = nil
                coreMessage = "内核已升级到 \(asset.version)。"
                onEvent("mihomo 内核已升级到 \(asset.version)（SHA256 校验通过）。")
                await switchCore()
            } catch {
                coreMessage = nil
                self.error = error.localizedDescription
            }
        }
    }

    func restoreBundledCore() {
        guard !coreBusy, !busy, core?.bundled == false else { return }
        coreBusy = true
        Task {
            defer { coreBusy = false }
            await Task.detached { MihomoCore.removeUpgraded() }.value
            coreMessage = "已恢复内嵌版本。"
            onEvent("mihomo 内核已恢复为内嵌版本。")
            await switchCore()
        }
    }

    private func switchCore() async {
        let wasRunning = running
        if wasRunning {
            busy = true
            await halt(restoreSystemProxy: false)
        }
        await loadCoreInfo()
        guard wasRunning else { return }
        defer { busy = false }
        do { try await launch(interactive: true) } catch { self.error = error.localizedDescription }
    }

    func revokeTunAuthorization() {
        guard !busy, !(running && settings.tun) else {
            error = "请先关闭 TUN 模式，再移除授权。"
            return
        }
        Task {
            do {
                try await Task.detached { try MihomoCore.removePrivileged() }.value
                tunAuthorized = false
                onEvent("已移除 TUN 模式的特权内核。")
            } catch { self.error = error.localizedDescription }
        }
    }
}
