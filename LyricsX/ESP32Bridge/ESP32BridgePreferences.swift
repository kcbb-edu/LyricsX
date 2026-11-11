// LyricsXBridge — 不属于 LyricsX 原本的代码，见 docs/design.md。
// 偏好设置里的「歌词屏幕」分页：中文歌名修正、局域网歌词屏幕的开关和状态。

import AppKit
import LyricsXFoundation
import SwiftUI

enum ESP32BridgePreferences {
    /// 在偏好设置窗口最后加一个分页
    static func install(in tabViewController: NSTabViewController) {
        let controller = NSHostingController(rootView: ESP32BridgePreferencesView(status: ESP32Bridge.shared.status))
        controller.title = "歌词屏幕"
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        let item = NSTabViewItem(viewController: controller)
        item.label = "歌词屏幕"
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: "display", accessibilityDescription: "歌词屏幕")
        }
        tabViewController.addTabViewItem(item)
    }
}

struct ESP32BridgePreferencesView: View {
    @ObservedObject var status: ESP32BridgeStatus
    @State private var resolverEnabled = TrackNameResolver.shared.isEnabled
    @State private var serverEnabled = ESP32Bridge.shared.isServerEnabled
    @State private var cacheCleared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text("中文歌名修正").bold()) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("搜索歌词前，把 Apple Music 的英文歌名／歌手换回中文", isOn: Binding(
                        get: { resolverEnabled },
                        set: { resolverEnabled = $0; TrackNameResolver.shared.isEnabled = $0 }
                    ))
                    Text("使用 Apple 公开的 iTunes 搜索服务（香港区）查中文名，查过的歌会记住。用中文名搜不到歌词时，会再用原名搜一次。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    nameStatusRow
                    HStack {
                        Button("清除记住的歌名") {
                            TrackNameResolver.shared.clearCache()
                            cacheCleared = true
                        }
                        if cacheCleared {
                            Text("已清除").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("局域网歌词屏幕").bold()) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("让同一个局域网里的屏幕（ESP32）显示歌词", isOn: Binding(
                        get: { serverEnabled },
                        set: { serverEnabled = $0; ESP32Bridge.shared.isServerEnabled = $0 }
                    ))
                    serverStatusRow
                    clientList
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 520, height: 420, alignment: .topLeading)
    }

    // MARK: - 中文名

    @ViewBuilder private var nameStatusRow: some View {
        if !resolverEnabled {
            statusText("功能已关闭，会照 Apple Music 显示的名字搜歌词。")
        } else if let name = status.name {
            let original = "\(name.originalTitle) — \(name.originalArtist)"
            if name.isLookingUp {
                statusText("目前歌曲：\(original)（查询中…）")
            } else if let resolved = name.resolved {
                statusText("目前歌曲：\(original) → \(resolved.title) — \(resolved.artist)")
            } else if TrackNameResolver.containsCJK(name.originalTitle), TrackNameResolver.containsCJK(name.originalArtist) {
                statusText("目前歌曲：\(original)（已经是中文，不用修正）")
            } else {
                statusText("目前歌曲：\(original)（没有找到中文名，照原名搜索）")
            }
        } else {
            statusText("目前没有播放。")
        }
    }

    // MARK: - 服务器

    @ViewBuilder private var serverStatusRow: some View {
        let server = status.server
        if !serverEnabled {
            statusText("已关闭，屏幕不会收到歌词。")
        } else if server.isRunning {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                statusText("运行中 · 名称「\(server.name)」· 端口 \(server.port.map(String.init) ?? "?")")
            }
        } else {
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                statusText("启动中…（如果一直停在这里，请检查「系统设置 → 隐私与安全性 → 本地网络」是否允许 LyricsX）")
            }
        }
    }

    @ViewBuilder private var clientList: some View {
        if serverEnabled {
            let clients = status.server.clients
            Text(clients.isEmpty ? "还没有屏幕连接" : "已连接的屏幕（\(clients.count)）")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(clients) { client in
                HStack {
                    Image(nsImage: NSImage(named: NSImage.networkName) ?? NSImage())
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(client.device ?? "未知装置")
                    Text(client.address).foregroundColor(.secondary)
                    if let width = client.width, let height = client.height, width > 0 {
                        Text("\(width)×\(height)").foregroundColor(.secondary)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
