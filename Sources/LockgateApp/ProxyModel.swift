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
    private var gateAddresses: [String]?
    private var gateSyncing = false

    private let store = ProxyStore()
    private var process: Process?
    private var api: MihomoAPI?
    private var runtime: CoreRuntime?
    private var generation = 0
    private var autoUpdateTask: Task<Void, Never>?

    init() {
        do {
            settings = try store.load()
        } catch {
            settings = ProxySettings()
            self.error = "无法读取代理设置：\(error.localizedDescription)"
        }
        systemProxyApplied = MihomoCore.systemProxyPointsToCore(port: settings.mixedPort)
        Task {
            await loadCoreInfo()
            if settings.coreEnabled { await start(interactive: false) }
        }
        autoUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            while !Task.isCancelled {
                await self?.updateStaleSubscriptions()
                try? await Task.sleep(nanoseconds: 900_000_000_000)
            }
        }
    }

    var statusSummary: String {
        if busy { return "正在切换…" }
        guard running else { return "代理未运行" }
        var parts = ["代理运行中"]
        if settings.tun { parts.append("TUN") }
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
        save()
        onEvent("用户停止了内置代理。")
    }

    /// 退出应用时调用：停止内核并恢复系统代理，但保留「下次启动时自动运行」的状态。
    func shutdown() async {
        autoUpdateTask?.cancel()
        await halt(restoreSystemProxy: true)
    }

    private func restart(interactive: Bool) async throws {
        await halt(restoreSystemProxy: false)
        try await launch(interactive: interactive)
    }

    private func writeConfig(_ subscription: Subscription, runtime: CoreRuntime, home: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        MihomoCore.seedGeoData(into: home)
        let source = try Data(contentsOf: store.profileURL(subscription.id))
        let config: String
        if subscription.kind == .provider {
            let providers = home.appendingPathComponent("providers")
            try files.createDirectory(at: providers, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ProxyStore.writePrivate(source, to: providers.appendingPathComponent("subscription.txt"))
            config = ProfileComposer.compose(providerPath: "./providers/subscription.txt", runtime: runtime)
        } else {
            config = try ProfileComposer.compose(profile: String(decoding: source, as: UTF8.self), runtime: runtime)
        }
        let url = home.appendingPathComponent("config.yaml")
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
                                  gate: gateAddresses)
        let home = MihomoCore.home(tun: tun)
        let config = try writeConfig(subscription, runtime: runtime, home: home)
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
            } catch { self.error = "添加订阅失败：\(error.localizedDescription)" }
        }
    }

    func updateSubscription(_ id: UUID, silent: Bool = false) async {
        guard !updating.contains(id), let index = settings.subscriptions.firstIndex(where: { $0.id == id }),
              let url = Subscription.validatedURL(settings.subscriptions[index].url) else { return }
        updating.insert(id)
        defer { updating.remove(id) }
        let name = settings.subscriptions[index].name
        do {
            let fetched = try await fetch(url)
            try store.saveProfile(fetched.data, id: id)
            guard let index = settings.subscriptions.firstIndex(where: { $0.id == id }) else { return }
            settings.subscriptions[index].kind = fetched.kind
            settings.subscriptions[index].updatedAt = Date()
            settings.subscriptions[index].usage = fetched.usage ?? settings.subscriptions[index].usage
            settings.subscriptions[index].lastError = nil
            save()
            onEvent("订阅「\(name)」已更新。")
            if id == settings.activeSubscription, running { try await reloadConfig() }
        } catch {
            if let index = settings.subscriptions.firstIndex(where: { $0.id == id }) {
                settings.subscriptions[index].lastError = error.localizedDescription
                save()
            }
            if !silent { self.error = "更新订阅「\(name)」失败：\(error.localizedDescription)" }
        }
    }

    private func updateStaleSubscriptions() async {
        guard settings.autoUpdateHours > 0 else { return }
        let limit = TimeInterval(settings.autoUpdateHours) * 3600
        for subscription in settings.subscriptions
        where Date().timeIntervalSince(subscription.updatedAt ?? .distantPast) >= limit {
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
        let config = try writeConfig(subscription, runtime: current, home: home)
        try await validate(config, home: home, core: core)
        try await api.reload(configPath: config.path)
        self.runtime = current
        await applySelections()
        await api.closeConnections()
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
