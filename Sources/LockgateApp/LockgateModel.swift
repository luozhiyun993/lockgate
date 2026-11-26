import AppKit
import Foundation
import LockgateCore

struct LockgateEvent: Identifiable, Codable {
    var id = UUID()
    var time = Date()
    var text: String
}

@MainActor
final class LockgateModel: ObservableObject {
    let networkFilter = NetworkFilterController()
    @Published var savingSettings = false
    private var filterApproved = false
    private var filterTask: Task<Void, Never>?
    @Published var state: ProtectionState
    @Published var local: LocalHealth = .unknown("正在读取系统代理与路由状态…")
    @Published private(set) var processHealth: ProcessHealth = .unknown("正在读取受保护进程…")
    @Published private(set) var transport: NetworkTransport?
    @Published var exit: ExitHealth = .unknown("正在检测出口…")
    @Published var events: [LockgateEvent] = []
    @Published var notice = ""
    @Published var checking = false
    @Published var stopping = false
    @Published var savingError: String?
    @Published var simulationOutput: [String] = []
    @Published var lastChecked: Date?
    /// 分域名出口：只做诊断展示，不参与门禁判定，也不写入保护规则。
    @Published private(set) var probeDomains: [String]
    @Published private(set) var domainExits: [String: DomainProbeResult] = [:]
    @Published private(set) var probingDomains = false
    @Published private(set) var domainsCheckedAt: Date?
    @Published private(set) var domainProbeNote: String?
    private var initialDomainProbeStarted = false
    private static let probeDomainsKey = "probeDomains"
    private let store = StateStore()
    private var localTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var lastNetworkUpdate = Date.distantPast
    private var revision = 0
    private var recovering = false
    private var checkingLocal = false
    private var localRevision = 0
    private var localChecked = Date.distantPast
    private var processChecked = Date.distantPast
    private var wakeObserver: NSObjectProtocol?
    private var lastConfirmedTransport: NetworkTransport?

