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
                ScreenPage(client: client).id(client.id) // 换一块屏幕就重新读它的设定
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
            PrefSection(title: "顯示器設定") {
                Caption("亮度、字體大小、背景、播放畫面、待機時鐘等都是每塊顯示器各自的設定：在左邊選顯示器調整。")
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

/// 跟屏幕上的设定页同样分类：顯示 / 連線 / Wi-Fi / 關於。
/// 屏幕的本机设定（亮度、播放画面、待机…）存在屏幕上：这里显示它回报的值，改了就发 `set`，它套用后再回报
private struct ScreenPage: View {
    let client: BridgeServer.Client
    @State private var isAdding = false
    @State private var pendingRemoval: String?

    private var info: ScreenInfo { ScreenInfo(client) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(info.name)
            if client.prefs.isEmpty {
                PrefSection(title: "顯示") { Caption("更新這塊顯示器的韌體後，可以在這裡調整它的設定。") }
            } else {
                displaySection
                playingSection
                backgroundSection
                pauseSection
            }
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

    private var displaySection: some View {
        PrefSection(title: "顯示") {
            PrefSlider(title: "亮度", value: client.prefs["brightness"] ?? 100, range: 10...100,
                       icons: ("sun.min", "sun.max")) { set("brightness", $0) }
            Toggle("翻轉畫面（USB 線換邊時用）", isOn: toggle("flipped"))
            Caption("這些設定存在顯示器上，在顯示器的設定頁也可以改，兩邊會同步。")
        }
    }

    private var playingSection: some View {
        PrefSection(title: "播放中") {
            LayoutPicker(selection: client.prefs["now_style"] ?? 0,
                         aspect: CGFloat(client.width ?? 16) / CGFloat(max(client.height ?? 9, 1))) { set("now_style", $0) }
            Divider()
            PrefSlider(title: "字體大小", value: client.prefs["font_scale"] ?? 100, range: 70...200,
                       icons: ("textformat.size.smaller", "textformat.size.larger")) { set("font_scale", $0) }
            PrefSlider(title: "下一句大小", value: client.prefs["next_size"] ?? 60, range: 50...100,
                       icons: ("textformat.size.smaller", "textformat.size.larger")) { set("next_size", $0) }
            Caption("下一句大小是跟目前一句比：100% = 兩句一樣大，離得遠也看得到。")
            Divider()
            Toggle("換行動畫", isOn: toggle("line_anim"))
            Toggle("換歌時背景淡入", isOn: toggle("bg_fade"))
        }
    }

    private var backgroundSection: some View {
        PrefSection(title: "背景") {
            Picker("背景", selection: pref("bg_mode")) {
                Text("封面模糊").tag(0)
                Text("純色").tag(1)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if (client.prefs["bg_mode"] ?? 0) == 0 {
                PrefSlider(title: "背景暗度", value: client.prefs["bg_dim"] ?? 50, range: 0...100,
                           icons: ("sun.max", "moon")) { set("bg_dim", $0) }
                Caption("用正在播放的歌的封面做模糊背景，文字是白色。背景會按封面亮度自動加暗；看不清楚可以拉深一點。")
            } else {
                Caption("背景和文字顏色跟 LyricsX「桌面歌詞」的設定一樣：文字、進度（卡拉OK 已唱）、背景顏色。")
            }
        }
    }

    private var pauseSection: some View {
        PrefSection(title: "暫停後") {
            Picker("顯示封面與時間", selection: pref("card_sec")) {
                Text("30 秒").tag(30)
                Text("1 分鐘").tag(60)
                Text("5 分鐘").tag(300)
                Text("永不").tag(0)
            }
            .fixedSize()
            Picker("顯示待機時鐘", selection: pref("standby_min")) {
                ForEach([1, 5, 10, 30], id: \.self) { Text("\($0) 分鐘").tag($0) }
                Text("永不").tag(0)
            }
            .fixedSize()
            Picker("待機時鐘樣式", selection: pref("clock_face")) {
                Text("數字").tag(0)
                Text("大字").tag(1)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Caption("暫停後先顯示封面與時間，再變成待機時鐘。Mac 沒開或沒連線時，顯示器也會當時鐘用。")
        }
    }

    private func set(_ key: String, _ value: Int) {
        ESP32Bridge.shared.setScreenPref(key, value, forClient: client.id)
    }

    /// 屏幕回报的设定值；改了就发给屏幕（它回报后画面才更新）
    private func pref(_ key: String) -> Binding<Int> {
        Binding(get: { client.prefs[key] ?? 0 }, set: { set(key, $0) })
    }

    private func toggle(_ key: String) -> Binding<Bool> {
        Binding(get: { (client.prefs[key] ?? 0) != 0 }, set: { set(key, $0 ? 1 : 0) })
    }

    private var wifiSection: some View {
        PrefSection(title: "Wi-Fi") {
            if !client.prefs.isEmpty {
                Toggle("自動連線 Wi-Fi（關閉後只用 USB 連線）", isOn: toggle("wifi_auto"))
                Divider()
            }
            if client.wifiSaved.isEmpty {
                Caption("尚未儲存任何 Wi-Fi")
            }
            ForEach(client.wifiSaved, id: \.self) { ssid in
                HStack {
                    Image(systemName: "wifi").foregroundColor(.secondary)
                    Text(ssid)
                    if ssid == client.wifiCurrent {
                        Badge(text: "已連線", color: .green)
                    } else if ssid == client.wifiTestSSID, let badge = testBadge(client.wifiTestResult) {
                        Badge(text: badge.text, color: badge.color)
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
            if client.wifiTestResult == "wrong_password" {
                Caption("密碼錯誤：再「加入 Wi-Fi…」一次同一個名稱就可以改密碼。")
            }
            HStack {
                Button("加入 Wi-Fi…") { isAdding = true }
                    .disabled(client.wifiSaved.count >= 5)
                Caption(info.only24GHz ? "最多 5 組，只支援 2.4 GHz；開機時連訊號最強的。" : "最多 5 組；開機時連訊號最強的。")
            }
        }
    }
}

/// 刚加入的 Wi-Fi 试连结果（屏幕还没连上任何 Wi-Fi 时，加入后会马上试连）
private func testBadge(_ result: String?) -> (text: String, color: Color)? {
    switch result {
    case "testing": return ("正在試連…", .secondary)
    case "wrong_password": return ("密碼錯誤", .red)
    case "not_found": return ("附近找不到", .orange)
    case "failed": return ("連不上", .red)
    default: return nil
    }
}

/// 名称旁边的小标签
private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.2)))
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

/// 设定滑杆（%）：拖的时候只改数字，放开才发给屏幕（背景暗度每次都要重做背景图，不要一直发）
private struct PrefSlider: View {
    let title: String
    let value: Int // 屏幕回报的
    let range: ClosedRange<Double>
    var icons: (String, String)?
    let commit: (Int) -> Void
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 72, alignment: .leading)
            if let icons { Image(systemName: icons.0).foregroundColor(.secondary) }
            Slider(value: Binding(get: { dragging ?? Double(value) }, set: { dragging = $0 }), in: range, step: 5) { editing in
                if !editing, let v = dragging { commit(Int(v.rounded())) }
            }
            if let icons { Image(systemName: icons.1).foregroundColor(.secondary) }
            Text("\(Int((dragging ?? Double(value)).rounded()))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .onChange(of: value) { _ in dragging = nil } // 屏幕回报新的值了
    }
}

/// 播放画面：两种版面的线稿，点一下选
private struct LayoutPicker: View {
    let selection: Int
    let aspect: CGFloat // 屏幕宽 / 高
    let choose: (Int) -> Void

    var body: some View {
        HStack(spacing: 16) {
            ForEach(0..<2, id: \.self) { style in
                Button { choose(style) } label: {
                    VStack(spacing: 6) {
                        LayoutWireframe(coverBeside: style == 1)
                            .frame(width: 170, height: 170 / aspect)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(selection == style ? Color.accentColor : Color.secondary.opacity(0.3),
                                        lineWidth: selection == style ? 2.5 : 1))
                        Text(style == 0 ? "歌詞為主" : "封面在旁")
                            .font(.caption)
                            .foregroundColor(selection == style ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 版面线稿：封面、歌名、两行歌词（白的是目前一句）、下方 Bottom Bar
private struct LayoutWireframe: View {
    let coverBeside: Bool

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let gray = Color.white.opacity(0.3)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.12))
                if coverBeside {
                    let side = h * 0.5, lyricsX = w * 0.06 + side + w * 0.05, lyricsW = w - lyricsX - w * 0.05
                    RoundedRectangle(cornerRadius: 3).fill(gray).frame(width: side, height: side).offset(x: w * 0.06, y: h * 0.12)
                    Capsule().fill(gray).frame(width: side * 0.7, height: h * 0.05).offset(x: w * 0.06, y: h * 0.67)
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: lyricsW * 0.8, height: h * 0.1)
                        .offset(x: lyricsX + lyricsW * 0.1, y: h * 0.28)
                    Capsule().fill(gray).frame(width: lyricsW * 0.55, height: h * 0.07)
                        .offset(x: lyricsX + lyricsW * 0.225, y: h * 0.46)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(gray).frame(width: h * 0.15, height: h * 0.15).offset(x: w * 0.04, y: h * 0.07)
                    Capsule().fill(gray).frame(width: w * 0.2, height: h * 0.05).offset(x: w * 0.04 + h * 0.2, y: h * 0.12)
                    Capsule().fill(Color.white.opacity(0.9)).frame(width: w * 0.6, height: h * 0.11).offset(x: w * 0.2, y: h * 0.36)
                    Capsule().fill(gray).frame(width: w * 0.4, height: h * 0.07).offset(x: w * 0.3, y: h * 0.56)
                }
                Capsule().fill(gray).frame(width: w * 0.9, height: max(h * 0.025, 1.5)).offset(x: w * 0.05, y: h * 0.86)
            }
        }
    }
}
