// LyricsXBridge — 不属于 LyricsX 原本的代码，见 docs/design.md。
//
// 这个文件把 LyricsX 的状态（目前歌曲、歌词、播放进度）转成 docs/protocol.md 的讯息，
// 交给 BridgeServer 发到局域网上的显示屏。另外提供「先用中文名搜歌词，搜不到再用原名」的搜索流程。
//
// 接入点（原文件只改这几处）：
//   AppDelegate.applicationDidFinishLaunching → ESP32Bridge.shared.start()
//   AppController.currentTrackChanged        → LyricsXBridgeSearch.lyrics(...)
//   SearchLyricsViewController               → TrackNameResolver.shared.cachedName(...)
//   PreferenceTabViewController.viewDidLoad  → ESP32BridgePreferences.install(in:)

import AppKit
import Combine
import Foundation
import LyricsXFoundation
import MusicPlayer
import OpenCC

// 状态只在 `queue` 上读写，所以标成 @unchecked Sendable
final class ESP32Bridge: @unchecked Sendable {
    static let shared = ESP32Bridge()

    static let serverEnabledKey = "LyricsXBridgeServerEnabled"

    /// 局域网服务器开关（默认开启），在「歌词屏幕」设定页里切换
    var isServerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.serverEnabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.serverEnabledKey)
            newValue ? server.start() : server.stop()
        }
    }

    static let screenScaleKey = "LyricsXBridgeScreenScale"
    static let screenScalesKey = "LyricsXBridgeScreenScales"
    static let screenScaleRange = 0.7...2.0

    /// 屏幕字体大小比例（所有屏幕共用），在「歌詞顯示器」设定页调整
    var screenScale: Double {
        get { UserDefaults.standard.object(forKey: Self.screenScaleKey) as? Double ?? 1 }
        set {
            UserDefaults.standard.set(newValue.clamped(to: Self.screenScaleRange), forKey: Self.screenScaleKey)
            queue.async { self.sendStyle() }
        }
    }

    static let backgroundModeKey = "LyricsXBridgeBackgroundMode"
    static let backgroundDimKey = "LyricsXBridgeBackgroundDim" // 以前的三档（0 淡 / 1 标准 / 2 深）
    static let backgroundDarknessKey = "LyricsXBridgeBackgroundDarkness"

    enum BackgroundMode: String, CaseIterable {
        /// 模糊封面（文字白色）
        case artwork
        /// 纯色（颜色跟桌面歌词一样；Mac 不用做模糊背景）
        case solid
    }

    var backgroundMode: BackgroundMode {
        get { BackgroundMode(rawValue: UserDefaults.standard.string(forKey: Self.backgroundModeKey) ?? "") ?? .artwork }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.backgroundModeKey)
            queue.async { self.backgroundChanged() }
        }
    }

    /// 模糊封面的暗度 0（淡）– 1（深）
    var backgroundDim: Double {
        get {
            if let value = UserDefaults.standard.object(forKey: Self.backgroundDarknessKey) as? Double { return value }
            let old = UserDefaults.standard.object(forKey: Self.backgroundDimKey) as? Int ?? 1
            return [0.2, 0.5, 0.65][min(max(old, 0), 2)]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.backgroundDarknessKey)
            queue.async { self.backgroundChanged() }
        }
    }

    /// 背景设定改了：样式重发（屏幕按模式换颜色），封面重做
    private func backgroundChanged() {
        sendStyle()
        if artwork != nil, let id = trackID { server.setArt(trackID: id) }
    }

    /// 个别屏幕自订的字体比例（deviceId → 比例）
    private var screenScales: [String: Double] {
        UserDefaults.standard.dictionary(forKey: Self.screenScalesKey) as? [String: Double] ?? [:]
    }

    /// 这块屏幕自订的比例；nil = 跟共用的一样
    func screenScale(for deviceID: String) -> Double? { screenScales[deviceID] }

    func setScreenScale(_ value: Double?, for deviceID: String) {
        var scales = screenScales
        scales[deviceID] = value?.clamped(to: Self.screenScaleRange)
        UserDefaults.standard.set(scales, forKey: Self.screenScalesKey)
        queue.async { self.sendStyle() }
    }

    /// 给设定页用（只在主线程更新）
    let status = ESP32BridgeStatus()

    private let server = BridgeServer()
    /// 所有状态只在这个 queue 上读写
    private let queue = DispatchQueue(label: "LyricsXBridge.glue")
    private var cancelBag = Set<AnyCancellable>()
    private var syncTimer: DispatchSourceTimer?

    private var trackID: String?
    /// LyricsX 的行号 → 发出去的行号（停用的行不发）
    private var lineIndexMap: [Int: Int] = [:]
    private var resolveTask: Task<Void, Never>?
    /// 上一次发出的进度，用来省掉没有新资讯的 sync
    private var lastSync: (playing: Bool, line: Int?, pos: TimeInterval, at: Date)?
    /// 换歌时 Apple Music 会短暂回报「没有歌」：等一下才告诉屏幕停止，免得闪一下时钟
    private var pendingStop: DispatchWorkItem?
    /// 播放器最新的状态、LyricsX 目前的行号（从事件拿到的新值）
    private var playback = PlaybackState.stopped
    private var lineIndex: Int?
    /// 目前这首歌的封面（播放器给的，或 iTunes 查到的）
    private var artwork: CGImage?
    private var artworkTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard cancelBag.isEmpty else { return }
        server.onStatusChange = { [status] newValue in
            DispatchQueue.main.async { status.server = newValue }
        }
        server.onNeedArt = { [weak self] width, height in
            self?.queue.async { self?.renderArt(width: width, height: height) }
        }
        if isServerEnabled { server.start() }

        // 注意：这几个都是 @Published 的「将要改变」，送出时播放器的属性还是旧的值，
        // 所以一律用送来的新值，不要回头读 selectedPlayer / AppController
        selectedPlayer.currentTrackWillChange
            .receive(on: queue)
            .sink { [weak self] in self?.trackChanged($0) }
            .store(in: &cancelBag)
        AppController.shared.$currentLyrics
            .receive(on: queue)
            .sink { [weak self] lyrics in self?.lyricsChanged(lyrics) }
            .store(in: &cancelBag)
        // 用户调歌词偏移 → 时间变了，重发整首歌词
        AppController.shared.publisher(for: \.lyricsOffset)
            .dropFirst()
            .removeDuplicates()
            .receive(on: queue)
            .sink { [weak self] _ in self?.lyricsChanged(AppController.shared.currentLyrics) }
            .store(in: &cancelBag)
        // 换行、播放 / 暂停、拖动进度 → 马上发 sync（没有新资讯的会被省掉）
        AppController.shared.$currentLineIndex
            .receive(on: queue)
            .sink { [weak self] in
                self?.lineIndex = $0
                self?.sendSync()
            }
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .receive(on: queue)
            .sink { [weak self] in
                self?.playback = $0
                self?.sendSync()
            }
            .store(in: &cancelBag)

        // 颜色跟桌面歌词设定一样，改了马上发
        defaults.publisher(for: [.desktopLyricsColor, .desktopLyricsProgressColor, .desktopLyricsBackgroundColor])
            .prepend(())
            .receive(on: queue)
            .sink { [weak self] in self?.sendStyle() }
            .store(in: &cancelBag)

        // 播放中每秒发一次进度，让屏幕校准时钟
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            if self?.playback.isPlaying == true { self?.sendSync(force: true) }
        }
        timer.resume()
        syncTimer = timer

        queue.async {
            self.playback = selectedPlayer.playbackState
            self.lineIndex = AppController.shared.currentLineIndex
            self.trackChanged(selectedPlayer.currentTrack)
        }
    }

    // MARK: - Style / Wi-Fi

    private func sendStyle() {
        func hex(_ color: NSColor, over background: NSColor = .black) -> String {
            // 半透明颜色先叠在背景上（屏幕没有透明度）
            let c = color.usingColorSpace(.sRGB) ?? color
            let b = background.usingColorSpace(.sRGB) ?? background
            let a = c.alphaComponent
            let rgb = [(c.redComponent, b.redComponent), (c.greenComponent, b.greenComponent), (c.blueComponent, b.blueComponent)]
                .map { Int(((($0.0 * a) + $0.1 * (1 - a)) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2])
        }
        let text: NSColor? = defaults[.desktopLyricsColor]
        let progress: NSColor? = defaults[.desktopLyricsProgressColor]
        let background: NSColor? = defaults[.desktopLyricsBackgroundColor]
        server.send(BridgeMessage.Style(
            text: hex(text ?? .white),
            highlight: hex(progress ?? NSColor(red: 0.2, green: 1, blue: 0.87, alpha: 1)),
            background: hex(background ?? .black),
            scale: screenScale,
            scales: screenScales,
            backgroundMode: backgroundMode.rawValue,
            backgroundDim: Int((backgroundDim * 100).rounded())
        ))
    }

    /// 给某块屏幕新增（或改密码）一组 Wi-Fi
    func addWiFi(ssid: String, password: String, toClient clientID: String) {
        server.send(BridgeMessage.WiFi(action: .add, ssid: ssid, password: password), toClient: clientID)
    }

    func removeWiFi(ssid: String, fromClient clientID: String) {
        server.send(BridgeMessage.WiFi(action: .remove, ssid: ssid), toClient: clientID)
    }

    // MARK: - Track

    private func trackChanged(_ track: MusicTrack?) {
        resolveTask?.cancel()
        artworkTask?.cancel()
        pendingStop?.cancel()
        pendingStop = nil
        artwork = nil
        server.setArt(trackID: nil)
        guard let track else {
            trackID = nil
            lineIndexMap = [:]
            updateNameStatus(nil)
            let stop = DispatchWorkItem { [weak self] in self?.server.send(BridgeMessage.Stopped()) }
            pendingStop = stop
            queue.asyncAfter(deadline: .now() + 2, execute: stop)
            return
        }
        trackID = track.id
        lineIndexMap = [:]
        lastSync = nil

        let title = track.title ?? ""
        let artist = track.artist ?? ""
        let duration = track.duration ?? 0
        let cached = TrackNameResolver.shared.cachedName(title: title, artist: artist, duration: duration)
        sendTrack(track, resolved: cached)
        // AppController 会马上把歌词清空，这里不用另外发 lyrics
        updateNameStatus(.init(originalTitle: title, originalArtist: artist, resolved: cached, isLookingUp: cached == nil))

        // 中文名查到后再发一次 track（通常跟搜歌词共用同一个查询）
        resolveTask = Task { [weak self] in
            let resolved = await TrackNameResolver.shared.resolve(title: title, artist: artist, duration: duration)
            guard !Task.isCancelled else { return }
            self?.updateNameStatus(.init(originalTitle: title, originalArtist: artist, resolved: resolved, isLookingUp: false))
            guard let resolved else { return }
            self?.queue.async {
                guard let self, self.trackID == track.id else { return }
                self.sendTrack(track, resolved: resolved)
            }
        }
        loadArtwork(track, title: title, artist: artist, duration: duration)
        sendSync()
    }

    // MARK: - 封面

    /// 先用播放器给的封面；没有（Apple Music 串流常常没有）就去 iTunes 查
    private func loadArtwork(_ track: MusicTrack, title: String, artist: String, duration: TimeInterval) {
        if let image = track.artwork?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            artwork = image
            server.setArt(trackID: track.id)
            return
        }
        let storefront = TrackNameResolver.shared.storefront
        artworkTask = Task { [weak self] in
            let image = await BridgeArtwork.lookup(title: title, artist: artist, duration: duration, storefront: storefront)
            guard let image, !Task.isCancelled else { return }
            self?.queue.async {
                guard let self, self.trackID == track.id else { return }
                self.artwork = image
                self.server.setArt(trackID: track.id)
            }
        }
    }

    /// 做某个屏幕大小的封面和背景（在背景执行绪做，做好直接交给 server）
    private func renderArt(width: Int, height: Int) {
        guard let image = artwork, let id = trackID else { return }
        let dim = backgroundDim, withBackground = backgroundMode == .artwork
        DispatchQueue.global(qos: .utility).async { [server] in
            guard let art = BridgeArtwork.render(image, width: width, height: height, dim: dim,
                                                 withBackground: withBackground) else { return }
            server.send(BridgeMessage.Art(id: id, cover: art.cover, background: art.background), width: width, height: height)
        }
    }

    private func updateNameStatus(_ value: ESP32BridgeStatus.NameStatus?) {
        DispatchQueue.main.async { [status] in status.name = value }
    }

    private func sendTrack(_ track: MusicTrack, resolved: ResolvedTrackName?) {
        let title = track.title ?? ""
        let artist = track.artist ?? ""
        server.send(BridgeMessage.Track(
            id: track.id,
            title: resolved?.title ?? title,
            artist: resolved?.artist ?? artist,
            album: resolved?.album ?? track.album,
            duration: track.duration ?? 0,
            originalTitle: title,
            originalArtist: artist
        ))
    }

    // MARK: - Lyrics

    private func lyricsChanged(_ lyrics: Lyrics?) {
        guard let id = trackID else { return }
        guard let lyrics else {
            lineIndexMap = [:]
            server.send(BridgeMessage.Lyrics(id: id, status: .none, lines: []))
            return
        }

        // 简繁转换规则跟桌面歌词（KaraokeLyricsController）一样
        let converter = ChineseConverter.shared
        let translationCode = lyrics.metadata.translationLanguages.first
        let convertText = lyrics.metadata.language?.hasPrefix("zh") == true
        let convertTranslation = translationCode?.hasPrefix("zh") == true
        let delay = lyrics.adjustedTimeDelay

        var lines: [BridgeMessage.Line] = []
        var map: [Int: Int] = [:]
        for (index, line) in lyrics.lines.enumerated() where line.enabled {
            var text = line.content
            if convertText, let converter { text = converter.convert(text) }
            let length = text.unicodeScalars.count

            var words: [BridgeMessage.Word]?
            if let tags = line.attachments.timetag?.tags, !tags.isEmpty {
                words = tags.map {
                    let scalar = BridgeMessage.scalarIndex(ofUTF16Offset: $0.index, in: line.content)
                    return BridgeMessage.Word(time: $0.time, index: min(scalar, length))
                }
            }

            var translation = line.attachments[.translation(languageCode: translationCode)]
            if convertTranslation, let converter, let value = translation { translation = converter.convert(value) }

            map[index] = lines.count
            lines.append(BridgeMessage.Line(t: line.position - delay, text: text, trans: translation, words: words))
        }
        lineIndexMap = map
        server.send(BridgeMessage.Lyrics(id: id, status: lines.isEmpty ? .none : .ok, lines: lines))
        sendSync()
    }

    // MARK: - Sync

    /// `force` = 定时同步，一定发；其他情况只在播放状态、行号改变或进度跳动时才发
    private func sendSync(force: Bool = false) {
        guard let id = trackID else { return }
        let state = playback
        let line = lineIndex.flatMap { lineIndexMap[$0] }
        let now = Date()
        if !force, let last = lastSync, last.playing == state.isPlaying, last.line == line {
            let expected = last.pos + (last.playing ? now.timeIntervalSince(last.at) : 0)
            if abs(expected - state.time) < 0.3 { return }
        }
        lastSync = (state.isPlaying, line, state.time, now)
        server.send(BridgeMessage.Sync(id: id, pos: state.time, playing: state.isPlaying, line: line))
    }
}

