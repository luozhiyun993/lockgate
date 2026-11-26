import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LockgateCore

private enum Page: String, CaseIterable {
    case overview = "保护概览"
    case settings = "出口与规则"
    case tests = "保护测试"
    case usage = "Token 用量"
    case activity = "事件记录"

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .settings: return "slider.horizontal.3"
        case .tests: return "checkmark.shield"
        case .usage: return "chart.bar"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

struct LockgateView: View {
    @ObservedObject var model: LockgateModel
    @StateObject private var usage = TokenUsageModel()
    @State private var page: Page = .overview
    @State private var draft: LockgateSettings
    @State private var confirmEnable = false
    @State private var confirmPause = false
    @State private var confirmRealTest = false
    @State private var confirmEmergencyStop = false
    @State private var newProbeDomain = ""
    @State private var probeDomainError: String?
    @State private var showBulkDomains = false
    @State private var bulkDomainText = ""
    @State private var bulkDomainMessage: String?
    @State private var reportFeedback: String?
    private let accent = Color(red: 0.13, green: 0.37, blue: 0.78)

    private var mascot: NSImage {
        if let url = Bundle.main.url(forResource: "LockgateMascot", withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        return NSApplication.shared.applicationIconImage
    }

    init(model: LockgateModel) {
        self.model = model
        _draft = State(initialValue: model.state.settings)
    }

    private var statusColor: Color {
        if model.state.lockedReason != nil { return .red }
        if !model.state.enabled { return accent }
        return model.decision.mayLaunch ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page.rawValue).font(.system(size: 26, weight: .semibold))
                        Text(subtitle).foregroundStyle(.secondary).font(.system(size: 13))
                    }
                    Spacer()
                    if page == .overview {
                        if model.checking { ProgressView().controlSize(.small) }
                        Button { model.recheck() } label: {
                            Label("立即检查", systemImage: "arrow.clockwise")
                        }.disabled(model.checking)
                    }
                }.padding(28)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let error = model.savingError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).padding().frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        switch page {
                        case .overview: overview
                        case .settings: settings
                        case .tests: tests
                        case .usage: TokenUsageView(model: usage)
                        case .activity: activity
                        }
                    }.padding(28)
                }
                Divider()
                HStack {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(model.statusTitle)
                    Spacer()
                    Text("本机检查约 2 秒 · 出口检查约 10 秒")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .alert("启用保护与自动急停？", isPresented: $confirmEnable) {
            Button("取消", role: .cancel) {}
            Button("启用保护") { model.enableProtection() }
        } message: {
            Text("确认异常后会终止当前用户选中的 Claude 进程\(customStopHint)，包括从其他入口启动的进程。正在生成的回答或执行中的任务可能中断。网络超时只告警。")
        }
        .alert("暂停保护？", isPresented: $confirmPause) {
            Button("取消", role: .cancel) {}
            Button("暂停保护", role: .destructive) { model.pauseProtection() }
        } message: { Text("暂停后不再执行急停，现有 Claude 会继续运行。已有锁定不会被清除。") }
        .alert("真实测试会关闭 Claude", isPresented: $confirmRealTest) {
            Button("取消", role: .cancel) {}
            Button("确认急停并锁定", role: .destructive) { model.realStopTest() }
        } message: {
            Text("会终止当前用户选中的 Claude Desktop / Code 进程\(customStopHint)，并持续阻止其运行，直到检查通过并手动解锁。请先保存工作。")
        }
        .alert("一键急停全部 Claude？", isPresented: $confirmEmergencyStop) {
            Button("取消", role: .cancel) {}
            Button("立即终止全部 Claude", role: .destructive) { model.emergencyStopAllClaude() }
        } message: {
            Text("会终止当前用户所有已核实的 Claude Desktop / Code 进程\(customStopHint)，不受保护对象勾选限制。未保存的工作可能丢失；无法核实身份的进程不会仅凭名称终止。")
        }
        .alert("Lockgate", isPresented: Binding(get: { !model.notice.isEmpty }, set: { if !$0 { model.notice = "" } })) {
            Button("知道了") { model.notice = "" }
        } message: { Text(model.notice) }
    }

    private var customStopHint: String {
        let count = model.state.settings.customStopApplications.count
        return count == 0 ? "" : "，以及你添加的 \(count) 个自定义软件"
    }

    private func addCustomStopApplications() {
        let panel = NSOpenPanel()
        panel.title = "选择急停时一并关闭的软件"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.application, .unixExecutable]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        draft.customStopApplications = CustomStopTargets.normalized(
            draft.customStopApplications + panel.urls.map(\.path))
    }

    private var subtitle: String {
        switch page {
        case .overview: return "为 Claude 的每次启动与持续运行检查代理环境。"
        case .settings: return "参考地区检查规则，可额外固定一个出口 IP。"
        case .tests: return "先安全演练，再按需验证真实急停。"
        case .usage: return "按 agent、模型与项目查看本机记录的 token 消耗。"
        case .activity: return "查看检测变化、锁定原因与恢复操作。"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 11) {
                Image(nsImage: mascot).resizable().interpolation(.high)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AGENT").font(.system(size: 10, weight: .bold)).tracking(2)
                    Text("Lockgate").font(.system(size: 21, weight: .semibold))
                }
            }.padding(.top, 12)
            VStack(spacing: 7) {
                ForEach(Page.allCases, id: \.self) { item in
                    Button { page = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .foregroundStyle(page == item ? accent : Color.primary)
                            .background(page == item ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            // 透明背景不参与点击判定，显式把整行设为可点击区域。
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label("系统网络检测", systemImage: "network").font(.system(size: 12, weight: .medium))
                Text("macOS · 隧道 / HTTPS 代理").font(.system(size: 11)).foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
                Text("关闭窗口后仍在菜单栏运行。\n退出应用会停止保护。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            }
        }.padding(20).frame(width: 184).frame(maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private var overview: some View {
        Group {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 15) {
                    if model.state.lockedReason != nil {
                        Image(systemName: "lock.shield.fill").font(.system(size: 38)).foregroundStyle(statusColor)
                    } else {
                        Image(nsImage: mascot).resizable().interpolation(.high)
                            .frame(width: 58, height: 58)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text(model.statusTitle).font(.system(size: 27, weight: .semibold))
                        Text(model.statusDetail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Text(model.state.enabled ? "ACTIVE" : "OBSERVE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(statusColor.opacity(0.10), in: Capsule()).foregroundStyle(statusColor)
                }
                HStack(spacing: 12) {
                    Button { confirmEmergencyStop = true } label: {
                        Label("一键急停全部 Claude", systemImage: "octagon.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(model.stopping)
                    if model.state.enabled {
                        Button("暂停保护") { confirmPause = true }
                    } else {
                        Button("启用保护") { confirmEnable = true }.buttonStyle(.borderedProminent)
                    }
                    if model.state.lockedReason != nil {
                        Button("重新检查并解锁") { model.recover() }
                            .disabled(!model.state.enabled || model.checking || model.stopping)
                    }
                    if model.stopping { ProgressView().controlSize(.small); Text("正在急停…").font(.caption) }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(statusColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(statusColor.opacity(0.18), lineWidth: 1))

            HStack(alignment: .top, spacing: 16) {
                card("代理与隧道", icon: "network") {
                    Text(model.networkStatus.summary).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Text(model.networkGuidance)
                        .font(.caption).foregroundStyle(.secondary)
                }
                card("当前出口", icon: "globe.asia.australia") {
                    if let observation = model.currentObservation {
                        Text(observation.ip).font(.system(size: 17, weight: .medium, design: .monospaced)).textSelection(.enabled)
                        Text("地区 \(observation.country)  /  目标 \(model.state.settings.country)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("暂时无法确认").font(.system(size: 16, weight: .medium))
                        Text("网络超时不会关闭正在运行的 Claude。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let checked = model.lastChecked {
                        Text("最近检查 \(checked.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            domainExitCard

            card("进程检查", icon: "app.badge.checkmark") {
                Text(model.processStatus.summary)
                    .font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text("仅监测当前用户的 Claude Desktop / Code。其他软件的 Node 进程不会阻断检查；网络异常时终止已核实的 Claude 目标，少数目标无法核实时单独提示。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            card("受保护的启动", icon: "play.shield") {
                HStack(spacing: 12) {
                    Button { model.launchDesktop() } label: { Label("启动 Claude Desktop", systemImage: "macwindow") }
                        .disabled(!model.state.enabled || model.state.lockedReason != nil || !model.state.settings.protectDesktop || model.checking)
                    Button { model.launchCLI() } label: { Label("启动 Claude Code", systemImage: "terminal") }
                        .disabled(!model.state.enabled || model.state.lockedReason != nil || !model.state.settings.protectCLI || model.checking)
                }
                Text("每次启动前重新检查网络、出口与进程状态，终端执行前再次校验。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Label("进程级保护存在检测窗口；出口探针不代表所有域名或 IPv6 路径都已验证。", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var domainExitCard: some View {
        card("分域名出口", icon: "point.3.connected.trianglepath.dotted") {
            Text("按代理分流规则分别访问各域名的 /cdn-cgi/trace，显示该域名看到的出口 IP。只有接入 Cloudflare 的域名能回显 IP，其他域名只显示能否连接与延迟；只做诊断，不参与门禁判定。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(model.probeDomains, id: \.self) { domain in
                    domainExitRow(domain)
                    if domain != model.probeDomains.last { Divider() }
                }
            }
            HStack(spacing: 10) {
                TextField("添加域名，多个用逗号或空格分隔", text: $newProbeDomain)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    .onSubmit(addProbeDomain)
                Button("添加", action: addProbeDomain)
                    .disabled(newProbeDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("批量添加…") { bulkDomainMessage = nil; showBulkDomains = true }
                    .popover(isPresented: $showBulkDomains, arrowEdge: .bottom) { bulkDomainEditor }
                Button("添加推荐域名") { probeDomainError = model.addRecommendedProbeDomains() }
                    .help("补充 Claude 相关的常用域名（与 cleanip.io/claude 检测的清单一致），不会删除已有域名")
                Spacer()
                if model.probingDomains { ProgressView().controlSize(.small) }
                Button { Task { await model.probeDomainExits() } } label: {
                    Label("检测", systemImage: "arrow.clockwise")
                }.disabled(model.probingDomains || model.probeDomains.isEmpty)
            }
            if let error = probeDomainError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let note = model.domainProbeNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            if let checked = model.domainsCheckedAt {
                Text("最近检测 \(checked.formatted(date: .omitted, time: .standard)) · 启动时自动检测一次，之后手动触发")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func domainExitRow(_ domain: String) -> some View {
        HStack(spacing: 12) {
            Text(domain).font(.system(size: 13, design: .monospaced))
                .lineLimit(1).truncationMode(.middle).frame(width: 190, alignment: .leading)
            switch model.domainExits[domain]?.outcome {
            case .observed(let observation):
                Text(observation.ip).font(.system(size: 13, weight: .medium, design: .monospaced)).textSelection(.enabled)
                Text(observation.country).font(.caption)
                    .foregroundStyle(observation.country == model.state.settings.country ? Color.secondary : Color.red)
                if let main = model.currentObservation?.ip {
                    let same = main == observation.ip
                    Text(same ? "与当前出口一致" : "与当前出口不同")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background((same ? Color.green : Color.orange).opacity(0.12), in: Capsule())
                        .foregroundStyle(same ? Color.green : Color.orange)
                }
            case .reachable:
                Text("可连接 · 未接入 Cloudflare，无法回显出口 IP").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            case .unreachable:
                Text("连接失败或超时").font(.caption).foregroundStyle(.orange)
            case .invalidDomain:
                Text("域名格式无效").font(.caption).foregroundStyle(.orange)
            case nil:
                Text(model.probingDomains ? "检测中…" : "未检测").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let latency = model.domainExits[domain]?.latency {
                Text("约 \(Int((latency * 1000).rounded())) ms").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("单次请求耗时，含经代理建立 TLS 连接的时间")
            }
            Button { model.removeProbeDomain(domain) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("移除")
        }.padding(.vertical, 7)
    }

    private var bulkDomainEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("批量添加域名").font(.system(size: 13, weight: .semibold))
            Text("每行一个，也可以用空格、逗号或分号分隔；可以直接粘贴网址，会自动取域名。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $bulkDomainText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15), lineWidth: 1))
            if let message = bulkDomainMessage {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { showBulkDomains = false }.keyboardShortcut(.cancelAction)
                Button("添加") {
                    let result = model.addProbeDomains(bulkDomainText)
                    bulkDomainMessage = result.message
                    // 格式无效的条目留在输入框里方便修改；全部有效时关闭。
                    bulkDomainText = result.invalid.joined(separator: "\n")
                    if result.invalid.isEmpty { showBulkDomains = false; probeDomainError = result.message }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bulkDomainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16).frame(width: 380)
    }

    private func addProbeDomain() {
        let result = model.addProbeDomains(newProbeDomain)
        probeDomainError = result.message
        newProbeDomain = result.invalid.joined(separator: ", ")
    }

    private var settings: some View {
        Group {
            card("目标地区", icon: "globe") {
                HStack {
                    Text("国家 / 地区代码").frame(width: 125, alignment: .leading)
                    TextField("JP", text: $draft.country).textFieldStyle(.roundedBorder).frame(width: 80)
                        .onChange(of: draft.country) { draft.country = $0.uppercased() }
                    Menu("常用地区") {
                        ForEach(["JP", "US", "SG", "GB", "DE", "CA", "AU", "KR", "TW"], id: \.self) { code in
                            Button(code) { draft.country = code }
                        }
                    }.frame(width: 110)
                }
                Text("与参考项目一致：使用 Cloudflare trace 返回的地区。地区定位可能有误差，不代表 Claude 的地区判断。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("网络路径自动识别", icon: "network") {
                Text("支持将系统流量接入隧道的 VPN / TUN，以及 macOS 静态 HTTPS 代理。Lockgate 只检测，不修改代理设置，代理由你自己的代理客户端提供。")
                    .font(.system(size: 13))
                Text("PAC、仅 SOCKS 和无法确认的配置会阻止新的受管启动。系统代理模式下，Claude Code 需从本应用启动以继承检测到的代理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("指定出口 IP", icon: "pin") {
                Toggle("启用严格 IP 匹配", isOn: $draft.pinEnabled)
                HStack {
                    TextField("例如 203.0.113.10（请填写你的实际公网 IP）", text: $draft.pinnedIP)
                        .textFieldStyle(.roundedBorder).disabled(!draft.pinEnabled)
                    Button("使用当前出口") {
                        if let observation = model.currentObservation {
                            draft.pinnedIP = observation.ip
                            draft.pinEnabled = true
                        }
                    }.disabled(model.currentObservation == nil || Date().timeIntervalSince(model.currentObservation?.timestamp ?? .distantPast) > 25)
                }
                Text("留在未启用状态时，同地区 IP 变化只提醒。启用后地址必须一致，自动检测不会覆盖这里的设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("保护对象", icon: "app.badge.checkmark") {
                Toggle("Claude Desktop", isOn: $draft.protectDesktop)
                Toggle("Claude Code", isOn: $draft.protectCLI)
                Text("仅处理当前用户匹配到的 Claude 进程。锁定期间从其他入口启动，也会在巡检后终止。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("急停时一并关闭的软件", icon: "xmark.app") {
                Text("急停与锁定期间，除 Claude 外还会终止这里列出的软件，例如浏览器或其他需要走代理的客户端。只影响急停，不参与启动门禁检查。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(draft.customStopApplications, id: \.self) { path in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: (path as NSString).expandingTildeInPath))
                            .resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(FileManager.default.displayName(atPath: (path as NSString).expandingTildeInPath))
                                .font(.system(size: 13, weight: .medium))
                            Text(path).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { draft.customStopApplications.removeAll { $0 == path } } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).help("移除")
                    }
                }
                Button { addCustomStopApplications() } label: { Label("添加软件…", systemImage: "plus") }
                    .disabled(draft.customStopApplications.count >= CustomStopTargets.limit)
                Text("应用会连同其辅助进程一起关闭，未保存的内容可能丢失。锁定解除前重新打开也会被再次关闭。修改后需点击「保存并重新检查」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card("安装位置（可选）", icon: "folder") {
                Text("默认自动发现安装位置；自定义目录、命令别名或特殊版本管理器可填写路径。监测与启动使用相同的发现结果。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Claude Desktop .app 路径，留空自动发现", text: $draft.desktopApplicationPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Claude Code 可执行命令路径，留空自动发现", text: $draft.cliExecutablePath)
                    .textFieldStyle(.roundedBorder)
                Text("Desktop 会核对应用标识；CLI 路径仅填写可信的 Claude 安装入口。支持绝对路径和 ~/。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("保存并重新检查") { model.saveSettings(draft) }.buttonStyle(.borderedProminent)
                    .disabled(draft.validationError != nil || model.stopping || model.savingSettings)
                if let error = draft.validationError { Text(error).font(.caption).foregroundStyle(.orange) }
                Spacer()
            }
            Text("保护已锁定时，保存会按新规则完整重新检查网络、出口与进程，全部通过才解除锁定，否则保持锁定并显示新的原因。启动或解锁时若无法确认出口，门禁保持关闭。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tests: some View {
        Group {
            card("安全模拟演练", icon: "testtube.2") {
                Text("使用独立的模拟状态，验证与真实保护相同的判定逻辑。不会关闭任何进程，也不会更改真实锁定。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(["网络超时", "地区漂移", "IP 不匹配", "代理退出"], id: \.self) { scenario in
                        Button { model.simulate(scenario) } label: {
                            Label(scenario, systemImage: "play.circle").frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                    }
                }
                if !model.simulationOutput.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.simulationOutput.enumerated()), id: \.offset) { entry in
                            Text(entry.element).font(.system(size: 12, design: .monospaced))
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            card("真实急停测试", icon: "exclamationmark.shield") {
                Text("关闭选中的真实 Claude 进程并进入锁定。用于验证进程识别、终止权限和手动恢复，不验证真实网络故障。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button("测试真实急停…", role: .destructive) { confirmRealTest = true }
                    .disabled(!model.state.enabled || model.stopping)
                if !model.state.enabled { Text("先在保护概览中启用保护。").font(.caption).foregroundStyle(.secondary) }
            }
            card("手动验收顺序", icon: "list.number") {
                Text("1. 先演练网络超时，确认结果为保留运行。\n2. 演练地区漂移与 IP 不匹配，确认锁定保持。\n3. 保存工作后执行真实急停测试。\n4. 返回概览，检查并解锁，再通过门禁启动。")
                    .font(.system(size: 13)).lineSpacing(7)
            }
        }
    }

    private var activity: some View {
        Group {
            card("发送给开发者", icon: "square.and.arrow.up") {
                Text("复制或导出为纯文本，包含当前状态摘要和下方全部事件，可直接粘贴到聊天或 Issue。出口 IP 只保留前两段，用户目录路径以 ~ 代替；不含账号、密码或订阅信息。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { copyDiagnosticReport() } label: { Label("复制全部", systemImage: "doc.on.doc") }
                    Button { exportDiagnosticReport() } label: { Label("导出为文件…", systemImage: "square.and.arrow.down") }
                    if let feedback = reportFeedback {
                        Text(feedback).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            eventList
        }
    }

    private func copyDiagnosticReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.diagnosticReport(), forType: .string)
        reportFeedback = "已复制 \(model.events.count) 条事件和状态摘要。"
    }

    private func exportDiagnosticReport() {
        let panel = NSSavePanel()
        panel.title = "导出 Lockgate 诊断记录"
        panel.allowedContentTypes = [.plainText]
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        panel.nameFieldStringValue = "Lockgate-诊断记录-\(stamp).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.diagnosticReport().write(to: url, atomically: true, encoding: .utf8)
            reportFeedback = "已导出到 \(url.lastPathComponent)。"
        } catch {
            reportFeedback = "导出失败：\(error.localizedDescription)"
        }
    }

    private var eventList: some View {
        card("最近 200 条事件", icon: "clock") {
            ForEach(model.events) { event in
                HStack(alignment: .top, spacing: 18) {
                    Text(event.time.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
                    Text(event.text).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.padding(.vertical, 6)
                if event.id != model.events.last?.id { Divider() }
            }
        }
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        LockgateCard(title: title, icon: icon, content: content)
    }
}

struct LockgateCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
