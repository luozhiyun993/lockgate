import Foundation
import NetworkExtension
import Security
import LockgateCore

private struct FlowIdentity {
    var uid: UInt32?
    var executable: String?
    var entrypoint: String?
}

final class FilterDataProvider: NEFilterDataProvider, NSXPCListenerDelegate, LockgateFilterIPC {
    private let stateLock = NSRecursiveLock()
    private var lease: FilterLease?
    private var listener: NSXPCListener?
    private var timer: DispatchSourceTimer?
    private var connections: [NSXPCConnection] = []
    private var flows: [UUID: (NEFilterSocketFlow, FlowIdentity)] = [:]
    private var droppedFlows = 0

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        guard let data = filterConfiguration.vendorConfiguration?["initialPolicy"] as? Data,
              let policy = try? JSONDecoder().decode(FilterPolicySnapshot.self, from: data),
              let service = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
              let name = service["NEMachServiceName"] as? String,
              let team = Bundle.main.object(forInfoDictionaryKey: "LockgateTeamID") as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
            completionHandler(NSError(domain: "LockgateFilter", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing signed extension configuration"]))
            return
        }
        lease = FilterLease(policy: policy)
        let listener = NSXPCListener(machServiceName: name)
        listener.setConnectionCodeSigningRequirement("anchor apple generic and identifier \"dev.local.lockgate\" and certificate leaf[subject.OU] = \"\(team)\"")
        listener.delegate = self
        listener.resume()
        self.listener = listener
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "lockgate.filter.lease"))
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.blockExistingFlows() }
        timer.resume()
        self.timer = timer
        apply(nil, completionHandler: completionHandler)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        timer?.cancel()
        listener?.invalidate()
        stateLock.lock()
        connections.forEach { $0.invalidate() }
        connections.removeAll()
        flows.removeAll()
        stateLock.unlock()
        completionHandler()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard connection.effectiveUserIdentifier == lease?.policy.ownerUID else { return false }
        connection.exportedInterface = NSXPCInterface(with: LockgateFilterIPC.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.stateLock.lock()
            self.connections.removeAll { $0 === connection }
            self.stateLock.unlock()
        }
        connections.append(connection)
        connection.resume()
        return true
    }

    func updatePolicy(_ data: Data, reply: @escaping (Data?) -> Void) {
        guard data.count <= 131_072, let policy = try? JSONDecoder().decode(FilterPolicySnapshot.self, from: data),
              policy.preferences.validationError == nil, policy.cliPaths.count <= 256,
              policy.desktopRoots.count <= 4 else { reply(nil); return }
        stateLock.lock()
        guard policy.ownerUID == lease?.policy.ownerUID else { stateLock.unlock(); reply(nil); return }
        lease?.receive(policy, uptime: ProcessInfo.processInfo.systemUptime)
        stateLock.unlock()
        blockExistingFlows()
        stateLock.lock()
        let result = FilterAcknowledgement(revision: policy.revision,
            blocked: lease?.shouldBlock(uptime: ProcessInfo.processInfo.systemUptime) ?? true, droppedFlows: droppedFlows)
        stateLock.unlock()
        reply(try? JSONEncoder().encode(result))
    }

    private func identity(for flow: NEFilterFlow) -> FlowIdentity {
        guard let token = flow.sourceAppAuditToken, token.count == 32 else { return FlowIdentity() }
        let uid = token.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        let pid = token.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: Int32.self) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return FlowIdentity(uid: uid) }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let values = information as? [String: Any],
              let path = values[kSecCodeInfoMainExecutable as String] as? URL else { return FlowIdentity(uid: uid) }
        let executable = path.path
        var entrypoint: String?
        if ["node", "bun"].contains(path.lastPathComponent) {
            let arguments = ProcessInspector.arguments(pid: pid)
            if arguments.count > 1, arguments[1].hasPrefix("/") {
                entrypoint = URL(fileURLWithPath: arguments[1]).resolvingSymlinksInPath().path
            }
        }
        return FlowIdentity(uid: uid, executable: executable, entrypoint: entrypoint)
    }

    private func isProtected(_ flow: NEFilterSocketFlow, identity: FlowIdentity) -> Bool {
        let endpoint = flow.remoteEndpoint as? NWHostEndpoint
        return lease?.policy.protects(uid: identity.uid, executable: identity.executable,
            entrypoint: identity.entrypoint, hostname: flow.remoteHostname, ip: endpoint?.hostname) ?? false
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard flow.direction == .outbound, let socket = flow as? NEFilterSocketFlow else { return .allow() }
        let identity = identity(for: flow)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isProtected(socket, identity: identity) else { return .allow() }
        guard lease?.shouldBlock(uptime: ProcessInfo.processInfo.systemUptime) == false,
              flows.count < 8192 else {
            droppedFlows += 1
            return .drop()
        }
        flows[flow.identifier] = (socket, identity)
        let verdict = NEFilterNewFlowVerdict.filterDataVerdict(withFilterInbound: true, peekInboundBytes: 4096,
                                                              filterOutbound: true, peekOutboundBytes: 4096)
        verdict.shouldReport = true
        return verdict
    }

    private func dataVerdict(for flow: NEFilterFlow, count: Int) -> NEFilterDataVerdict {
        stateLock.lock()
        defer { stateLock.unlock() }
        if lease?.shouldBlock(uptime: ProcessInfo.processInfo.systemUptime) != false {
            flows.removeValue(forKey: flow.identifier)
            droppedFlows += 1
            return .drop()
        }
        return NEFilterDataVerdict(passBytes: count, peekBytes: 4096)
    }

    override func handleInboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        dataVerdict(for: flow, count: readBytes.count)
    }

    override func handleOutboundData(from flow: NEFilterFlow, readBytesStartOffset offset: Int, readBytes: Data) -> NEFilterDataVerdict {
        dataVerdict(for: flow, count: readBytes.count)
    }

    override func handle(_ report: NEFilterReport) {
        if report.event == .flowClosed, let flow = report.flow {
            stateLock.lock()
            flows.removeValue(forKey: flow.identifier)
            stateLock.unlock()
        }
    }

    private func blockExistingFlows() {
        stateLock.lock()
        guard lease?.shouldBlock(uptime: ProcessInfo.processInfo.systemUptime) != false else { stateLock.unlock(); return }
        let targets = flows.values.map { $0.0 }
        flows.removeAll()
        droppedFlows += targets.count
        stateLock.unlock()
        targets.forEach { update($0, using: .drop(), for: .any) }
    }
}
