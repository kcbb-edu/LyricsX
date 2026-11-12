// LyricsXBridge — 不属于 LyricsX 原本的代码，见 docs/design.md。
// 偏好设置里的「歌詞顯示器」分页：左边分类（一般、每块显示器、中文歌名修正），右边内容。

import AppKit
import LyricsXFoundation
import SwiftUI

enum ESP32BridgePreferences {
    /// 跟 LyricsX 其他分页差不多大；固定大小，内容太长就在右边捲动
    static let size = NSSize(width: 680, height: 460)

    /// 在偏好设置窗口最后加一个分页
    static func install(in tabViewController: NSTabViewController) {
        let controller = NSHostingController(rootView: ESP32BridgePreferencesView(status: ESP32Bridge.shared.status))
        if #available(macOS 13.0, *) {
            controller.sizingOptions = [] // 不要让 SwiftUI 按内容改视窗大小
        }
        controller.title = "歌詞顯示器"
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.preferredContentSize = size
        let item = NSTabViewItem(viewController: controller)
        item.label = "歌詞顯示器"
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: "display", accessibilityDescription: "歌詞顯示器")
        }
        tabViewController.addTabViewItem(item)
    }
}

/// 左边分类、右边内容（像系统设定）。显示器的分类跟屏幕上的设定页一样：顯示 / 連線 / Wi-Fi / 關於
struct ESP32BridgePreferencesView: View {
    enum Page: Hashable {
        case general
        case screen(String) // BridgeServer.Client.id
        case names
    }

    @ObservedObject var status: ESP32BridgeStatus
    @State private var selection: Page? = .general

    private var clients: [BridgeServer.Client] { status.server.clients }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider()
            ScrollView {
                detail
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: ESP32BridgePreferences.size.width, height: ESP32BridgePreferences.size.height)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Label("一般", systemImage: "gearshape").tag(Page.general)
            Section("顯示器") {
                if clients.isEmpty {
                    Text("沒有連線的顯示器").foregroundColor(.secondary)
                }
                ForEach(clients) { client in
                    Label(ScreenInfo(client).name, systemImage: ScreenInfo(client).isUSB ? "cable.connector" : "wifi")
                        .tag(Page.screen(client.id))
                }
            }
            Section("Apple Music") {
                Label("中文歌名修正", systemImage: "character.book.closed").tag(Page.names)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .general {
        case .general:
            GeneralPage(status: status)
        case let .screen(id):
            if let client = clients.first(where: { $0.id == id }) {
                ScreenPage(client: client)
            } else {
                PageTitle("顯示器")
                Caption("這塊顯示器已經中斷連線。")
            }
        case .names:
            NamesPage(status: status)
        }
    }
}

// MARK: - 一般

private struct GeneralPage: View {
    @ObservedObject var status: ESP32BridgeStatus
    @State private var serverEnabled = ESP32Bridge.shared.isServerEnabled
    @State private var screenScale = ESP32Bridge.shared.screenScale

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle("一般")
            PrefSection(title: "歌詞顯示器") {
                Toggle("在顯示器（ESP32）上顯示歌詞", isOn: Binding(
                    get: { serverEnabled },
                    set: { serverEnabled = $0; ESP32Bridge.shared.isServerEnabled = $0 }
                ))
                Caption("同一個區域網路裡的顯示器會自動找到這台 Mac；用 USB 線接著 Mac 的顯示器不需要 Wi-Fi。")
                serverStatusRow
            }
            PrefSection(title: "顯示") {
                HStack {
                    Text("字體大小")
                    Slider(value: Binding(
                        get: { screenScale },
                        set: { screenScale = $0; ESP32Bridge.shared.screenScale = $0 }
                    ), in: 0.7...1.3, step: 0.05)
                    Text("\(Int((screenScale * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Caption("顏色跟「桌面歌詞」的文字、進度、背景顏色一樣。亮度和旋轉在顯示器上調整。")
            }
        }
    }

    @ViewBuilder private var serverStatusRow: some View {
        let server = status.server
        if !serverEnabled {
            StatusLine(color: .secondary, text: "已關閉，顯示器不會收到歌詞。")
        } else if server.isRunning {
            StatusLine(color: .green, text: "運作中 · 名稱「\(server.name)」· 連接埠 \(server.port.map(String.init) ?? "?")")
        } else {
            StatusLine(color: .orange, text: "啟動中…（若一直停在這裡，請到「系統設定 → 隱私權與安全性 → 區域網路」允許 LyricsX）")
        }
    }
}

// MARK: - 中文歌名修正

