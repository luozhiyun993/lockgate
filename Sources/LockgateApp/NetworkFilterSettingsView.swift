import SwiftUI
import LockgateCore

struct NetworkFilterSettingsView: View {
    @Binding var preferences: NetworkFilterPreferences
    @ObservedObject var controller: NetworkFilterController
    let retry: () -> Void

    private var addresses: Binding<String> {
        Binding(get: { preferences.addresses.joined(separator: "\n") }, set: { text in
            preferences.addresses = text.components(separatedBy: .newlines)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("启用网络阻断（保存后申请系统授权）", isOn: $preferences.enabled)
            Label(controller.status, systemImage: controller.isEffective ? "network.badge.shield.half.filled" : "info.circle")
                .font(.caption).foregroundStyle(controller.isEffective ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)
            if let issue = controller.readiness {
                Text(issue).font(.caption).foregroundStyle(.secondary)
            }
            Text("保护选中的 Claude 进程全部出站连接，包括它连接本机代理的流量。确认代理异常后保持阻断，检查通过并手动恢复后才放行。首次启用前请先关闭已有 Claude 会话，再通过受管入口启动。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("同时保护其他应用访问下列地址的连接", isOn: $preferences.includeOtherApps)
            Text("默认关闭：其他应用正常联网。开启后，浏览器访问列表内的地址也受保护。域名匹配依赖系统提供主机名，无法覆盖所有 DNS / 代理转发方式；新增地址仅保证检查后续新连接。")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: addresses).font(.system(.body, design: .monospaced)).frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("恢复默认地址") { preferences.addresses = NetworkFilterPreferences.defaultAddresses }
                Button("安装 / 重试系统过滤") { retry() }
                    .disabled(!preferences.enabled || controller.busy || controller.readiness != nil)
            }
            Text("每行一个域名、*.子域名或 IP。*.example.com 不包含 example.com 本身。不接受 URL、端口和路径。规则修改后点击页面底部保存。")
                .font(.caption).foregroundStyle(.secondary)
            Text("关闭窗口不停止保护；正常停止保护或退出会先停用过滤。守护失联超过约 8 秒时，扩展会阻断已识别的受保护连接。尚未安装或确认生效时，界面不会显示网络阻断已生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
