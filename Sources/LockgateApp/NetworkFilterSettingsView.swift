import SwiftUI
import LockgateCore

struct NetworkFilterSettingsView: View {
    @Binding var preferences: NetworkFilterPreferences
    @ObservedObject var controller: NetworkFilterController
    @ObservedObject var proxy: ProxyModel
    let retry: () -> Void

    private var addresses: Binding<String> {
        Binding(get: { preferences.addresses.joined(separator: "\n") }, set: { text in
            preferences.addresses = text.components(separatedBy: .newlines)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("通过内置代理阻断（无需系统扩展）", isOn: $preferences.gateEnabled)
            Label(proxy.gateStatus.summary, systemImage: proxy.gateAllowing ? "network.badge.shield.half.filled" : "info.circle")
                .font(.caption).foregroundStyle(proxy.gateAllowing ? .green : (proxy.gateStatus == .off ? .secondary : .orange))
                .fixedSize(horizontal: false, vertical: true)
            Text("由内置的 mihomo 内核拒绝访问下列地址的连接：保护启用后，锁定期间或检查尚未通过时一律拒绝，检查通过并解锁后才放行；暂停保护时不拦截。对所有经过内置代理的应用生效，不区分进程。需要内置代理正在运行并已开启系统代理或 TUN 模式；开启后代理固定为规则模式。不经过内置代理的流量（系统代理模式下不走系统代理的程序、Lockgate 退出后）不受它约束。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("通过系统扩展阻断（需要签名扩展，保存后申请系统授权）", isOn: $preferences.enabled)
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