// MARK: - 搜索：先中文名，搜不到再用原名

enum LyricsXBridgeSearch {
    /// 代替 `provider.lyrics(for: request)`。
    /// 每换一个搜索条件就先呼叫 `onRequest`，让 AppController 更新 `searchRequest`（它用来比对收到的歌词）。
    static func lyrics(
        provider: LyricsProvider,
        original: LyricsSearchRequest,
        onRequest: @escaping @MainActor (LyricsSearchRequest) -> Void
    ) -> AsyncThrowingStream<Lyrics, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    var requests = [original]
                    if case .info(let title, let artist) = original.searchTerm,
                       let resolved = await TrackNameResolver.shared.resolve(
                           title: title, artist: artist, duration: original.duration
                       ) {
                        var chinese = original
                        chinese.searchTerm = .info(title: resolved.title, artist: resolved.artist)
                        requests.insert(chinese, at: 0)
                        NSLog("[LyricsXBridge] 用中文名搜索：%@ - %@（原名 %@ - %@）",
                              resolved.title, resolved.artist, title, artist)
                    }
                    for request in requests {
                        try Task.checkCancellation()
                        onRequest(request)
                        var found = false
                        for try await lyrics in provider.lyrics(for: request) {
                            found = true
                            continuation.yield(lyrics)
                        }
                        if found { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - 设定页用的状态

// 只在主线程读写，所以标成 @unchecked Sendable
final class ESP32BridgeStatus: ObservableObject, @unchecked Sendable {
    struct NameStatus: Equatable {
        var originalTitle: String
        var originalArtist: String
        var resolved: ResolvedTrackName?
        var isLookingUp: Bool
    }

    /// 目前歌曲的中文名修正结果（没有播放就是 nil）
    @Published var name: NameStatus?
    @Published var server = BridgeServer.Status()
}
