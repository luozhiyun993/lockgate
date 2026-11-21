import SwiftUI
import LockgateCore

struct ProxyCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

private struct ProxyErrorBanner: View {
    @ObservedObject var proxy: ProxyModel

    var body: some View {
        if let error = proxy.error {
            HStack(alignment: .top) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer()
                Button("关闭") { proxy.error = nil }.buttonStyle(.link)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// 「代理」页：内核启停、接管方式、节点选择、内核版本与日志。
struct ProxyPage: View {
    @ObservedObject var proxy: ProxyModel
    let protectionEnabled: Bool
    @State private var portText = ""
    @State private var showLogs = false
    @State private var confirmRevoke = false

    var body: some View {
        Group {
            ProxyErrorBanner(proxy: proxy)
            ProxyCard(title: "内置代理", icon: "bolt.horizontal.circle") {
                HStack(spacing: 12) {
                    Circle().fill(proxy.running ? Color.green : Color.secondary).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(proxy.statusSummary).font(.system(size: 16, weight: .medium))
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if proxy.busy { ProgressView().controlSize(.small) }
                    if proxy.running {
                        Button("停止代理") { Task { await proxy.stop() } }.disabled(proxy.busy)
                    } else {
                        Button("启动代理") { Task { await proxy.start() } }
                            .buttonStyle(.borderedProminent).disabled(proxy.busy || proxy.settings.active == nil)
                    }
                }
                if proxy.settings.active == nil {
                    Text("还没有订阅。请先到「订阅」页添加。").font(.caption).foregroundStyle(.secondary)
                }
                if !proxy.running, proxy.systemProxyApplied {
                    HStack {
                        Text("系统代理仍指向 Lockgate 的端口，当前无法联网。").font(.caption).foregroundStyle(.orange)
                        Button("关闭系统代理") { proxy.setSystemProxy(false) }.controlSize(.small)
                    }
                }
                if protectionEnabled {
                    Label("保护已启用：启停代理、切换系统代理 / TUN 或端口都会改变网络路径，会触发急停并锁定，之后需要手动解锁。",
                          systemImage: "lock.shield").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ProxyCard(title: "接管方式", icon: "arrow.triangle.branch") {
                Toggle("系统代理", isOn: Binding(get: { proxy.settings.systemProxy }, set: { proxy.setSystemProxy($0) }))
                    .disabled(proxy.busy)
                Text("把 macOS 的 HTTP / HTTPS / SOCKS 代理指向内置代理，只绕过本机和局域网地址。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("TUN 模式", isOn: Binding(get: { proxy.settings.tun }, set: { proxy.setTun($0) }))
                    .disabled(proxy.busy)
                Text("接管全部系统流量，包括不遵循系统代理的命令行程序。首次开启需要输入一次管理员密码，之后不再询问。")
                    .font(.caption).foregroundStyle(.secondary)
                if proxy.tunAuthorized {
                    HStack {
                        Text("已安装 TUN 特权内核：/Library/Application Support/Lockgate/core/mihomo")
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("移除授权…") { confirmRevoke = true }.controlSize(.small)
                            .disabled(proxy.busy || (proxy.running && proxy.settings.tun))
                    }
                }
                Divider()
                HStack {
                    Text("代理模式").frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(get: { proxy.settings.mode }, set: { proxy.setMode($0) })) {
                        ForEach(ProxyMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240).disabled(proxy.gateStatus != .off)
                    if proxy.gateStatus != .off {
                        Text("内核阻断开启时固定为规则模式。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("混合端口").frame(width: 80, alignment: .leading)
                    TextField("17890", text: $portText).textFieldStyle(.roundedBorder).frame(width: 90)
                    Button("应用") { if let port = Int(portText) { proxy.setPort(port) } else { proxy.error = "端口需为数字。" } }
                        .disabled(proxy.busy || Int(portText) == proxy.settings.mixedPort)
                    Text("HTTP 与 SOCKS5 共用，仅监听 127.0.0.1。").font(.caption).foregroundStyle(.secondary)
                }
            }

            if proxy.running {
                ProxyCard(title: "节点", icon: "point.3.connected.trianglepath.dotted") {
                    if proxy.snapshot.groups.isEmpty {
                        Text("当前订阅没有策略组。").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(proxy.snapshot.groups) { group in
                        ProxyGroupRow(proxy: proxy, group: group)
                        if group.id != proxy.snapshot.groups.last?.id { Divider() }
                    }
                }
            }

            ProxyCard(title: "内核版本", icon: "shippingbox") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(coreTitle).font(.system(size: 14, weight: .medium))
                        if let bundled = proxy.bundledVersion {
                            Text("内嵌版本 \(bundled)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if proxy.coreBusy { ProgressView().controlSize(.small) }
                    if let latest = proxy.latest {
                        Button(proxy.core == nil ? "下载 \(latest.version)" : "升级到 \(latest.version)") { proxy.upgradeCore() }
                            .buttonStyle(.borderedProminent).disabled(proxy.coreBusy || proxy.busy)
                    }
                    Button("检查更新") { proxy.checkUpdate() }.disabled(proxy.coreBusy)
                    if proxy.core?.bundled == false, proxy.bundledVersion != nil {
                        Button("恢复内嵌版本") { proxy.restoreBundledCore() }.disabled(proxy.coreBusy || proxy.busy)
                    }
                }
                if let message = proxy.coreMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("升级包来自 mihomo 官方 GitHub Release，下载后校验 SHA256 并试运行，通过才会替换。代理运行中升级会重启内核；TUN 模式下需要重新输入管理员密码。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            ProxyCard(title: "内核日志", icon: "text.alignleft") {
                DisclosureGroup(showLogs ? "收起" : "显示最近 \(min(proxy.logs.count, 60)) 行", isExpanded: $showLogs) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(proxy.logs.suffix(60).enumerated()), id: \.offset) { entry in
                            Text(entry.element).font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
        }
        .onAppear {
            portText = String(proxy.settings.mixedPort)
            Task { await proxy.refresh() }
        }
        .onChange(of: proxy.settings.mixedPort) { portText = String($0) }
        .alert("移除 TUN 授权？", isPresented: $confirmRevoke) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) { proxy.revokeTunAuthorization() }
        } message: {
            Text("会删除系统目录中带 root 权限的 mihomo 内核，需要输入管理员密码。之后再开启 TUN 模式需要重新授权。")
        }
    }

    private var detail: String {
        guard let subscription = proxy.settings.active else { return "未选择订阅" }
        return "订阅「\(subscription.name)」 · 端口 \(proxy.settings.mixedPort)"
    }

    private var coreTitle: String {
        guard let core = proxy.core else { return "未找到 mihomo 内核，请点击「检查更新」下载。" }
        return "mihomo \(core.version) · \(core.bundled ? "内嵌" : "已升级")"
    }
}

private struct ProxyGroupRow: View {
    @ObservedObject var proxy: ProxyModel
    let group: ProxyGroup
    @State private var expanded = false

    private func delayText(_ name: String) -> String {
        proxy.snapshot.delays[name].map { "\($0) ms" } ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption)
                        Text(group.name).font(.system(size: 13, weight: .medium))
                        Text(group.typeTitle).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        Text(group.now.isEmpty ? "\(group.all.count) 个节点" : "\(group.now)  \(delayText(group.now))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
                if proxy.testing.contains(group.name) { ProgressView().controlSize(.small) }
                Button("测速") { proxy.testDelay(group: group.name) }.controlSize(.small)
                    .disabled(proxy.testing.contains(group.name))
            }
            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                    ForEach(group.all, id: \.self) { node in
                        Button { proxy.select(group: group.name, node: node) } label: {
                            HStack {
                                Text(node).lineLimit(1).font(.system(size: 12))
                                Spacer()
                                Text(delayText(node)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }.padding(.horizontal, 10).padding(.vertical, 7)
                                .background(node == group.now ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                                            in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7)
                                    .stroke(node == group.now ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!group.selectable)
                    }
                }
            }
        }
    }
}

/// 「订阅」页：添加、更新、切换和删除订阅。
struct SubscriptionPage: View {
    @ObservedObject var proxy: ProxyModel
    @State private var name = ""
    @State private var url = ""
    @State private var removing: Subscription?

    var body: some View {
        Group {
            ProxyErrorBanner(proxy: proxy)
            ProxyCard(title: "添加订阅", icon: "plus.circle") {
                HStack {
                    TextField("名称（可留空）", text: $name).textFieldStyle(.roundedBorder).frame(width: 170)
                    TextField("订阅地址 https://…", text: $url).textFieldStyle(.roundedBorder)
                    if proxy.adding { ProgressView().controlSize(.small) }
                    Button("添加") {
                        proxy.addSubscription(name: name, url: url)
                        name = ""
                        url = ""
                    }.buttonStyle(.borderedProminent)
                        .disabled(proxy.adding || url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("支持 Clash / mihomo 配置订阅（沿用其中的策略组和规则），以及只含节点分享链接的订阅（由 Lockgate 生成「除本机和局域网外全部走代理」的规则）。订阅地址通常带有令牌，只保存在本机，界面和事件记录只显示主机名。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            ProxyCard(title: "我的订阅", icon: "list.bullet.rectangle") {
                if proxy.settings.subscriptions.isEmpty {
                    Text("还没有订阅。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(proxy.settings.subscriptions) { subscription in
                    row(subscription)
                    if subscription.id != proxy.settings.subscriptions.last?.id { Divider() }
                }
            }

            ProxyCard(title: "自动更新", icon: "clock.arrow.2.circlepath") {
                Picker("更新间隔", selection: Binding(get: { proxy.settings.autoUpdateHours }, set: { proxy.setAutoUpdateHours($0) })) {
                    Text("关闭").tag(0)
                    Text("每 6 小时").tag(6)
                    Text("每 12 小时").tag(12)
                    Text("每天").tag(24)
                    Text("每 3 天").tag(72)
                }.frame(width: 260)
                Text("仅在 Lockgate 运行时更新。正在使用的订阅更新后会让内核重新读取配置，现有连接会断开重连。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("删除订阅？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("删除", role: .destructive) {
                if let removing { proxy.removeSubscription(removing.id) }
                removing = nil
            }
        } message: { Text("会删除「\(removing?.name ?? "")」及其已下载的节点配置。") }
    }

    private func row(_ subscription: Subscription) -> some View {
        let active = subscription.id == proxy.settings.activeSubscription
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color.green : Color.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(subscription.name).font(.system(size: 13, weight: .medium))
                    Text(subscription.kind == .profile ? "完整配置" : "节点列表").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Text(meta(subscription)).font(.caption).foregroundStyle(.secondary)
                if let usage = subscription.usage?.summary, !usage.isEmpty {
                    Text(usage).font(.caption).foregroundStyle(.secondary)
                }
                if let error = subscription.lastError {
                    Text("上次更新失败：\(error)").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if proxy.updating.contains(subscription.id) { ProgressView().controlSize(.small) }
            if !active {
                Button("使用") { proxy.activate(subscription.id) }.disabled(proxy.busy)
            }
            Button("更新") { Task { await proxy.updateSubscription(subscription.id) } }
                .disabled(proxy.updating.contains(subscription.id))
            Button("删除", role: .destructive) { removing = subscription }
        }.padding(.vertical, 4)
    }

    private func meta(_ subscription: Subscription) -> String {
        let updated = subscription.updatedAt.map { "更新于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未更新"
        return "\(subscription.displayHost) · \(updated)"
    }
}

struct ProxySidebarStatus: View {
    @ObservedObject var proxy: ProxyModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(proxy.running ? Color.green : Color.secondary).frame(width: 6, height: 6)
            Text(proxy.statusSummary).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// 菜单栏中的代理开关。
struct ProxyMenuItems: View {
    @ObservedObject var proxy: ProxyModel

    var body: some View {
        Text("代理：\(proxy.statusSummary)")
        if proxy.running {
            Button("停止代理") { Task { await proxy.stop() } }.disabled(proxy.busy)
        } else {
            Button("启动代理") { Task { await proxy.start() } }.disabled(proxy.busy || proxy.settings.active == nil)
        }
        Toggle("系统代理", isOn: Binding(get: { proxy.settings.systemProxy }, set: { proxy.setSystemProxy($0) }))
            .disabled(proxy.busy)
        Toggle("TUN 模式", isOn: Binding(get: { proxy.settings.tun }, set: { proxy.setTun($0) }))
            .disabled(proxy.busy)
    }
}
