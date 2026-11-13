// LyricsXBridge — 不属于 LyricsX 原本的代码。
// 局域网 WebSocket 服务器 + Bonjour 宣告（_lyricsx._tcp），以及 USB 线连着的屏幕（BridgeUSB.swift）。格式见 docs/protocol.md。

import Foundation
import Network
import notify

public final class BridgeServer: @unchecked Sendable {
    public static let serviceType = "_lyricsx._tcp"
    public static let preferredPort: UInt16 = 8765
    /// 屏幕用 UDP 广播找 Mac 的端口（固定；回应里带 WebSocket 实际端口）。
    /// 很多路由器不转发 Wi-Fi 装置发出的多播，所以 ESP32 不靠 mDNS 找 Mac。
    public static let discoveryPort: UInt16 = 8765
    static let discoveryRequest = "LYRICSX_DISCOVER 1"
    /// 烧录 / 看 log 前发这个通知，USB 屏幕会放开串口一分钟：`notifyutil -p LyricsXBridge.usb.pause`
    public static let usbPauseNotification = "LyricsXBridge.usb.pause"

    /// 给设定页显示用的状态
    public struct Status: Sendable, Equatable {
        public var isRunning = false
        public var port: UInt16?
        public var name = ""
        public var clients: [Client] = []

        public init(isRunning: Bool = false, port: UInt16? = nil, name: String = "", clients: [Client] = []) {
            self.isRunning = isRunning
            self.port = port
            self.name = name
            self.clients = clients
        }
    }

    public struct Client: Sendable, Equatable, Identifiable {
        public var id: String
        public var address: String
        public var device: String?
        public var deviceId: String?
        public var width: Int?
        public var height: Int?
        /// 屏幕固件的版本
        public var version: String?
        /// 屏幕存的 Wi-Fi（只有名称）和目前连着的
        public var wifiSaved: [String] = []
        public var wifiCurrent: String?
    }

    /// 状态改变时呼叫（在 server queue 上），请在 start() 之前设定
    public var onStatusChange: (@Sendable (Status) -> Void)?

    /// 所有状态只在这个 queue 上读写
    private let queue = DispatchQueue(label: "LyricsXBridge.server")
    private var listener: NWListener?
    private var discoverySource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    private var isRunning = false
    private var usbPorts: [String: BridgeSerialPort] = [:]
    private var usbTimer: DispatchSourceTimer?
    private var usbPausedUntil = Date.distantPast
    private var usbPauseToken: Int32 = -1
    private var retryCount = 0

    /// 每种讯息最近的一则，新装置连上时按这个顺序补发；stopped 跟 track / lyrics / sync 互斥
    private enum Slot: CaseIterable { case style, stopped, track, lyrics, sync }
    private var latest: [Slot: Data] = [:]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    public let serverID: String
    public let serverName: String
    private let serverVersion: String

