import SwiftUI
import LockgateCore

/// 「外部资源」：地理数据库的下载地址、数据模式和更新方式。
struct GeoResourcesCard: View {
    @ObservedObject var proxy: ProxyModel
    @State private var draft = GeoSettings()
    @State private var intervalText = "24"

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var edited: GeoSettings {
        var value = draft
        value.intervalHours = Int(intervalText.trimmingCharacters(in: .whitespaces)) ?? 0
        return value
    }

    var body: some View {
        ProxyCard(title: "外部资源", icon: "globe.asia.australia") {
            Text("规则里的 GEOIP、GEOSITE、IP-ASN 要查这些数据库才知道某个 IP 属于哪个国家、某个域名属于哪类网站。只有规则用到的数据库才会被加载和更新。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            field("GeoIP 数据库", text: $draft.geoip)
            field("GeoSite 数据库", text: $draft.geosite)
            field("MMDB 数据库", text: $draft.mmdb)
            field("ASN 数据库", text: $draft.asn)
            HStack {
                Text("GeoData 数据模式").frame(width: 130, alignment: .leading)
                Picker("", selection: $draft.datMode) {
                    Text("db").tag(false)
                    Text("dat").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
                Text(draft.datMode ? "GEOIP 规则使用 GeoIP.dat（未内置，首次使用时由内核下载）" : "GEOIP 规则使用 MMDB（已内置）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("自动更新", isOn: $draft.autoUpdate)
                Spacer()
                Text("更新间隔（小时）").foregroundStyle(draft.autoUpdate ? Color.primary : Color.secondary)
                TextField("24", text: $intervalText).textFieldStyle(.roundedBorder).frame(width: 64)
                    .disabled(!draft.autoUpdate)
            }
            HStack(spacing: 10) {
                Button("保存") { proxy.applyGeo(edited) }
                    .buttonStyle(.borderedProminent).disabled(edited == proxy.settings.geo)
                Button("恢复默认") {
                    draft = GeoSettings()
                    intervalText = "24"
                }.disabled(edited == GeoSettings())
                Spacer()
                if proxy.geoUpdating { ProgressView().controlSize(.small) }
                Button { proxy.updateGeoData() } label: { Label("立即更新", systemImage: "arrow.clockwise") }
                    .disabled(!proxy.running || proxy.geoUpdating || edited != proxy.settings.geo)
            }
            if let message = proxy.geoMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !proxy.running {
                Text("下载由内核完成，启动代理后才能立即更新；自动更新也只在代理运行期间进行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if proxy.geoFiles.isEmpty {
                Text("本机还没有地理数据库文件。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(proxy.geoFiles) { file in
                HStack {
                    Text(file.title).font(.caption.weight(.medium)).frame(width: 60, alignment: .leading)
                    Text(file.name).font(.caption.monospaced())
                    Spacer()
                    Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(Self.date.string(from: file.modified))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            reset()
            proxy.refreshGeoFiles()
        }
        .onChange(of: proxy.settings.geo) { _ in reset() }
        .onChange(of: proxy.running) { _ in proxy.refreshGeoFiles() }
    }

    private func reset() {
        draft = proxy.settings.geo
        intervalText = String(proxy.settings.geo.intervalHours)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).frame(width: 130, alignment: .leading)
            TextField("https://…", text: text).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
        }
    }
}
