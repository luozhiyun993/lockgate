import Foundation

public struct NetworkFilterPreferences: Codable, Equatable {
    public var enabled = false
    public var includeOtherApps = false
    public var addresses = Self.defaultAddresses
    public var rules: [NetworkAddressRule] { addresses.compactMap(NetworkAddressRule.init) }

    public static let defaultAddresses = ["claude.ai", "*.claude.ai", "api.anthropic.com",
        "platform.claude.com", "sso.claude.com", "mcp-proxy.anthropic.com",
        "*.claudeusercontent.com"]

    public init() {}

    public var validationError: String? {
        guard addresses.count <= 200 else { return "最多允许 200 条网络地址规则。" }
        for address in addresses where !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && NetworkAddressRule(address) == nil {
            return "无效地址：\(address)。请输入域名、*.子域名规则或 IP，不含协议、端口或路径。"
        }
        return nil
    }
}

public struct NetworkAddressRule: Equatable {
    public let value: String
    public let subdomains: Bool

    public init?(_ raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let ip = IPAddress.normalized(normalized) {
            value = ip
            subdomains = false
            return
        }
        subdomains = normalized.hasPrefix("*.")
        let domain = subdomains ? String(normalized.dropFirst(2)) : normalized
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domain.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                  && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), labels.last?.contains(where: { $0.isLetter }) == true else { return nil }
        value = domain
    }

    public func matches(_ destination: String) -> Bool {
        let host = IPAddress.normalized(destination) ?? destination.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return subdomains ? host.hasSuffix("." + value) : host == value
    }
}

public struct FilterPolicySnapshot: Codable, Equatable {
    public var ownerUID: UInt32
    public var blocked: Bool
    public var protectDesktop: Bool
    public var protectCLI: Bool
    public var desktopRoots: [String]
    public var cliPaths: [String]
    public var preferences: NetworkFilterPreferences
    public var revision: UUID

    public init(ownerUID: UInt32, blocked: Bool, protectDesktop: Bool, protectCLI: Bool,
                desktopRoots: [String], cliPaths: [String], preferences: NetworkFilterPreferences) {
        self.ownerUID = ownerUID
        self.blocked = blocked
        self.protectDesktop = protectDesktop
        self.protectCLI = protectCLI
        self.desktopRoots = desktopRoots
        self.cliPaths = cliPaths
        self.preferences = preferences
        revision = UUID()
    }

    public func protects(uid: UInt32?, executable: String?, entrypoint: String?, hostname: String?, ip: String?) -> Bool {
        guard uid == ownerUID else { return false }
        if let executable {
            if protectDesktop, desktopRoots.contains(where: {
                !$0.isEmpty && executable.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")
            }) { return true }
            if protectCLI {
                if cliPaths.contains(executable) { return true }
                if ["node", "bun"].contains(URL(fileURLWithPath: executable).lastPathComponent),
                   let entrypoint, cliPaths.contains(entrypoint), entrypoint.hasSuffix("/@anthropic-ai/claude-code/cli.js") { return true }
            }
        }
        guard preferences.includeOtherApps else { return false }
        return preferences.addresses.compactMap(NetworkAddressRule.init).contains { rule in
            [hostname, ip].compactMap { $0 }.contains(where: rule.matches)
        }
    }
}

public struct FilterLease {
    public private(set) var policy: FilterPolicySnapshot
    public private(set) var receivedAt: TimeInterval?
    public static let timeout: TimeInterval = 8

    public init(policy: FilterPolicySnapshot) { self.policy = policy }

    public mutating func receive(_ policy: FilterPolicySnapshot, uptime: TimeInterval) {
        self.policy = policy
        receivedAt = uptime
    }

    public func shouldBlock(uptime: TimeInterval) -> Bool {
        guard let receivedAt else { return true }
        let elapsed = uptime - receivedAt
        return policy.blocked || elapsed < 0 || elapsed >= Self.timeout
    }
}

@objc public protocol LockgateFilterIPC {
    func updatePolicy(_ data: Data, reply: @escaping (Data?) -> Void)
}

public struct FilterAcknowledgement: Codable {
    public let revision: UUID
    public let blocked: Bool
    public let droppedFlows: Int

    public init(revision: UUID, blocked: Bool, droppedFlows: Int) {
        self.revision = revision
        self.blocked = blocked
        self.droppedFlows = droppedFlows
    }
}
