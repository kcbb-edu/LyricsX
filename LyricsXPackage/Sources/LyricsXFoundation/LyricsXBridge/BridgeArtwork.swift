// LyricsXBridge — 不属于 LyricsX 原本的代码，见 docs/design.md、docs/display-design.md。
//
// 屏幕的封面和模糊背景：重的事都在 Mac 做、每首歌每种屏幕大小只做一次，屏幕只解码 JPEG。
//   - 封面来源：播放器给的 artwork；没有（Apple Music 串流的歌常常没有）就用 iTunes Search 的 600×600 封面
//   - 背景：缩小 → 模糊 → 按亮度加暗（白字对比够）→ 放大到屏幕大小

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum BridgeArtwork {
    /// 屏幕的硬件 JPEG 解码按 16 像素区块输出：宽高用 16 的倍数，屏幕再缩成 300 / 220 / 56
    public static let coverSize = 320

    // MARK: - iTunes 封面（后备）

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default // 用系统 URLCache，同一张图不重复下载
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }()

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            var trackTimeMillis: Double?
            var artworkUrl100: String?
        }

        var results: [Item]
    }

    /// 在 iTunes 商店找同一首歌的封面（长度最接近的那首），下载 600×600 的版本
    public static func lookup(title: String, artist: String, duration: TimeInterval, storefront: String) async -> CGImage? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "country", value: storefront),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url,
              let (data, _) = try? await session.data(from: url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return nil }
        func diff(_ item: SearchResponse.Item) -> Double {
            guard duration > 0, let ms = item.trackTimeMillis else { return .infinity }
            return abs(ms / 1000 - duration)
        }
        let items = response.results.filter { $0.artworkUrl100 != nil && (duration <= 0 || diff($0) <= 3) }
        guard let best = items.min(by: { diff($0) < diff($1) }),
              let large = URL(string: best.artworkUrl100!.replacingOccurrences(of: "100x100", with: "600x600")),
              let (imageData, _) = try? await session.data(from: large),
              let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - 产生 JPEG

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// 背景暗度 0（淡）– 1（深）→ 平均亮度、最亮处亮度的上限（线性），在两端之间按比例（对数）取。
    /// 白字在最亮处也要看得清楚；0.5 ≈ 平均 0.09、最亮 0.22
    static func dimLimits(_ dim: Double) -> (average: Double, brightest: Double) {
        let d = min(max(dim, 0), 1)
        func mix(_ light: Double, _ dark: Double) -> Double { light * pow(dark / light, d) }
        return (mix(0.25, 0.03), mix(0.60, 0.08))
    }

    /// 封面（coverSize²）和屏幕大小的背景（withBackground = false 时不做），都是 JPEG
    public static func render(_ image: CGImage, width: Int, height: Int, dim: Double,
                              withBackground: Bool) -> (cover: Data, background: Data?)? {
        guard let cover = draw(image, width: coverSize, height: coverSize).flatMap({ jpeg($0, quality: 0.85) }) else { return nil }
        guard withBackground, width > 0, height > 0 else { return (cover, nil) }
        let background = background(image, width: width, height: height, dim: dim).flatMap { jpeg($0, quality: 0.8) }
        return background.map { (cover, $0) }
    }

    /// 等比放大填满（裁掉多出来的部分）
    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        ctx.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    private static func background(_ image: CGImage, width: Int, height: Int, dim: Double) -> CGImage? {
        // 先缩到 1/8 再模糊：快，而且放大回去本来就是柔和的
        let sw = max(8, width / 8), sh = max(8, height / 8)
        guard let small = draw(image, width: sw, height: sh) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: sw, height: sh)
        var ci = CIImage(cgImage: small).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(min(sw, sh)) / 6)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
            .cropped(to: extent)
        // 加暗：看平均亮度，也看中间（歌词所在）那一带最亮的地方，两个都要压到上限以下。
        // 0.5：平均 0.09、最亮 0.22（线性）→ 白字对比平均 ≥ 7:1、最亮处 ≥ 3.9:1。最少也压到 80%，看起来有深度
        let band = CGRect(x: 0, y: Double(sh) * 0.25, width: Double(sw), height: Double(sh) * 0.5)
        let average = luminance(ci, filter: "CIAreaAverage", in: extent)
        let brightest = luminance(ci, filter: "CIAreaMaximum", in: band)
        let limits = dimLimits(dim)
        let linear = min(0.8, limits.average / max(average, 0.001), limits.brightest / max(brightest, 0.001))
        let k = pow(linear, 1 / 2.2)
        ci = ci.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        ])
        guard let dimmed = context.createCGImage(ci, from: extent) else { return nil }
        return draw(dimmed, width: width, height: height)
    }

    /// 某区域的相对亮度（0–1，线性）：CIAreaAverage = 平均、CIAreaMaximum = 最亮（每个颜色分开取最大，偏保守）
    private static func luminance(_ image: CIImage, filter: String, in rect: CGRect) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let result = image.applyingFilter(filter, parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        // 结果是 1×1 的图（位置跟着区域走，所以用它自己的范围）
        context.render(result, toBitmap: &pixel, rowBytes: 4, bounds: result.extent,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        func lin(_ v: UInt8) -> Double { pow(Double(v) / 255, 2.2) }
        return 0.2126 * lin(pixel[0]) + 0.7152 * lin(pixel[1]) + 0.0722 * lin(pixel[2])
    }

    /// 一般（baseline）JPEG：ESP32-P4 的硬件解码器不支援 progressive
    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
