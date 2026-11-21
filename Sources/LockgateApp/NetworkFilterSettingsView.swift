import SwiftUI
import LockgateCore

struct NetworkFilterSettingsView: View {
    @Binding var preferences: NetworkFilterPreferences
    @ObservedObject var proxy: ProxyModel

    private var addresses: Binding<String> {
        Binding(get: { preferences.addresses.joined(separator: "\n") }, set: { text in
            preferences.addresses = text.components(separatedBy: .newlines)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("启用网络阻断（通过内置代理）", isOn: $preferences.gateEnabled)
            Label(proxy.gateStatus.summary, systemImage: proxy.gateAllowing ? "network.badge.shield.half.filled" : "info.circle")
                .font(.caption).foregroundStyle(proxy.gateAllowing ? .green : (proxy.gateStatus == .off ? .secondary : .orange))
                .fixedSize(horizontal: false, vertical: true)
            Text("由内置的 mihomo 内核拒绝访问下列地址的连接：保护启用后，锁定期间或检查尚未通过时一律拒绝，检查通过并解锁后才放行；暂停保护时不拦截。对所有经过内置代理的应用生效，不区分进程。需要内置代理正在运行并已开启系统代理或 TUN 模式；开启后代理固定为规则模式。不经过内置代理的流量（系统代理模式下不走系统代理的程序、Lockgate 退出后）不受它约束。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: addresses).font(.system(.body, design: .monospaced)).frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Button("恢复默认地址") { preferences.addresses = NetworkFilterPreferences.defaultAddresses }
            Text("受保护的地址：每行一个域名、*.子域名或 IP。*.example.com 不包含 example.com 本身。不接受 URL、端口和路径。修改后点击页面底部保存。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