private struct NamesPage: View {
    @ObservedObject var status: ESP32BridgeStatus
    @State private var resolverEnabled = TrackNameResolver.shared.isEnabled
    @State private var cacheCleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle("中文歌名修正")
            PrefSection(title: nil) {
                Toggle("搜尋歌詞前，把 Apple Music 的英文歌名／歌手換回中文", isOn: Binding(
                    get: { resolverEnabled },
                    set: { resolverEnabled = $0; TrackNameResolver.shared.isEnabled = $0 }
                ))
                Caption("使用 Apple 公開的 iTunes 搜尋服務（香港區）查中文名，查過的歌會記住。用中文名搜不到歌詞時，會再用原名搜一次。")
            }
            PrefSection(title: "目前歌曲") {
                nameStatusRow
                HStack {
                    Button("清除記住的歌名") {
                        TrackNameResolver.shared.clearCache()
                        cacheCleared = true
                    }
                    if cacheCleared { Caption("已清除") }
                }
            }
        }
    }

    @ViewBuilder private var nameStatusRow: some View {
        if !resolverEnabled {
            Caption("功能已關閉，會照 Apple Music 顯示的名字搜尋歌詞。")
        } else if let name = status.name {
            let original = "\(name.originalTitle) — \(name.originalArtist)"
            if name.isLookingUp {
                Text("\(original)（查詢中…）")
            } else if let resolved = name.resolved {
                Text("\(original) → \(resolved.title) — \(resolved.artist)")
            } else if TrackNameResolver.containsCJK(name.originalTitle), TrackNameResolver.containsCJK(name.originalArtist) {
                Text("\(original)（已經是中文，不用修正）")
            } else {
                Text("\(original)（找不到中文名，照原名搜尋）")
            }
        } else {
            Caption("目前沒有播放。")
        }
    }
}

// MARK: - 一塊显示器

private struct ScreenInfo {
    let client: BridgeServer.Client
    init(_ client: BridgeServer.Client) { self.client = client }

    var isUSB: Bool { client.address == "USB" }

    var name: String {
        switch client.device {
        case "guition-p4-4.3": return "4.3 吋顯示器"
        case "aibox-p4-6.2": return "6.2 吋顯示器"
        default: return client.device ?? "顯示器"
        }
    }

    /// 4.3 吋的 Wi-Fi 晶片（C6）只支援 2.4 GHz
    var only24GHz: Bool { client.device == "guition-p4-4.3" }
}

/// 跟屏幕上的设定页同样分类：連線 / Wi-Fi / 關於（顯示的亮度、旋转在屏幕上调）
private struct ScreenPage: View {
    let client: BridgeServer.Client
    @State private var isAdding = false
    @State private var pendingRemoval: String?

    private var info: ScreenInfo { ScreenInfo(client) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(info.name)
            PrefSection(title: "連線") {
                LabeledRow("連線方式", info.isUSB ? "USB" : "Wi-Fi")
                if !info.isUSB { LabeledRow("IP 位址", client.address) }
                if let current = client.wifiCurrent, !current.isEmpty { LabeledRow("Wi-Fi", current) }
            }
            wifiSection
            PrefSection(title: "關於") {
                LabeledRow("裝置", client.device ?? "—")
                LabeledRow("識別碼", client.deviceId ?? "—")
                if let width = client.width, let height = client.height, width > 0 {
                    LabeledRow("解析度", "\(width)×\(height)")
                }
                LabeledRow("版本", client.version ?? "—")
            }
        }
        .sheet(isPresented: $isAdding) {
            AddWiFiSheet(deviceName: info.name, only24GHz: info.only24GHz) { ssid, password in
                ESP32Bridge.shared.addWiFi(ssid: ssid, password: password, toClient: client.id)
            }
        }
        .alert("刪除目前連線的 Wi-Fi？", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("刪除", role: .destructive) {
                if let ssid = pendingRemoval { ESP32Bridge.shared.removeWiFi(ssid: ssid, fromClient: client.id) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("顯示器會中斷這個 Wi-Fi，改連其他已儲存的網路；都沒有的話要用 USB 線重新設定。")
        }
    }

    private var wifiSection: some View {
        PrefSection(title: "Wi-Fi") {
            if client.wifiSaved.isEmpty {
                Caption("尚未儲存任何 Wi-Fi")
            }
            ForEach(client.wifiSaved, id: \.self) { ssid in
                HStack {
                    Image(systemName: "wifi").foregroundColor(.secondary)
                    Text(ssid)
                    if ssid == client.wifiCurrent {
                        Text("已連線")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.2)))
                    }
                    Spacer()
                    Button {
                        // 删掉正在用的 Wi-Fi 会让显示器断线：先确认
                        if ssid == client.wifiCurrent, !info.isUSB {
                            pendingRemoval = ssid
                        } else {
                            ESP32Bridge.shared.removeWiFi(ssid: ssid, fromClient: client.id)
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("刪除")
                }
                Divider()
            }
            HStack {
                Button("加入 Wi-Fi…") { isAdding = true }
                    .disabled(client.wifiSaved.count >= 5)
                Caption(info.only24GHz ? "最多 5 組，只支援 2.4 GHz；開機時連訊號最強的。" : "最多 5 組；開機時連訊號最強的。")
            }
        }
    }
}

private struct AddWiFiSheet: View {
    let deviceName: String
    let only24GHz: Bool
    let onAdd: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("為「\(deviceName)」加入 Wi-Fi").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Wi-Fi 名稱", text: $ssid)
                SecureField("密碼（沒有密碼就留空）", text: $password)
            }
            .textFieldStyle(.roundedBorder)
            Caption(only24GHz ? "這塊顯示器只支援 2.4 GHz 的網路。" : "支援 2.4 GHz 和 5 GHz 的網路。")
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("加入") {
                    onAdd(ssid.trimmingCharacters(in: .whitespaces), password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(ssid.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - 共用

/// 标题 + 圆角框
private struct PrefSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        }
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatusLine: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 右边内容最上面的大标题
private struct PageTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.title2.bold())
    }
}

/// 名称 …… 值
private struct LabeledRow: View {
    let name: String
    let value: String
    init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundColor(.secondary).textSelection(.enabled)
        }
    }
}
