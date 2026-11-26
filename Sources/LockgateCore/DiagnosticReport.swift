import Foundation

/// 把诊断摘要与事件记录拼成便于转发的纯文本。只做格式化与脱敏，不读取任何系统状态。
public enum DiagnosticReport {
    public struct Event {
        public let time: Date
        public let text: String

        public init(time: Date, text: String) {
            self.time = time
            self.text = text
        }
    }

    /// - Parameters:
    ///   - summary: 按顺序输出的「项目：内容」诊断摘要。
    ///   - events: 任意顺序的事件，输出时按时间从早到晚排列。
    ///   - home: 用户主目录；出现在文本中的该路径会替换为 `~`，避免泄露用户名。
    public static func render(summary: [(String, String)], events: [Event], generatedAt: Date = Date(),
                              timeZone: TimeZone = .current, home: String = NSHomeDirectory()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let offset = timeZone.secondsFromGMT(for: generatedAt)
        let zone = String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)

        var lines = ["Lockgate 诊断记录", "生成时间：\(formatter.string(from: generatedAt))（\(zone)，下方事件时间同此时区）", ""]
        lines.append("== 当前状态 ==")
        for (key, value) in summary { lines.append("\(key)：\(value)") }
        lines.append("")
        lines.append("== 事件记录（\(events.count) 条，按时间从早到晚）==")
        for event in events.sorted(by: { $0.time < $1.time }) {
            lines.append("\(formatter.string(from: event.time))  \(event.text)")
        }
        return redactingHome(lines.joined(separator: "\n") + "\n", home: home)
    }

    /// 只保留 IPv4 前两段、IPv6 前两组，例如 `204.141.x.x`；无法识别时返回「已隐藏」。
    public static func maskedIP(_ ip: String) -> String {
        guard let normalized = IPAddress.normalized(ip) else { return "已隐藏" }
        if normalized.contains(":") {
            let groups = normalized.split(separator: ":", omittingEmptySubsequences: false)
            return groups.prefix(2).joined(separator: ":") + ":…"
        }
        let parts = normalized.split(separator: ".")
        guard parts.count == 4 else { return "已隐藏" }
        return "\(parts[0]).\(parts[1]).x.x"
    }

    static func redactingHome(_ text: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard home.count > 1 else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}
