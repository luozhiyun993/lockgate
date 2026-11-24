import Foundation
import LockgateCore

let connection = LocalInspector.inspectConnection()
print("代理与路由：\(connection.health.summary)")
let settings = (try? StateStore().load().settings) ?? LockgateSettings()
let inspection = ProcessInspector.inspect(settings: settings)
print("进程检查：\(inspection.health.summary)")
if CommandLine.arguments.contains("--list-processes") {
    for target in inspection.targets {
        print("已识别 PID \(target.pid)：\(target.executable)")
    }
}
let installations = InstallationDiscovery.discover(settings: settings)
print("安装发现：Desktop \(installations.desktopApplications.count) 处 · CLI 命令 \(installations.cliCommands.count) 个 · 原生文件 \(installations.nativeExecutables.count) 个")
if CommandLine.arguments.contains("--list-installations") {
    for app in installations.desktopApplications { print("Desktop 安装：\(app.path)") }
    for command in installations.cliCommands { print("CLI 入口：\(command.path)") }
}
print("Claude Code：\(installations.cliCommands.isEmpty ? "未找到" : "已找到")")
if CommandLine.arguments.contains("--network") {
    let result: ExitHealth
    if let transport = connection.transport {
        result = await ExitInspector.inspect(transport: transport)
    } else {
        result = .unknown("没有可确认的代理或隧道路径，未发送出口请求。")
    }
    switch result {
    case .known(let observation):
        print("出口探针：有效；地区 \(observation.country)；地址默认隐藏")
        if CommandLine.arguments.contains("--show-ip") { print("出口 IP：\(observation.ip)") }
    case .unknown(let reason): print("出口探针：\(reason)")
    }
} else {
    print("未发送网络探测；使用 --network 启用 Cloudflare 出口查询。")
}
if CommandLine.arguments.contains("--usage") {
    let started = Date()
    let summary = await TokenUsageScanner().refresh().summary(prices: PriceTable(directory: StateStore.defaultDirectory))
    print("Token 用量：共 \(summary.total.total)（输入 \(summary.total.input) · 输出 \(summary.total.output) · 缓存读取 \(summary.total.cacheRead) · 缓存写入 \(summary.total.cacheWrite)），\(summary.sessions) 个会话，扫描 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒")
    print("  估算费用：$\(String(format: "%.2f", summary.cost))（按公开 API 标准价，价格表 \(PriceTable.builtInDate)）\(summary.unpriced > 0 ? "，另有 \(summary.unpriced) token 价格未知未计入" : "")")
    for row in summary.agents { print("  \(row.name)：\(row.counts.total)，\(row.sessions) 个会话，$\(String(format: "%.2f", row.cost))") }
    for row in summary.models { print("  模型 \(row.name)：\(row.counts.total)，\(row.unpriced > 0 ? "价格未知" : "$" + String(format: "%.2f", row.cost))") }
    for row in summary.subagents { print("  Claude Code \(row.name.isEmpty ? "主会话" : "子代理 \(row.name)")：\(row.counts.total)") }
}
print("诊断结束：未启动或终止任何 Claude 进程，未更改保护状态。")
