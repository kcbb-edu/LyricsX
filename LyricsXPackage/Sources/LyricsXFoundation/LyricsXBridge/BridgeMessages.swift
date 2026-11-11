// LyricsXBridge — 不属于 LyricsX 原本的代码。
// 局域网歌词 API 的讯息格式，跟 docs/protocol.md 一一对应。改这里要同步改文件和 ESP32 固件。

import Foundation

public enum BridgeMessage {
    public static let protocolVersion = 1

    public struct Hello: Encodable, Sendable {
        public let type = "hello"
        public let ver = BridgeMessage.protocolVersion
        public var server = "LyricsX"
        public var serverVersion: String
        public var id: String
        public var name: String
    }

    /// UDP 发现的回应
    struct Server: Encodable {
        let type = "server"
        let ver = BridgeMessage.protocolVersion
        var id: String
        var name: String
        var port: Int
    }

    public struct Track: Encodable, Sendable {
        public let type = "track"
        public var id: String
        public var title: String
        public var artist: String
        public var album: String?
        public var duration: Double
        public var originalTitle: String
        public var originalArtist: String

        public init(id: String, title: String, artist: String, album: String?, duration: Double,
                    originalTitle: String, originalArtist: String) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = BridgeMessage.round(duration)
            self.originalTitle = originalTitle
            self.originalArtist = originalArtist
        }
    }

    public struct Lyrics: Encodable, Sendable {
        public enum Status: String, Encodable, Sendable {
            /// 有歌词
            case ok
            /// 目前没有歌词（搜索中或搜不到）
            case none
        }

        public let type = "lyrics"
        public var id: String
        public var status: Status
        public var karaoke: Bool
        public var lines: [Line]

        public init(id: String, status: Status, lines: [Line]) {
            self.id = id
            self.status = status
            self.lines = lines
            self.karaoke = lines.contains { $0.words != nil }
        }
    }

    public struct Line: Encodable, Sendable {
        /// 开始时间（秒，已加上歌词偏移）
        public var t: Double
        public var text: String
        public var trans: String?
        /// 逐字时间：[相对 t 的秒数, 第几个字]
        public var words: [Word]?

        public init(t: Double, text: String, trans: String?, words: [Word]?) {
            self.t = BridgeMessage.round(t)
            self.text = text
            self.trans = trans
            self.words = words
        }
    }

    /// 编码成 `[time, index]`
    public struct Word: Encodable, Sendable {
        public var time: Double
        public var index: Int

        public init(time: Double, index: Int) {
            self.time = BridgeMessage.round(time)
            self.index = index
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(time)
            try container.encode(index)
        }
    }

    public struct Sync: Encodable, Sendable {
        public let type = "sync"
        public var id: String
        public var pos: Double
        public var playing: Bool
        public var line: Int?

        public init(id: String, pos: Double, playing: Bool, line: Int?) {
            self.id = id
            self.pos = BridgeMessage.round(pos)
            self.playing = playing
            self.line = line
        }
    }

    public struct Style: Encodable, Sendable {
        public let type = "style"
        /// "#RRGGBB"
        public var text: String
        public var highlight: String
        public var background: String
        public var scale: Double

        public init(text: String, highlight: String, background: String, scale: Double) {
            self.text = text
            self.highlight = highlight
            self.background = background
            self.scale = BridgeMessage.round(scale)
        }
    }

    /// 只发给一块屏幕：新增 / 删除它存的 Wi-Fi
    public struct WiFi: Encodable, Sendable {
        public enum Action: String, Encodable, Sendable { case add, remove }
        public let type = "wifi"
        public var action: Action
        public var ssid: String
        public var password: String?

        public init(action: Action, ssid: String, password: String? = nil) {
            self.action = action
            self.ssid = ssid
            self.password = password
        }
    }

    public struct Stopped: Encodable, Sendable {
        public let type = "stopped"
        public init() {}
    }

    struct Pong: Encodable {
        let type = "pong"
    }

    /// ESP32 → Mac 的讯息（只解析需要的字段）
    struct Incoming: Decodable {
        var type: String
        var device: String?
        var deviceId: String?
        var width: Int?
        var height: Int?
        // wifi_list
        var current: String?
        var saved: [String]?
    }

    /// 时间只保留到毫秒，JSON 比较短
    static func round(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    /// UTF-16 位置（LyricsX 的逐字时间用这个）→ 第几个字（Unicode 字符，ESP32 用这个）
    public static func scalarIndex(ofUTF16Offset offset: Int, in string: String) -> Int {
        let utf16 = string.utf16
        let clamped = min(max(offset, 0), utf16.count)
        let end = utf16.index(utf16.startIndex, offsetBy: clamped)
        let scalarEnd = end.samePosition(in: string.unicodeScalars)
            ?? string.unicodeScalars.index(before: end) // 落在代理对中间时往前对齐
        return string.unicodeScalars.distance(from: string.unicodeScalars.startIndex, to: scalarEnd)
    }
}
