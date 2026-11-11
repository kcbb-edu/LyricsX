// LyricsXBridge — 不属于 LyricsX 原本的代码。
// 局域网 WebSocket 服务器 + Bonjour 宣告（_lyricsx._tcp），格式见 docs/protocol.md。

import Foundation
import Network

public final class BridgeServer: @unchecked Sendable {
    public static let serviceType = "_lyricsx._tcp"
    public static let preferredPort: UInt16 = 8765

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
    }

    /// 状态改变时呼叫（在 server queue 上），请在 start() 之前设定
    public var onStatusChange: (@Sendable (Status) -> Void)?

    /// 所有状态只在这个 queue 上读写
    private let queue = DispatchQueue(label: "LyricsXBridge.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    private var isRunning = false
    private var retryCount = 0

    /// 每种讯息最近的一则，新装置连上时按这个顺序补发；stopped 跟其他三种互斥
    private enum Slot: CaseIterable { case stopped, track, lyrics, sync }
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
        }
    }

    public func stop() {
        queue.async {
            self.isRunning = false
            self.listener?.cancel()
            self.listener = nil
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.clients.removeAll()
            self.publishStatus()
        }
    }

    // MARK: - 发送

    public func send(_ message: BridgeMessage.Stopped) { broadcast(message, slot: .stopped) }
    public func send(_ message: BridgeMessage.Track) { broadcast(message, slot: .track) }
    public func send(_ message: BridgeMessage.Lyrics) { broadcast(message, slot: .lyrics) }
    public func send(_ message: BridgeMessage.Sync) { broadcast(message, slot: .sync) }

    private func broadcast(_ message: some Encodable & Sendable, slot: Slot) {
        queue.async {
            // 内容跟上一则一样就不重发
            guard let data = self.encode(message), self.latest[slot] != data else { return }
            if slot == .stopped { self.latest.removeAll() } else { self.latest[.stopped] = nil }
            self.latest[slot] = data
            for connection in self.connections.values {
                self.send(data, to: connection)
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
                self.sendInitialState(to: connection)
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

    private func sendInitialState(to connection: NWConnection) {
        let hello = BridgeMessage.Hello(serverVersion: serverVersion, id: serverID, name: serverName)
        if let data = encode(hello) { send(data, to: connection) }
        for data in Slot.allCases.compactMap({ latest[$0] }) {
            send(data, to: connection)
        }
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
                self.handle(message, from: connection)
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ message: BridgeMessage.Incoming, from connection: NWConnection) {
        switch message.type {
        case "ping":
            if let data = encode(BridgeMessage.Pong()) { send(data, to: connection) }
        case "hello":
            let key = ObjectIdentifier(connection)
            if var client = clients[key] {
                client.device = message.device
                client.deviceId = message.deviceId
                client.width = message.width
                client.height = message.height
                clients[key] = client
                publishStatus()
            }
            log("装置 \(message.device ?? "?")（\(message.deviceId ?? "?")）\(message.width ?? 0)×\(message.height ?? 0)")
        default:
            break
        }
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
        NSLog("[LyricsXBridge] %@", text)
    }
}
