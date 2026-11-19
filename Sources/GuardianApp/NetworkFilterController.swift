import AppKit
import Foundation
import GuardianCore
import NetworkExtension
import Security
import SystemExtensions

private final class FilterReply {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) { self.continuation = continuation }

    func finish(_ data: Data?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: data)
    }
}

@MainActor
final class NetworkFilterController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let extensionID = "dev.local.agent-account-guardian.filter"
    @Published private(set) var status = "网络阻断未开启"
    @Published private(set) var isEffective = false
    @Published private(set) var busy = false
    @Published private(set) var systemEnabled = false
    private var connection: NSXPCConnection?
    private var activation: CheckedContinuation<Bool, Never>?
    private var acknowledgedAt = Date.distantPast
    private var acknowledgedPolicy: FilterPolicySnapshot?
    private let manager = NEFilterManager.shared()
    private var polling = false
    private var generation = 0

    var readiness: String? {
        guard let team = Bundle.main.object(forInfoDictionaryKey: "GuardianTeamID") as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            return "当前构建未配置 Developer ID 与系统扩展权限，网络阻断尚不可用。开关可保存偏好，但不会产生网络拦截。"
        }
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(Self.extensionID).systemextension")
        guard FileManager.default.fileExists(atPath: path.path) else { return "安装包缺少网络过滤扩展，请安装包含签名扩展的版本。" }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return "请先将应用移入 /Applications，再安装网络过滤扩展。" }
        return nil
    }

    func permitsLaunch(policy: FilterPolicySnapshot) -> Bool {
        guard policy.preferences.enabled else { return true }
        guard systemEnabled, isEffective, !busy, Date().timeIntervalSince(acknowledgedAt) >= 0,
              Date().timeIntervalSince(acknowledgedAt) < 5,
              var acknowledged = acknowledgedPolicy else { return false }
        acknowledged.revision = policy.revision
        return acknowledged == policy && !policy.blocked
    }

    private func load() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        systemEnabled = manager.isEnabled && manager.providerConfiguration?.filterDataProviderBundleIdentifier == Self.extensionID
    }

    private func save() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func enable(policy: FilterPolicySnapshot) async -> Bool {
        guard !busy, policy.preferences.enabled else { return false }
        guard let issue = readiness else { return await installAndEnable(policy: policy) }
        status = issue
        isEffective = false
        return false
    }

    private func installAndEnable(policy: FilterPolicySnapshot) async -> Bool {
        busy = true
        defer { busy = false }
        generation += 1
        while polling { try? await Task.sleep(nanoseconds: 20_000_000) }
        isEffective = false
        do {
            try await load()
            if let other = manager.providerConfiguration?.filterDataProviderBundleIdentifier, other != Self.extensionID {
                status = "检测到其他内容过滤器；为避免覆盖，请先在系统设置中处理冲突。"
                return false
            }
            if !systemEnabled {
                status = "正在请求安装系统扩展，请完成 macOS 授权。"
                let installed = await withCheckedContinuation { continuation in
                    activation = continuation
                    let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.extensionID, queue: .main)
                    request.delegate = self
                    OSSystemExtensionManager.shared.submitRequest(request)
                }
                guard installed else { return false }
                let configuration = NEFilterProviderConfiguration()
                configuration.filterSockets = true
                configuration.filterPackets = false
                configuration.filterDataProviderBundleIdentifier = Self.extensionID
                configuration.vendorConfiguration = ["initialPolicy": try JSONEncoder().encode(policy)]
                manager.providerConfiguration = configuration
                manager.localizedDescription = "Account Guardian · Claude 网络保护"
                manager.isEnabled = true
                try await save()
                try await load()
            }
            manager.providerConfiguration?.vendorConfiguration = ["initialPolicy": try JSONEncoder().encode(policy)]
            try await save()
            for _ in 0..<5 {
                if await send(policy: policy) { return true }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            status = "系统已启用过滤配置，但尚未收到扩展确认；不能视为保护就绪。"
        } catch { status = "启用网络过滤失败：\(error.localizedDescription)" }
        return false
    }

    func disable() async -> Bool {
        guard !busy else { status = "系统扩展操作尚未结束，请先处理授权提示。"; return false }
        busy = true
        defer { busy = false }
        generation += 1
        while polling { try? await Task.sleep(nanoseconds: 20_000_000) }
        do {
            try await load()
            if systemEnabled {
                manager.isEnabled = false
                try await save()
                try await load()
                guard !systemEnabled else { status = "系统尚未确认过滤已停用，请勿退出。"; return false }
            }
            connection?.invalidate()
            connection = nil
            isEffective = false
            acknowledgedPolicy = nil
            status = "网络阻断已关闭"
            return true
        } catch {
            if readiness != nil, !systemEnabled {
                let installed = await Task.detached {
                    Command.run("/usr/bin/systemextensionsctl", ["list"])
                }.value
                if installed.status == 0, !installed.output.contains(Self.extensionID) {
                    status = "系统未安装 Account Guardian 网络过滤扩展"
                    isEffective = false
                    acknowledgedPolicy = nil
                    return true
                }
            }
            status = "无法确认网络过滤已关闭：\(error.localizedDescription)"
            return false
        }
    }

    func poll(policy: FilterPolicySnapshot) async {
        guard !polling, !busy else { return }
        polling = true
        defer { polling = false }
        if let issue = readiness {
            status = policy.preferences.enabled ? issue : "网络阻断未开启 · 当前构建不含可用的签名扩展"
            isEffective = false
            return
        }
        do {
            try await load()
            guard !busy else { return }
            guard systemEnabled else {
                isEffective = false
                status = policy.preferences.enabled ? "已请求网络阻断，但系统过滤尚未启用；点击安装 / 重试。" : "网络阻断已关闭"
                return
            }
            _ = await send(policy: policy)
        } catch {
            isEffective = false
            status = "读取网络过滤状态失败：\(error.localizedDescription)"
        }
    }

    private func send(policy: FilterPolicySnapshot) async -> Bool {
        let requestGeneration = generation
        guard let team = Bundle.main.object(forInfoDictionaryKey: "GuardianTeamID") as? String,
              let service = Bundle.main.object(forInfoDictionaryKey: "GuardianFilterService") as? String,
              let data = try? JSONEncoder().encode(policy) else { return false }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: service, options: .privileged)
            connection.setCodeSigningRequirement("anchor apple generic and identifier \"\(Self.extensionID)\" and certificate leaf[subject.OU] = \"\(team)\"")
            connection.remoteObjectInterface = NSXPCInterface(with: GuardianFilterIPC.self)
            connection.resume()
            self.connection = connection
        }
        let response: Data? = await withCheckedContinuation { continuation in
            let reply = FilterReply(continuation)
            guard let remote = connection?.remoteObjectProxyWithErrorHandler({ _ in reply.finish(nil) }) as? GuardianFilterIPC else {
                reply.finish(nil)
                return
            }
            remote.updatePolicy(data) { reply.finish($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { reply.finish(nil) }
        }
        guard requestGeneration == generation else { return false }
        guard let response, let acknowledgement = try? JSONDecoder().decode(FilterAcknowledgement.self, from: response),
              acknowledgement.revision == policy.revision, acknowledgement.blocked == policy.blocked else {
            connection?.invalidate()
            connection = nil
            isEffective = false
            status = "过滤扩展未确认当前规则；受管启动保持关闭。"
            return false
        }
        acknowledgedPolicy = policy
        acknowledgedAt = Date()
        isEffective = true
        status = "\(acknowledgement.blocked ? "网络过滤已启用 · 正在阻断受保护连接" : "网络过滤已启用 · 当前允许受保护连接") · 已阻断 \(acknowledgement.droppedFlows) 条"
        return true
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.status = "等待 macOS 授权：请在系统设置中允许 Account Guardian 系统扩展。" }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            let completed = result == .completed
            if !completed { self.status = "系统扩展需要重启电脑后才能继续启用。" }
            self.activation?.resume(returning: completed)
            self.activation = nil
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.status = "系统扩展安装失败：\(error.localizedDescription)"
            self.activation?.resume(returning: false)
            self.activation = nil
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                            withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
}
