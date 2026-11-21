import AppKit
import SwiftUI
import LockgateCore

/// 等宽、不做智能引号和自动更正的文本编辑器。系统的自动替换会把代码里的引号和连字符改掉。
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isRichText = false
        view.isEditable = editable
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.textContainerInset = NSSize(width: 6, height: 8)
        view.string = text
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

/// 只读查看的一份配置。
struct ConfigDocument: Identifiable {
    let id = UUID()
    let title: String
    let note: String
    let text: String
}

struct ConfigViewer: View {
    let document: ConfigDocument
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(document.title).font(.headline)
            Text(document.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            CodeEditor(text: .constant(document.text), editable: false)
            HStack {
                Text("\(document.text.split(separator: "\n", omittingEmptySubsequences: false).count) 行 · 只读")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "已复制" : "复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.text, forType: .string)
                    copied = true
                }
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(minWidth: 760, minHeight: 560)
    }
}

/// 「查看最终配置」按钮：生成或读取合并后的配置并弹出查看。
struct FinalConfigButton: View {
    @ObservedObject var proxy: ProxyModel
    @State private var document: ConfigDocument?
    @State private var loading = false

    var body: some View {
        HStack(spacing: 8) {
            Button { load() } label: { Label("查看最终配置", systemImage: "doc.text.magnifyingglass") }
                .disabled(loading || proxy.settings.active == nil)
            if loading { ProgressView().controlSize(.small) }
        }
        .sheet(item: $document) { item in ConfigViewer(document: item) { document = nil } }
    }

    private func load() {
        loading = true
        Task {
            defer { loading = false }
            do {
                let result = try await proxy.finalConfig()
                let name = proxy.settings.active?.name ?? ""
                document = ConfigDocument(
                    title: result.live ? "最终配置 · 内核正在使用" : "最终配置 · 预览",
                    note: (result.live ? "订阅「\(name)」加上已启用的覆写和 Lockgate 接管项之后，内核当前实际加载的配置。"
                           : "代理没有运行。这是按订阅「\(name)」、已启用的覆写和当前设置生成的预览，启动后控制端口和密钥会重新生成。")
                        + "已整理成 YAML，控制接口密钥已隐藏；其中包含节点的服务器地址和密码，分享前请留意。",
                    text: result.text)
            } catch { proxy.error = "无法查看最终配置：\(error.localizedDescription)" }
        }
    }
}

private struct OverrideDraft: Identifiable {
    let id: UUID
    let kind: OverrideKind
    var name: String
    var content: String
}

/// 「覆写」页：管理 YAML 覆写和脚本覆写。
struct OverridePage: View {
    @ObservedObject var proxy: ProxyModel
    @State private var draft: OverrideDraft?
    @State private var removing: OverrideItem?

    var body: some View {
        Group {
            if let error = proxy.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Spacer()
                    Button("关闭") { proxy.error = nil }.buttonStyle(.link)
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            ProxyCard(title: "覆写列表", icon: "wand.and.stars") {
                if proxy.settings.overrides.isEmpty {
                    Text("还没有覆写。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(proxy.settings.overrides.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index)
                    Divider()
                }
                HStack {
                    Button { create(.yaml) } label: { Label("新建 YAML 覆写", systemImage: "doc.badge.plus") }
                    Button { create(.script) } label: { Label("新建脚本覆写", systemImage: "curlybraces") }
                    FinalConfigButton(proxy: proxy)
                    Spacer()
                    if proxy.busy { ProgressView().controlSize(.small) }
                    if let message = proxy.overrideMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !proxy.overrideLogs.isEmpty {
                ProxyCard(title: "脚本输出", icon: "text.alignleft") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(proxy.overrideLogs.suffix(100).enumerated()), id: \.offset) { entry in
                            Text(entry.element).font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                    Text("最近一次生成配置时脚本里 console.log 的内容。").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProxyCard(title: "覆写怎么生效", icon: "info.circle") {
                Text("每次生成内核配置时，按列表从上到下依次应用已启用的覆写，对当前使用的任何订阅都生效；订阅更新不会丢失覆写。")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text("YAML 覆写与订阅配置合并，写法与 Clash Party 一致：映射递归合并，其他类型直接替换；`+rules` 把列表插到最前面，`rules+` 追加到最后，`dns!` 整个替换不合并。\n脚本覆写需要定义 function main(config) { return config }，在隔离的 JavaScript 环境里运行，不能访问文件和网络，不支持异步，超过 15 秒会被中止。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("覆写可以修改 DNS、TUN 的细节参数、规则、策略组和节点。代理端口、控制接口、局域网访问、代理模式和 TUN 开关仍由 Lockgate 设定，网络阻断的规则在覆写之后加入，覆写改不了它们。保存时会用内核校验结果；校验不通过时内核继续使用之前的配置。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $draft) { item in
            OverrideEditor(draft: item) { saved in
                proxy.saveOverride(saved.id, name: saved.name, content: saved.content)
                draft = nil
            } cancel: { draft = nil }
        }
        .alert("删除覆写？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("取消", role: .cancel) { removing = nil }
            Button("删除", role: .destructive) {
                if let removing { proxy.removeOverride(removing.id) }
                removing = nil
            }
        } message: { Text("会删除「\(removing?.name ?? "")」及其内容。") }
    }

    private func create(_ kind: OverrideKind) {
        guard let item = proxy.addOverride(kind) else { return }
        draft = OverrideDraft(id: item.id, kind: item.kind, name: item.name, content: proxy.overrideContent(item))
    }

    private func row(_ item: OverrideItem, index: Int) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { item.enabled }, set: { proxy.setOverrideEnabled(item.id, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(proxy.busy)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.name).font(.system(size: 13, weight: .medium))
                    Text(item.kind == .yaml ? "YAML" : "脚本").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Text("第 \(index + 1) 个应用 · 修改于 \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { proxy.moveOverride(item.id, by: -1) } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0 || proxy.busy).help("上移")
            Button { proxy.moveOverride(item.id, by: 1) } label: { Image(systemName: "arrow.down") }
                .disabled(index == proxy.settings.overrides.count - 1 || proxy.busy).help("下移")
            Button("编辑") {
                draft = OverrideDraft(id: item.id, kind: item.kind, name: item.name, content: proxy.overrideContent(item))
            }
            Button("删除", role: .destructive) { removing = item }.disabled(proxy.busy)
        }.padding(.vertical, 4)
    }
}

private struct OverrideEditor: View {
    @State var draft: OverrideDraft
    let save: (OverrideDraft) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft.kind.title).font(.headline)
                TextField("名称", text: $draft.name).textFieldStyle(.roundedBorder).frame(width: 260)
                Spacer()
            }
            CodeEditor(text: $draft.content)
            HStack {
                Text(draft.kind == .yaml ? "YAML 需用空格缩进。" : "需要定义 function main(config) 并返回配置对象。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("保存并应用") { save(draft) }.buttonStyle(.borderedProminent).keyboardShortcut("s")
            }
        }.padding(20).frame(minWidth: 720, minHeight: 520)
    }
}
