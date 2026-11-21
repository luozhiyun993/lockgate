import CryptoKit
import Darwin
import Foundation
import LockgateCore
import SystemConfiguration

struct CoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CoreBinary: Equatable {
    let url: URL
    let version: String
    let bundled: Bool
}

/// mihomo 内核文件的位置、校验、提权安装与升级。全部为阻塞调用，请在后台任务中使用。
struct GeoFile: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let name: String
    let modified: Date
    let size: Int64
}

enum MihomoCore {
    static let support = StateStore.defaultDirectory
    static let userCore = support.appendingPathComponent("core/mihomo")
    static let pidFile = support.appendingPathComponent("core/mihomo.pid")
    static let privilegedDirectory = "/Library/Application Support/Lockgate/core"
    static let privilegedCore = URL(fileURLWithPath: privilegedDirectory + "/mihomo")

    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("core")
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// 普通模式与 TUN 模式使用各自的工作目录，避免 root 运行后留下普通模式无法写入的缓存文件。
    static func home(tun: Bool) -> URL {
        support.appendingPathComponent(tun ? "mihomo-tun" : "mihomo")
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func version(of url: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        let result = run(url, ["-v"], timeout: 5)
        return result.status == 0 ? CoreRelease.version(fromOutput: result.output) : nil
    }

    static var bundledCore: CoreBinary? {
        guard let url = bundledDirectory?.appendingPathComponent("mihomo"), let version = version(of: url) else { return nil }
        return CoreBinary(url: url, version: version, bundled: true)
    }

    /// 内嵌内核与升级内核中版本较新的一个；升级内核不比内嵌的新时回到内嵌版本。
    static func activeCore() -> CoreBinary? {
        let bundled = bundledCore
        guard let version = version(of: userCore) else { return bundled }
        let upgraded = CoreBinary(url: userCore, version: version, bundled: false)
        if let bundled, !CoreRelease.isNewer(upgraded.version, than: bundled.version) { return bundled }
        return upgraded
    }

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: TUN 提权

    /// 提权内核必须由 root 持有、带 setuid、普通用户不可写，且内容与当前使用的内核一致。
    static func privilegedReady(matching core: CoreBinary) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: privilegedCore.path),
              (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              mode & 0o4000 != 0, mode & 0o022 == 0,
              let installed = sha256(of: privilegedCore), installed == sha256(of: core.url) else { return false }
        return true
    }