    public init() {
        let key = "LyricsXBridgeServerID"
        if let id = UserDefaults.standard.string(forKey: key) {
            serverID = id
        } else {
            serverID = UUID().uuidString
            UserDefaults.standard.set(serverID, forKey: key)
        }
        serverName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        serverVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    public func start() {
        queue.async {
            guard !self.isRunning else { return }
            self.isRunning = true
            self.startListener(port: Self.preferredPort)
            self.startDiscovery()
            self.startUSB()
        }
    }

    public func stop() {
        queue.async {
            self.isRunning = false
            self.listener?.cancel()
            self.listener = nil
            self.discoverySource?.cancel()
            self.discoverySource = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.stopUSB()
            self.clients.removeAll()
            self.publishStatus()
        }
    }

    // MARK: - 发送

    public func send(_ message: BridgeMessage.Style) { broadcast(message, slot: .style) }
    public func send(_ message: BridgeMessage.Stopped) { broadcast(message, slot: .stopped) }
    public func send(_ message: BridgeMessage.Track) { broadcast(message, slot: .track) }
    public func send(_ message: BridgeMessage.Lyrics) { broadcast(message, slot: .lyrics) }
    public func send(_ message: BridgeMessage.Sync) { broadcast(message, slot: .sync) }

    private func broadcast(_ message: some Encodable & Sendable, slot: Slot) {
        queue.async {
            // 内容跟上一则一样就不重发
            guard let data = self.encode(message), self.latest[slot] != data else { return }
            bridgeTrace("SEND " + String(decoding: data.prefix(200), as: UTF8.self))
            switch slot {
            case .stopped: self.latest = self.latest.filter { $0.key == .style }
            case .track, .lyrics, .sync: self.latest[.stopped] = nil
            case .style: break
            }
            self.latest[slot] = data
            for connection in self.connections.values {
                self.send(data, to: connection)
            }
            for port in self.usbPorts.values where port.isGreeted {
                port.send(data)
            }
        }
    }

    /// 只发给某一块屏幕（Client.id）
    public func send(_ message: BridgeMessage.WiFi, toClient clientID: String) {
        queue.async {
            guard let data = self.encode(message),
                  let key = self.clients.first(where: { $0.value.id == clientID })?.key else { return }
            self.send(data, toKey: key)
        }
    }

    private func send(_ data: Data, toKey key: ObjectIdentifier) {
        if let connection = connections[key] {
            send(data, to: connection)
        } else {
            usbPorts.values.first { ObjectIdentifier($0) == key }?.send(data)
        }
    }

    // MARK: - 封面（每种屏幕大小一份）

    /// 需要某个大小的封面时呼叫（在 server queue 上）：做好后用 send(_:width:height:) 发
    public var onNeedArt: (@Sendable (_ width: Int, _ height: Int) -> Void)?
    /// 有封面的歌（nil = 没有封面）、已经做好的封面（"宽x高" → 讯息）
    private var artTrackID: String?
    private var latestArt: [String: Data] = [:]

    /// 换歌：这首歌有没有封面。有的话，向每种已连接的屏幕大小要一份
    public func setArt(trackID: String?) {
        queue.async {
            self.artTrackID = trackID
            self.latestArt = [:]
            guard trackID != nil else { return }
            var sizes = Set<[Int]>()
            for client in self.clients.values {
                if let w = client.width, let h = client.height, sizes.insert([w, h]).inserted { self.onNeedArt?(w, h) }
            }
        }
    }

    public func send(_ message: BridgeMessage.Art, width: Int, height: Int) {
        queue.async {
            guard message.id == self.artTrackID, let data = self.encode(message) else { return }
            bridgeTrace("SEND art \(width)x\(height) \(data.count / 1024) KB")
            self.latestArt["\(width)x\(height)"] = data
            for (key, client) in self.clients where client.width == width && client.height == height {
                self.send(data, toKey: key)
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func encode(_ message: some Encodable) -> Data? {
        try? encoder.encode(message)
    }

    // MARK: - Listener

    private func startListener(port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)

        let listener: NWListener
        do {
            if port == 0 {
                listener = try NWListener(using: parameters)
            } else {
                listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            }
        } catch {
            log("无法建立服务器（端口 \(port)）：\(error)")
            if port != 0 { startListener(port: 0) }
            return
        }

        let txt: [String: Data] = [
            "ver": Data("\(BridgeMessage.protocolVersion)".utf8),
            "id": Data(serverID.utf8),
            "name": Data(serverName.utf8),
        ]
        listener.service = NWListener.Service(
            name: serverName, type: Self.serviceType, domain: nil,
            txtRecord: NetService.data(fromTXTRecord: txt)
        )
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.retryCount = 0
                self.publishStatus()
                self.log("服务器已启动：端口 \(listener.port?.rawValue ?? 0)，Bonjour 名称「\(self.serverName)」")
            case .failed(let error):
                self.log("服务器出错：\(error)")
                listener.cancel()
                guard self.isRunning, self.listener === listener else { return }
                self.listener = nil
                self.publishStatus()
                // 端口被占用就改用系统分配的端口；其他错误隔几秒重试
                if case .posix(.EADDRINUSE) = error, port != 0 {
                    self.startListener(port: 0)
                } else {
                    self.retryCount += 1
                    let delay = min(30, 2 * self.retryCount)
                    self.queue.asyncAfter(deadline: .now() + .seconds(delay)) {
                        if self.isRunning, self.listener == nil { self.startListener(port: port) }
                    }
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    // MARK: - UDP 广播发现

    private func startDiscovery() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return log("无法建立发现用的 UDP socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.discoveryPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            return log("UDP 端口 \(Self.discoveryPort) 被占用，屏幕会找不到这台 Mac")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.answerDiscovery(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        discoverySource = source
    }

    /// 收到屏幕的「有没有 LyricsX？」就直接回给它（unicast）
    private func answerDiscovery(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        var from = sockaddr_storage()
        var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
        }
        guard count > 0, String(decoding: buffer[0..<count], as: UTF8.self) == Self.discoveryRequest,
              let port = listener?.port?.rawValue else { return }
        let reply = BridgeMessage.Server(id: serverID, name: serverName, port: Int(port))
        guard let data = encode(reply) else { return }
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, data.count, 0, $0, fromLength) }
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.clients[ObjectIdentifier(connection)] = Client(
                    id: "\(ObjectIdentifier(connection).hashValue)", address: Self.address(of: connection.endpoint)
                )
                self.publishStatus()
                self.log("装置已连接：\(connection.endpoint)")
                self.sendInitialState { self.send($0, to: connection) }
                self.receive(on: connection)
            case .failed, .cancelled:
                self.connections[ObjectIdentifier(connection)] = nil
                if self.clients.removeValue(forKey: ObjectIdentifier(connection)) != nil { self.publishStatus() }
                self.log("装置已断开：\(connection.endpoint)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendInitialState(_ send: (Data) -> Void) {
        sendHello(send)
        for data in Slot.allCases.compactMap({ latest[$0] }) {
            send(data)
        }
    }

    private func sendHello(_ send: (Data) -> Void) {
        let hello = BridgeMessage.Hello(serverVersion: serverVersion, id: serverID, name: serverName)
        if let data = encode(hello) { send(data) }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, error in
            guard let self, let connection else { return }
            if error != nil {
                connection.cancel()
                return
            }
            let isClose = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata)?.opcode == .close
            if isClose {
                connection.cancel()
                return
            }
            if let data, let message = try? JSONDecoder().decode(BridgeMessage.Incoming.self, from: data) {
                self.handle(message, key: ObjectIdentifier(connection)) { self.send($0, to: connection) }
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ message: BridgeMessage.Incoming, key: ObjectIdentifier, reply: (Data) -> Void) {
        switch message.type {
        case "ping":
            if let data = encode(BridgeMessage.Pong()) { reply(data) }
        case "hello":
            if var client = clients[key] {
                client.device = message.device
                client.deviceId = message.deviceId
                client.width = message.width
                client.height = message.height
                client.version = message.version
                clients[key] = client
                publishStatus()
            }
            log("装置 \(message.device ?? "?")（\(message.deviceId ?? "?")）\(message.width ?? 0)×\(message.height ?? 0)")
            // 知道屏幕大小了：补发封面，没有这个大小的就去做
            if artTrackID != nil, let w = message.width, let h = message.height {
                if let art = latestArt["\(w)x\(h)"] { reply(art) } else { onNeedArt?(w, h) }
            }
        case "wifi_list":
            if var client = clients[key] {
                client.wifiSaved = message.saved ?? []
                client.wifiCurrent = message.current
                clients[key] = client
                publishStatus()
            }
        default:
            break
        }
    }

    // MARK: - USB

    private func startUSB() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkUSB() }
        timer.resume()
        usbTimer = timer
        notify_register_dispatch(Self.usbPauseNotification, &usbPauseToken, queue) { [weak self] _ in
            guard let self else { return }
            self.log("USB 屏幕暂停一分钟（烧录 / 看 log）")
            self.usbPausedUntil = Date().addingTimeInterval(60)
            self.usbPorts.values.forEach { $0.close() }
        }
    }

    private func stopUSB() {
        usbTimer?.cancel()
        usbTimer = nil
        notify_cancel(usbPauseToken)
        usbPauseToken = -1
        usbPorts.values.forEach { $0.close() }
    }

    /// 每 2 秒：打开新接上的屏幕、把太久没回应的移出列表
    private func checkUSB() {
        for port in usbPorts.values where port.isGreeted && Date().timeIntervalSince(port.lastReceived) > 6 {
            port.isGreeted = false
            if clients.removeValue(forKey: ObjectIdentifier(port)) != nil { publishStatus() }
            log("USB 屏幕没有回应：\(port.path)")
        }
        guard Date() >= usbPausedUntil else { return }
        for path in BridgeSerialPort.espressifPorts() where usbPorts[path] == nil {
            guard let port = BridgeSerialPort(path: path, queue: queue) else { continue }
            usbPorts[path] = port
            port.onLine = { [weak self, unowned port] data in self?.receive(data, from: port) }
            port.onClose = { [weak self, unowned port] in
                guard let self else { return }
                self.usbPorts[port.path] = nil
                if self.clients.removeValue(forKey: ObjectIdentifier(port)) != nil { self.publishStatus() }
                self.log("USB 屏幕已断开：\(port.path)")
            }
            sendHello(port.send) // 屏幕收到后马上回 hello，不用等它下一次广播
        }
    }

    private func receive(_ data: Data, from port: BridgeSerialPort) {
        guard let message = try? JSONDecoder().decode(BridgeMessage.Incoming.self, from: data) else { return }
        port.lastReceived = Date()
        let key = ObjectIdentifier(port)
        if message.type == "hello", !port.isHelloPending {
            // 屏幕刚开机 / 刚连上：补发全部状态。没人读串口时屏幕每 2 秒发的 hello 会积在缓冲里、
            // 打开时一次涌进来，所以等一下、只回一次
            port.isHelloPending = true
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self, weak port] in
                guard let self, let port, self.usbPorts[port.path] === port else { return }
                port.isHelloPending = false
                port.isGreeted = true
                if self.clients[key] == nil { self.log("USB 屏幕已连接：\(port.path)") }
                self.clients[key] = Client(id: "usb:\(port.path)", address: "USB")
                self.publishStatus()
                self.sendInitialState(port.send)
                self.handle(message, key: key, reply: port.send) // 记下装置资料
            }
            return
        }
        guard port.isGreeted else { return }
        handle(message, key: key, reply: port.send)
    }

    private func publishStatus() {
        let status = Status(
            isRunning: isRunning && listener?.state == .ready,
            port: listener?.port?.rawValue,
            name: serverName,
            clients: clients.values.sorted { $0.address < $1.address }
        )
        onStatusChange?(status)
    }

    private static func address(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        var text = "\(host)"
        if text.hasPrefix("::ffff:") { text.removeFirst(7) }
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        return text
    }

    private func log(_ text: String) {
        bridgeTrace(text)
        NSLog("[LyricsXBridge] %@", text)
    }
}

/// 调试：用环境变量 LYRICSX_BRIDGE_TRACE=1 启动时，把发出的讯息和屏幕的 log 印到 stderr（docs/design.md §4）
private let traceEnabled = ProcessInfo.processInfo.environment["LYRICSX_BRIDGE_TRACE"] != nil
public func bridgeTrace(_ text: @autoclosure () -> String) {
    guard traceEnabled else { return }
    let time = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
    FileHandle.standardError.write(Data("\(time) \(text())\n".utf8))
}