    init() {
        let savedDomains = UserDefaults.standard.stringArray(forKey: Self.probeDomainsKey)
            ?? ProbeDomain.recommended
        var seen = Set<String>()
        probeDomains = savedDomains.compactMap(ProbeDomain.normalized).filter { seen.insert($0).inserted }
        do {
            state = try store.load()
            state.enabled = false
        } catch {
            state = ProtectionState()
            state.lockedReason = "设置文件无法读取，请重新保存设置后检查并解锁。"
            savingError = "无法读取原有设置：\(error.localizedDescription)"
        }
        let logURL = store.directory.appendingPathComponent("events.json")
        if let data = try? Data(contentsOf: logURL), let saved = try? JSONDecoder().decode([LockgateEvent].self, from: data) {
            events = Array(saved.prefix(200))
        }
        record("应用已打开。监控处于观察模式，启用保护后才会执行急停。")
        persist()
        filterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.recovering { await self.networkFilter.poll(policy: self.filterPolicy) }
                self.persist()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        localTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshLocal()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        networkTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Date().timeIntervalSince(self.lastNetworkUpdate) >= 10 { await self.refreshExit() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.revision += 1
                self.filterApproved = false
                self.exit = .unknown("系统刚刚唤醒，重新检测出口。")
                self.local = .unknown("系统刚刚唤醒，重新检测代理。")
                self.processHealth = .unknown("系统刚刚唤醒，重新检查受保护进程。")
                self.localChecked = .distantPast
                self.processChecked = .distantPast
                self.lastNetworkUpdate = .distantPast
                self.record("系统唤醒：旧检测结果已失效，等待重新检查。")
            }
        }
    }

    var networkStatus: LocalHealth {
        if localChecked == .distantPast { return local }
        return Date().timeIntervalSince(localChecked) < 8
            ? local : .unknown("代理检查结果已过期，等待重新检测。")
    }

    var processStatus: ProcessHealth {
        if processChecked == .distantPast { return processHealth }
        return Date().timeIntervalSince(processChecked) < 8
            ? processHealth : .unknown("进程检查结果已过期，启动门禁保持关闭，等待重新检测。")
    }

    var decision: Decision {
        LockgatePolicy.evaluate(settings: state.settings, local: networkStatus, exit: exit,
                                processes: processStatus, previousIP: state.lastIP)
    }

    var statusTitle: String {
        if state.lockedReason != nil { return "保护已锁定" }
        if !state.enabled { return "观察模式" }
        if !filterReady { return "网络阻断未就绪" }
        switch decision {
        case .allow, .warn: return "保护运行中"
        case .wait(let reason):
            if processStatus.blockingReason == reason { return "等待进程确认" }
            return "等待网络确认"
        case .trip: return "检测到异常"
        }
    }

    var statusDetail: String {
        if let reason = state.lockedReason { return reason }
        if !state.enabled { return "正在检测环境。启用保护后，异常将触发急停。" }
        if !filterReady { return networkFilter.status }
        switch decision {
        case .allow: return "启动门禁已就绪，正在持续检查代理、出口与进程。"
        case .warn(let reason), .wait(let reason), .trip(let reason): return reason
        }
    }

    var currentObservation: ExitObservation? {
        if case .known(let result) = exit { return result }
        return nil
    }

    var networkGuidance: String {
        if case .systemHTTPS = transport {
            return "系统代理模式：Claude Code 请通过本应用启动，其他入口可能不跟随系统代理。"
        }
        return "自动识别系统 HTTPS 代理或实际隧道路由，不依赖代理软件名称。"
    }

    func record(_ text: String) {
        if events.first?.text == text { return }
        events.insert(LockgateEvent(text: text), at: 0)
        events = Array(events.prefix(200))
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: store.directory.appendingPathComponent("events.json"), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                ofItemAtPath: store.directory.appendingPathComponent("events.json").path)
        }
    }

    /// 系统扩展方式的网络阻断开启时，是否已确认处于放行状态；未开启时视为就绪。
    var filterReady: Bool {
        !state.settings.filterPreferences.enabled || networkFilter.permitsLaunch(policy: filterPolicy)
    }

    func persist() {
        state.heartbeat = Date()
        state.filterReadyUntil = filterReady && state.settings.filterPreferences.enabled
            ? Date().addingTimeInterval(4) : nil
        do { try store.save(state) }
        catch {
            savingError = "无法保存保护状态：\(error.localizedDescription)"
            state.lockedReason = "保护状态无法保存，启动门禁保持关闭。"
        }
    }

    func refreshLocal() async {
        guard !checkingLocal else { return }
        checkingLocal = true
        defer { checkingLocal = false }
        let settings = state.settings
        let capturedRevision = revision
        let result = await Task.detached { (LocalInspector.inspectConnection(), ProcessInspector.inspect(settings: settings)) }.value
        guard revision == capturedRevision else { return }
        let connection = result.0
        if connection.transport != transport {
            revision += 1
            exit = .unknown("网络路径已变化，等待新的出口检测。")
            lastNetworkUpdate = .distantPast
            transport = connection.transport
        }
        if let newTransport = connection.transport {
            if let previous = lastConfirmedTransport, newTransport.requiresProcessRestart(after: previous),
               state.enabled, state.lockedReason == nil {
                state.observe(.trip("系统代理路径已切换，已有进程可能仍使用旧代理，请检查并手动恢复。"))
                record("已锁定：系统代理路径变化，等待手动恢复。")
                notice = state.lockedReason ?? ""
            }
            lastConfirmedTransport = newTransport
            // 启动后确认到网络路径时自动检测一次分域名出口，之后只手动触发。
            if !initialDomainProbeStarted {
                initialDomainProbeStarted = true
                Task { await probeDomainExits() }
            }
        }
        if connection.health != local { record("网络检查：\(connection.health.summary)") }
        local = connection.health
        localChecked = Date()
        localRevision += 1
        updateProcessHealth(result.1)
        applyDecision()
        persist()
        if state.enabled, state.lockedReason != nil { await enforceLock() }
    }

    private func updateProcessHealth(_ inspection: ProcessInspection) {
        let health = inspection.health
        if health != processHealth { record("进程检查：\(health.summary)") }
        processHealth = health
        processChecked = Date()
    }

    func refreshExit() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        guard let requestTransport = transport else {
            exit = .unknown("尚未确认系统代理或隧道路径，暂不发送出口探针。")
            lastNetworkUpdate = Date()
            return
        }
        let capturedRevision = revision
        let result = await ExitInspector.inspect(transport: requestTransport)
        await refreshLocal()
        guard revision == capturedRevision, transport == requestTransport else { return }
        exit = result
        lastChecked = Date()
        lastNetworkUpdate = Date()
        switch result {
        case .known(let observation):
            if let previous = state.lastIP, previous != observation.ip {
                record("出口 IP 发生变化；当前地区 \(observation.country)。")
            }
            if case .wait = decision {} else { recordNetworkResult(observation) }
        case .unknown(let reason): record(reason)
        }
        applyDecision()
        if case .known(let observation) = result { state.lastIP = observation.ip }
        persist()
        if state.enabled, state.lockedReason != nil { await enforceLock() }
    }

    /// 添加一个或多个域名。返回无法识别的条目（供界面保留修改）和提示；全部添加成功时提示为 nil。
    func addProbeDomains(_ text: String) -> (invalid: [String], message: String?) {
        let parsed = ProbeDomain.parseList(text)
        let added = parsed.domains.filter { !probeDomains.contains($0) }
        let duplicates = parsed.domains.count - added.count
        if !added.isEmpty {
            probeDomains.append(contentsOf: added)
            UserDefaults.standard.set(probeDomains, forKey: Self.probeDomainsKey)
        }
        var parts: [String] = []
        if !added.isEmpty, duplicates > 0 || !parsed.invalid.isEmpty { parts.append("已添加 \(added.count) 个") }
        if duplicates > 0 { parts.append("\(duplicates) 个已在列表中") }
        if !parsed.invalid.isEmpty { parts.append("\(parsed.invalid.count) 个格式无效：\(parsed.invalid.joined(separator: "、"))") }
        if parsed.domains.isEmpty, parsed.invalid.isEmpty { parts.append("没有可添加的域名") }
        return (parsed.invalid, parts.isEmpty ? nil : parts.joined(separator: "；") + "。")
    }

    /// 把推荐清单中尚未添加的域名追加到列表末尾，不删除已有域名。
    func addRecommendedProbeDomains() -> String? {
        addProbeDomains(ProbeDomain.recommended.joined(separator: "\n")).message
    }

    func removeProbeDomain(_ domain: String) {
        probeDomains.removeAll { $0 == domain }
        domainExits[domain] = nil
        UserDefaults.standard.set(probeDomains, forKey: Self.probeDomainsKey)
    }

    func probeDomainExits() async {
        guard !probingDomains, !probeDomains.isEmpty else { return }
        guard let requestTransport = transport else {
            domainProbeNote = "尚未确认系统代理或隧道路径，暂不发送探针。"
            return
        }
        probingDomains = true
        domainProbeNote = nil
        defer { probingDomains = false }
        let domains = probeDomains
        // 域名数量不限，但同时最多 8 个请求，避免列表很长时一次性向代理打出大量连接。
        let results = await withTaskGroup(of: (String, DomainProbeResult).self) { group in
            var pending = domains.makeIterator()
            func enqueueNext() {
                guard let domain = pending.next() else { return }
                group.addTask { (domain, await ExitInspector.inspect(domain: domain, transport: requestTransport)) }
            }
            for _ in 0..<8 { enqueueNext() }
            var collected: [String: DomainProbeResult] = [:]
            for await (domain, result) in group {
                collected[domain] = result
                enqueueNext()
            }
            return collected
        }
        guard transport == requestTransport else {
            domainProbeNote = "检测期间网络路径发生变化，结果已丢弃，请重新检测。"
            return
        }
        domainExits = results
        domainsCheckedAt = Date()
        var ips = Set<String>()
        var reachable = 0
        var failed = 0
        for result in results.values {
            switch result.outcome {
            case .observed(let observation): ips.insert(observation.ip)
            case .reachable: reachable += 1
            case .unreachable, .invalidDomain: failed += 1
            }
        }
        record("分域名出口检测完成：\(domains.count) 个域名，观察到 \(ips.count) 个不同出口 IP；"
            + "\(reachable) 个可连接但无法回显 IP，\(failed) 个连接失败。")
    }

    private func recordNetworkResult(_ observation: ExitObservation) {
        let entry = "出口检测完成：\(observation.country) · \(decision.mayLaunch ? "规则通过" : "规则未通过")。"
        if !events.prefix(5).contains(where: { $0.text == entry }) { record(entry) }
    }

    private func applyDecision() {
        let wasLocked = state.lockedReason
        state.observe(decision)
        if state.enabled, state.lockedReason == nil, decision.mayLaunch { filterApproved = true }
        if state.lockedReason != nil { filterApproved = false }
        if wasLocked == nil, let reason = state.lockedReason {
            record("已锁定：\(reason)")
            notice = "已触发保护：\(reason)"
            NSSound.beep()
        }
    }

    func enableProtection() {
        state.enabled = true
        filterApproved = false
        record("用户启用保护。锁定期间将持续终止选中的 Claude 进程，包括外部启动。")
        applyDecision()
        persist()
        Task {
            if state.settings.filterPreferences.enabled { _ = await networkFilter.enable(policy: filterPolicy) }
            await refreshLocal()
            await refreshExit()
        }
    }

    func pauseProtection() {
        Task { _ = await stopProtection() }
    }

    func stopProtection() async -> Bool {
        guard await networkFilter.disable() else { notice = networkFilter.status; return false }
        state.enabled = false
        filterApproved = false
        revision += 1
        record("用户停止保护；系统过滤已停用或未安装。已有锁定保持。")
        persist()
        return true
    }

    func saveSettings(_ settings: LockgateSettings) {
        var settings = settings
        var preferences = settings.filterPreferences
        settings.customStopApplications = CustomStopTargets.normalized(settings.customStopApplications)
        preferences.addresses = preferences.addresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        // 系统扩展方式的开关已从界面移除；保存时一并关闭，避免旧设置里残留的开启状态无法取消。
        preferences.enabled = false
        preferences.includeOtherApps = false
        settings.filterPreferences = preferences
        if let error = settings.validationError { notice = error; return }
        guard !savingSettings else { return }
        savingSettings = true
        Task {
            defer { savingSettings = false }
            if !settings.filterPreferences.enabled, state.settings.filterPreferences.enabled || networkFilter.systemEnabled {
                guard await networkFilter.disable() else { notice = networkFilter.status; return }
            }
            applySettings(settings)
            if settings.filterPreferences.enabled { _ = await networkFilter.enable(policy: filterPolicy) }
            await refreshLocal()
            await refreshExit()
        }
    }

    private func applySettings(_ settings: LockgateSettings) {
        state.settings = settings
        filterApproved = false
        revision += 1
        exit = .unknown("设置已更改，正在重新检测。")
        processHealth = .unknown("保护对象设置已更新，正在重新检查受保护进程。")
        processChecked = .distantPast
        lastNetworkUpdate = .distantPast
        savingError = nil
        persist()
        record("保护规则已保存；已有锁定不会自动解除。")
        notice = savingError ?? "设置已保存。"
    }

    var filterPolicy: FilterPolicySnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cli = ProcessInspector.claudeCommand()?.resolvingSymlinksInPath().path
        return FilterPolicySnapshot(ownerUID: getuid(),
            blocked: !state.enabled || state.lockedReason != nil || !filterApproved,
            protectDesktop: state.settings.protectDesktop, protectCLI: state.settings.protectCLI,
            desktopRoots: ["/Applications/Claude.app/Contents/", "\(home)/Applications/Claude.app/Contents/"],
            cliPaths: cli.map { [$0] } ?? [], preferences: state.settings.filterPreferences)
    }

    func retryNetworkFilter() {
        guard state.settings.filterPreferences.enabled else {
            notice = "请先保存网络阻断设置，再重试安装。"
            return
        }
        Task { _ = await networkFilter.enable(policy: filterPolicy) }
    }

    func recheck() {
        Task { await refreshLocal(); await refreshExit() }
    }

    private func freshCheck() async -> Decision {
        guard !checking, !checkingLocal else { return .wait("正在检查，请等待当前检测完成后重试。") }
        let capturedRevision = revision
        let oldLocalRevision = localRevision
        await refreshLocal()
        await refreshExit()
        await networkFilter.poll(policy: filterPolicy)
        persist()
        guard revision == capturedRevision, localRevision > oldLocalRevision,
              Date().timeIntervalSince(lastNetworkUpdate) < 2 else {
            return .wait("本次检查未完成或设置发生变化，请重试。")
        }
        return decision
    }

    func recover() {
        guard !recovering else { return }
        recovering = true
        Task {
            defer { recovering = false }
            guard state.enabled else { notice = "请先启用保护，再进行手动恢复。"; return }
            let result = await freshCheck()
            guard savingError == nil, !stopping, state.recover(result) else {
                notice = "尚不能解除锁定：请等待检测完成，并确保网络、出口、进程及设置全部通过。"
                return
            }
            if state.settings.filterPreferences.enabled {
                var candidate = filterPolicy
                candidate.blocked = false
                let capturedRevision = revision
                await networkFilter.poll(policy: candidate)
                guard capturedRevision == revision, state.enabled, decision.mayLaunch, !stopping,
                      savingError == nil, networkFilter.permitsLaunch(policy: candidate) else {
                    await networkFilter.poll(policy: filterPolicy)
                    notice = "网络过滤器未确认放行，保持锁定：\(networkFilter.status)"
                    return
                }
            }
            guard state.recover(decision) else { return }
            filterApproved = true
            await networkFilter.poll(policy: filterPolicy)
            persist()
            notice = "检查通过，已解除锁定。不会自动重新打开 Claude。"
            record(notice)
        }
    }

    func enforceLock() async {
        guard !stopping, state.enabled, state.lockedReason != nil else { return }
        stopping = true
        defer { stopping = false }
        let settings = state.settings
        let inspection = await Task.detached { ProcessInspector.inspect(settings: settings) }.value
        guard state.enabled, state.lockedReason != nil, state.settings == settings else { return }
        updateProcessHealth(inspection)
        if let reason = inspection.failureReason {
            record("急停检查提示：\(reason)")
        }
        let custom = await Task.detached { CustomStopTargets.inspect(settings: settings) ?? [] }.value
        let targets = Self.merge(inspection.targets, custom)
        guard !targets.isEmpty else { return }
        let report = await Task.detached { await ProcessStopper.stop(targets) }.value
        record("急停结果：已终止 \(report.stopped) 个进程\(custom.isEmpty ? "" : "（含自定义软件 \(custom.count) 个）")，失败 \(report.failed) 个。\(report.inspectionFailed ? "无法完成进程复核，请手动检查。" : "")")
        let remaining = await Task.detached { ProcessInspector.inspect(settings: settings) }.value
        guard state.settings == settings else { return }
        updateProcessHealth(remaining)
    }

    /// 合并 Claude 目标与自定义软件目标；同一进程只保留一次。
    private static func merge(_ claude: [ProcessIdentity], _ custom: [ProcessIdentity]) -> [ProcessIdentity] {
        var seen = Set(claude.map(\.pid))
        return claude + custom.filter { seen.insert($0.pid).inserted }
    }

    func emergencyStopAllClaude() {
        guard !stopping else { return }
        stopping = true
        let settings = state.settings
        Task {
            defer { stopping = false }
            let inspection = await Task.detached {
                ProcessInspector.inspectAllClaude(settings: settings)
            }.value
            updateProcessHealth(inspection)
            if let reason = inspection.failureReason {
                record("全量急停检查提示：\(reason)")
            }
            let custom = await Task.detached { CustomStopTargets.inspect(settings: settings) ?? [] }.value
            let targets = Self.merge(inspection.targets, custom)
            guard !targets.isEmpty else {
                let message = inspection.failureReason ?? (settings.customStopApplications.isEmpty
                    ? "未发现已核实的 Claude Desktop / Code 进程。"
                    : "未发现已核实的 Claude Desktop / Code 进程，自定义软件也未在运行。")
                notice = message
                record("全量急停：\(message)")
                return
            }
            let report = await Task.detached { await ProcessStopper.stop(targets) }.value
            let remaining = await Task.detached {
                ProcessInspector.inspectAllClaude(settings: settings)
            }.value
            updateProcessHealth(remaining)
            let message = "全量急停完成：已终止 \(report.stopped) 个进程\(custom.isEmpty ? "" : "（含自定义软件 \(custom.count) 个）")，失败 \(report.failed) 个。"
            notice = report.inspectionFailed
                ? "\(message) 无法完成进程复核，请手动检查。"
                : message
            record("\(message)\(report.inspectionFailed ? " 无法完成进程复核，请手动检查。" : "")")
        }
    }

    func realStopTest() {
        guard state.enabled else { notice = "请先启用保护，才能执行真实急停测试。"; return }
        state.lockedReason = "用户触发真实急停测试。"
        persist()
        record("用户确认真实急停测试，保护进入锁定。")
        Task { await enforceLock() }
    }

    func launchDesktop() {
        Task {
            let result = await freshCheck()
            guard state.settings.protectDesktop, savingError == nil, state.permitsLaunch(result) else {
                notice = "启动门禁未通过：请启用保护、完成检查，并解除锁定。"; return
            }
            guard let app = InstallationDiscovery.discover(settings: state.settings).desktopApplications.first else {
                notice = "未发现 Claude Desktop。可在设置中填写应用路径。"; return
            }
            do {
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                record("启动检查通过，已打开 Claude Desktop。")
            } catch { notice = "无法启动 Claude：\(error.localizedDescription)" }
        }
    }

    func launchCLI() {
        Task {
            let result = await freshCheck()
            guard state.settings.protectCLI, savingError == nil, state.permitsLaunch(result) else {
                notice = "启动门禁未通过：请启用保护、完成检查，并解除锁定。"; return
            }
            guard ProcessInspector.claudeCommand(settings: state.settings) != nil, let executable = Bundle.main.executableURL else {
                notice = "未找到 Claude Code，请先安装官方 CLI。"; return
            }
            do {
                let script = store.directory.appendingPathComponent("Launch Claude Code.command")
                let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                try "#!/bin/zsh\nexec \(quoted) --guarded-cli\n".write(to: script, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                    notice = "未找到 Terminal。"; return
                }
                _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal,
                                                      configuration: NSWorkspace.OpenConfiguration())
                record("已请求打开 Claude Code 终端；执行前会再次检查门禁。")
            } catch { notice = "无法启动终端：\(error.localizedDescription)" }
        }
    }

    func simulate(_ scenario: String) {
        var settings = state.settings
        var sandbox = ProtectionState()
        sandbox.enabled = true
        sandbox.heartbeat = Date()
        let healthy = LocalHealth.healthy(interface: "演练网卡")
        let safeIP = settings.pinEnabled ? settings.pinnedIP : "8.8.8.8"
        let healthyExit = ExitHealth.known(ExitObservation(ip: safeIP, country: settings.country))
        let result: Decision
        switch scenario {
        case "网络超时":
            result = LockgatePolicy.evaluate(settings: settings, local: healthy, exit: .unknown("模拟网络超时"))
        case "地区漂移":
            result = LockgatePolicy.evaluate(settings: settings, local: healthy,
                exit: .known(ExitObservation(ip: safeIP, country: settings.country == "JP" ? "US" : "JP")))
        case "IP 不匹配":
            settings.pinEnabled = true
            settings.pinnedIP = "8.8.8.8"
            result = LockgatePolicy.evaluate(settings: settings, local: healthy,
                exit: .known(ExitObservation(ip: "1.1.1.1", country: settings.country)))
        default:
            result = LockgatePolicy.evaluate(settings: settings, local: .unsafe("模拟代理路径失效"), exit: healthyExit)
        }
        sandbox.observe(result)
        var lines = ["模拟：\(scenario)", "启动门禁：\(result.mayLaunch ? "允许" : "阻止")",
                     "运行进程：\(sandbox.lockedReason == nil ? "保留，不急停" : "将触发急停（本次不执行）")",
                     "锁定状态：\(sandbox.lockedReason == nil ? "未锁定" : "已锁定")"]
        if sandbox.lockedReason != nil {
            sandbox.observe(.allow)
            lines.append("网络恢复：\(sandbox.lockedReason != nil ? "仍锁定" : "已解锁")")
            let recovered = sandbox.recover(.allow)
            lines.append("手动恢复 + 检查通过：\(recovered ? "已解锁" : "失败")")
        }
        lines.append("演练完成：真实设置、锁定状态和进程均未改变。")
        simulationOutput = lines
    }
}
