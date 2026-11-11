// LyricsXBridge — 不属于 LyricsX 原本的代码，见 docs/design.md。
//
// 香港区 Apple Music 常把中文歌名 / 歌手显示成英文（例如 "Sunny Day" / "Jay Chou"），
// 歌词网站用英文名搜不到。这里用 iTunes Search API 在香港区查同一首歌，拿回中文名（晴天 / 周杰倫）。

import Foundation

public struct ResolvedTrackName: Codable, Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String?
}

public actor TrackNameResolver {
    public static let shared = TrackNameResolver()

    public static let enabledKey = "LyricsXBridgeNameResolverEnabled"

    /// 中文名修正开关（默认开启），在「歌词屏幕」设定页里切换
    public nonisolated var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// 清除记住的歌名（包括查不到的记录）
    public nonisolated func clearCache() {
        cache.removeAll()
    }

    /// iTunes 商店地区，香港区的结果是中文名
    public nonisolated let storefront = "hk"

    private struct CacheEntry: Codable {
        var result: ResolvedTrackName?
        var date: Date
    }

    /// 查不到的结果也缓存，但 3 天后会重查
    private static let negativeCacheLifetime: TimeInterval = 3 * 24 * 3600
    /// iTunes 结果的长度与歌曲长度最多差几秒才算同一首
    private static let durationTolerance: TimeInterval = 3

    private let cache: Cache
    private var inFlight: [String: Task<ResolvedTrackName?, Never>] = [:]
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        session = URLSession(configuration: configuration)
        cache = Cache()
    }

    /// 只查缓存（同步），给手动搜索窗口预填用。返回 nil 表示没有中文名可用。
    public nonisolated func cachedName(title: String, artist: String, duration: TimeInterval) -> ResolvedTrackName? {
        guard isEnabled else { return nil }
        return cache.get(Self.cacheKey(title: title, artist: artist, duration: duration))?.result
    }

    /// 查中文名。返回 nil 表示不需要改名、查不到或出错 —— 这时照原本名字搜歌词即可。
    public func resolve(title: String, artist: String, duration: TimeInterval) async -> ResolvedTrackName? {
        guard isEnabled, !title.isEmpty else { return nil }
        // 歌名和歌手都已经有中日韩文字，不用处理
        if Self.containsCJK(title), Self.containsCJK(artist) { return nil }

        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        if let entry = cache.get(key) {
            if entry.result != nil || Date().timeIntervalSince(entry.date) < Self.negativeCacheLifetime {
                return entry.result
            }
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task { await self.lookup(title: title, artist: artist, duration: duration) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if !Task.isCancelled {
            cache.set(key, CacheEntry(result: result, date: Date()))
        }
        return result
    }

    // MARK: - iTunes Search API

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            var kind: String?
            var trackName: String?
            var artistName: String?
            var collectionName: String?
            var trackTimeMillis: Double?
        }

        var results: [Item]
    }

    private func lookup(title: String, artist: String, duration: TimeInterval) async -> ResolvedTrackName? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "country", value: storefront),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url,
              let data = await fetch(url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            return nil
        }

        var candidates = response.results.filter {
            ($0.kind ?? "song") == "song" && !($0.trackName ?? "").isEmpty && !($0.artistName ?? "").isEmpty
        }
        // 用歌曲长度确认是同一首；没有长度资料时只接受有中文的结果
        func durationDiff(_ item: SearchResponse.Item) -> TimeInterval {
            guard duration > 0, let ms = item.trackTimeMillis else { return .infinity }
            return abs(ms / 1000 - duration)
        }
        if duration > 0 {
            candidates = candidates.filter { durationDiff($0) <= Self.durationTolerance }
        }
        let withCJK = candidates.filter { Self.containsCJK($0.trackName!) || Self.containsCJK($0.artistName!) }
        let pool = withCJK.isEmpty ? (duration > 0 ? candidates : []) : withCJK
        guard let best = pool.min(by: { durationDiff($0) < durationDiff($1) }) else {
            return nil
        }

        let result = ResolvedTrackName(title: best.trackName!, artist: best.artistName!, album: best.collectionName)
        if result.title == title, result.artist == artist {
            return nil // 结果跟原本一样，不用改
        }
        return result
    }

    private func fetch(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            session.dataTask(with: url) { data, response, _ in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                continuation.resume(returning: ok ? data : nil)
            }.resume()
        }
    }

    // MARK: - Helpers

    private static func cacheKey(title: String, artist: String, duration: TimeInterval) -> String {
        "\(title)\u{1F}\(artist)\u{1F}\(Int(duration.rounded()))"
    }

    /// 有没有中日韩文字（汉字、假名、韩文）
    public static func containsCJK(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // 假名
                 0x3400...0x4DBF, // 汉字扩展 A
                 0x4E00...0x9FFF, // 汉字
                 0xAC00...0xD7AF, // 韩文
                 0xF900...0xFAFF, // 兼容汉字
                 0x20000...0x2FA1F: // 汉字扩展 B 以后
                return true
            default:
                return false
            }
        }
    }

    // MARK: - 磁盘缓存

    /// 存在 ~/Library/Application Support/<bundle id>/LyricsXBridge/name-cache.json
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: CacheEntry] = [:]
        private let fileURL: URL?

        init() {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let bundleID = Bundle.main.bundleIdentifier ?? "LyricsX"
            let directory = base?.appendingPathComponent(bundleID).appendingPathComponent("LyricsXBridge")
            if let directory {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            fileURL = directory?.appendingPathComponent("name-cache.json")
            if let fileURL, let data = try? Data(contentsOf: fileURL) {
                entries = (try? JSONDecoder().decode([String: CacheEntry].self, from: data)) ?? [:]
            }
        }

        func removeAll() {
            lock.lock()
            entries.removeAll()
            lock.unlock()
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        }

        func get(_ key: String) -> CacheEntry? {
            lock.lock()
            defer { lock.unlock() }
            return entries[key]
        }

        func set(_ key: String, _ entry: CacheEntry) {
            lock.lock()
            entries[key] = entry
            let data = try? JSONEncoder().encode(entries)
            lock.unlock()
            if let fileURL, let data {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
