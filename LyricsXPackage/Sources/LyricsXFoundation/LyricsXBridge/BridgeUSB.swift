// LyricsXBridge — 不属于 LyricsX 原本的代码。
// USB 线连着的屏幕：ESP32 内建的 USB-Serial-JTAG（乐鑫 VID 0x303A），一行一则 JSON（docs/protocol.md「USB」）。
// 屏幕的 log 也走同一条线，只看 `{` 开头的行。

import Darwin
import Foundation
import IOKit
import IOKit.serial

/// 一个打开的串口。只在 BridgeServer 的 queue 上使用。
final class BridgeSerialPort: @unchecked Sendable {
    static let espressifVendorID = 0x303A
    /// 写不出去（屏幕没在读）时最多先存多少，超过就丢掉
    private static let maxPending = 1 << 20

    let path: String
    /// 最近一次收到 JSON 的时间；屏幕发了 hello 之后才算「连着」
    var lastReceived = Date.distantPast
    var isGreeted = false
    var isHelloPending = false

    private let fd: Int32
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private var writeSuspended = true
    private var pending = Data()
    private var lineBuffer = Data()
    private var isClosed = false

    /// 收到一行 JSON
    var onLine: ((Data) -> Void)?
    /// 拔掉 / 出错
    var onClose: (() -> Void)?

    init?(path: String, queue: DispatchQueue) {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var tio = termios()
        tcgetattr(fd, &tio)
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &tio)
        // DTR / RTS 维持打开时的状态：先放开 DTR、只留 RTS 会让板子停在重开状态（tools/serial-log.py）
        self.path = path
        self.fd = fd
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        writeSource.setEventHandler { [weak self] in self?.flush() }
        readSource.setCancelHandler { Darwin.close(fd) }
        readSource.resume()
    }

    func send(_ data: Data) {
        guard !isClosed else { return }
        if pending.count + data.count > Self.maxPending { pending.removeAll() }
        pending.append(data)
        pending.append(0x0A)
        flush()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if writeSuspended { writeSource.resume() } // 暂停中的 source 不能直接 cancel
        writeSource.cancel()
        readSource.cancel()
        onClose?()
    }

    private func flush() {
        while !pending.isEmpty {
            let n = pending.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.removeFirst(n)
            } else if n < 0, errno == EAGAIN {
                break
            } else {
                return close()
            }
        }
        // 还有没写完的就等可以写再继续
        if pending.isEmpty != writeSuspended {
            writeSuspended ? writeSource.resume() : writeSource.suspend()
            writeSuspended.toggle()
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else {
            if n == 0 || errno != EAGAIN { close() }
            return
        }
        lineBuffer.append(contentsOf: buffer[0..<n])
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            if line.first == UInt8(ascii: "{") { onLine?(Data(line)) }
        }
        if lineBuffer.count > 64 * 1024 { lineBuffer.removeAll() } // log 乱码，不会是讯息
    }

    /// 目前接着的乐鑫芯片串口（/dev/cu.*）
    static func espressifPorts() -> [String] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(mach_port_t(MACH_PORT_NULL), matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var paths: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String,
                let vendor = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault, options)
                as? Int,
                vendor == espressifVendorID else { continue }
            paths.append(path)
        }
        return paths
    }
}