    static var privilegedInstalled: Bool {
        FileManager.default.fileExists(atPath: privilegedCore.path)
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runAsAdministrator(_ script: String, prompt: String) throws {
        func appleScriptString(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "do shell script \(appleScriptString(script)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        let result = run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source], timeout: 300)
        guard result.status == 0 else {
            throw CoreError(result.output.contains("-128") ? "已取消管理员授权。"
                : "管理员授权失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// 把当前内核复制到系统目录并设为 root 持有的 setuid 程序，仅 admin 组可执行。需要输入一次管理员密码。
    static func installPrivileged(from core: CoreBinary) throws {
        let directory = shellQuoted(privilegedDirectory)
        let target = shellQuoted(privilegedCore.path)
        let staging = shellQuoted(privilegedCore.path + ".new")
        let script = [
            "/bin/mkdir -p \(directory)", "/usr/sbin/chown root:wheel \(directory)", "/bin/chmod 755 \(directory)",
            "/bin/cp -f \(shellQuoted(core.url.path)) \(staging)", "/usr/sbin/chown root:admin \(staging)",
            "/bin/chmod 4750 \(staging)", "/bin/mv -f \(staging) \(target)"
        ].joined(separator: " && ")
        try runAsAdministrator(script, prompt: "Lockgate 需要管理员权限，才能安装用于 TUN 模式的 mihomo 内核。")
        guard privilegedReady(matching: core) else {
            throw CoreError("TUN 内核安装后校验未通过。请确认当前用户属于管理员组后重试。")
        }
    }

    static func removePrivileged() throws {
        try runAsAdministrator("/bin/rm -rf \(shellQuoted("/Library/Application Support/Lockgate"))",
                               prompt: "Lockgate 需要管理员权限，才能移除 TUN 模式的 mihomo 内核。")
    }

    // MARK: 进程与端口

    static func isPortFree(_ port: Int) -> Bool {
        boundPort(requested: UInt16(port)) != nil
    }

    static func freePort() -> Int? {
        boundPort(requested: 0)
    }

    private static func boundPort(requested: UInt16) -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else { return nil }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return named == 0 ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    /// 应用异常退出后可能留下仍占用端口的内核。只终止 PID 文件记录、且可执行路径确实是 Lockgate 内核的进程。
    static func terminateOrphan() {
        defer { try? FileManager.default.removeItem(at: pidFile) }
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        let command = Command.run("/bin/ps", ["-p", String(pid), "-o", "comm="]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var known = [userCore.path, privilegedCore.path]
        if let bundled = bundledDirectory?.appendingPathComponent("mihomo").path { known.append(bundled) }
        guard known.contains(command) else { return }
        kill(pid, SIGTERM)
        for _ in 0..<20 where kill(pid, 0) == 0 { usleep(100_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// 内嵌的规则数据（GeoIP / GeoSite）首次使用时复制到工作目录，避免内核启动时还要联网下载。
    static func seedGeoData(into home: URL) {
        guard let source = bundledDirectory?.appendingPathComponent("geo"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: source.path) else { return }
        for name in names {
            let target = home.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.copyItem(at: source.appendingPathComponent(name), to: target)
            }
        }
    }

    /// 数据目录里已有的地理数据库文件（文件名不区分大小写，与内核的查找方式一致）。
    static func geoFiles(in home: URL) -> [GeoFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return [("MMDB", ["geoip.metadb", "country.mmdb"]), ("GeoSite", ["geosite.dat"]),
                ("GeoIP", ["geoip.dat"]), ("ASN", ["asn.mmdb"])].compactMap { title, candidates in
            guard let name = names.first(where: { candidates.contains($0.lowercased()) }),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(name).path),
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            return GeoFile(title: title, name: name, modified: modified, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: 系统代理

    private static let networksetup = "/usr/sbin/networksetup"

    static func systemProxyPointsToCore(port: Int) -> Bool {
        guard let values = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return false }
        return SystemProxyPlan.pointsToCore(values, port: port)
    }

    static func setSystemProxy(port: Int?) throws {
        let listing = Command.run(networksetup, ["-listallnetworkservices"])
        let services = SystemProxyPlan.services(from: listing.output)
        guard listing.status == 0, !services.isEmpty else { throw CoreError("无法读取 macOS 网络服务列表。") }
        var failures = 0
        for service in services {
            let commands = port.map { SystemProxyPlan.enableCommands(service: service, port: $0) }
                ?? SystemProxyPlan.disableCommands(service: service)
            for arguments in commands where Command.run(networksetup, arguments).status != 0 { failures += 1 }
        }
        if let port {
            for _ in 0..<10 where !systemProxyPointsToCore(port: port) { usleep(100_000) }
            guard systemProxyPointsToCore(port: port) else {
                throw CoreError("系统代理设置未生效。请确认当前用户有权修改网络设置。")
            }
        } else if failures > 0 {
            throw CoreError("部分网络服务的系统代理未能关闭，请在系统设置中检查。")
        }
    }

    // MARK: 升级

    static func latestRelease() async throws -> CoreAsset {
        var request = URLRequest(url: CoreRelease.latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lockgate", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CoreError("无法查询 mihomo 最新版本（GitHub 返回 \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        guard let asset = CoreRelease.parse(data, architecture: architecture) else {
            throw CoreError("最新版本中没有适用于本机、且带校验值的 mihomo 内核。")
        }
        return asset
    }

    /// 下载、校验 SHA256、解压并试运行，全部通过后才替换升级内核。
    static func install(_ asset: CoreAsset) async throws -> CoreBinary {
        var request = URLRequest(url: asset.url, timeoutInterval: 120)
        request.setValue("Lockgate", forHTTPHeaderField: "User-Agent")
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CoreError("内核下载失败。") }
        guard sha256(of: downloaded) == asset.sha256 else { throw CoreError("内核文件校验值不一致，已放弃升级。") }

        let directory = userCore.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent("mihomo.new")
        try? FileManager.default.removeItem(at: staging)
        guard FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o700]),
              let output = FileHandle(forWritingAtPath: staging.path) else { throw CoreError("无法写入内核文件。") }
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzip.arguments = ["-c", downloaded.path]
        gunzip.standardOutput = output
        gunzip.standardError = FileHandle.nullDevice
        try gunzip.run()
        gunzip.waitUntilExit()
        try? output.close()
        guard gunzip.terminationStatus == 0, version(of: staging) == asset.version else {
            try? FileManager.default.removeItem(at: staging)
            throw CoreError("下载的内核无法运行或版本不符，已放弃升级。")
        }
        _ = try FileManager.default.replaceItemAt(userCore, withItemAt: staging)
        return CoreBinary(url: userCore, version: asset.version, bundled: false)
    }

    static func removeUpgraded() {
        try? FileManager.default.removeItem(at: userCore)
    }
}
