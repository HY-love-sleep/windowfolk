import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WindowfolkArtKit

/// PNG 编解码（R4.1、R6.2）。像素统一为 sRGB、8 位、非预乘 RGBA，行优先、从上到下。
public enum PNGCodec {
    /// 解码 PNG。数据不是 PNG 或无法解码时返回 nil（规则「文件格式」）。
    ///
    /// `hasAlpha` 取自 `CGImage.alphaInfo`：`none`、`noneSkipFirst`、`noneSkipLast` 视为不含 alpha，
    /// 此时像素按不透明（alpha = 255）填充。像素先画进 sRGB `premultipliedLast` 上下文再反预乘，
    /// 因此 alpha 为 0 的像素解码为 `(0, 0, 0, 0)`。
    public static func decode(_ data: Data) -> DecodedPNG? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              type == UTType.png.identifier,
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let hasAlpha: Bool
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }

        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0,
              let premultiplied = PixelBridge.drawPremultiplied(cgImage, width: width, height: height)
        else { return nil }
        let image = RGBAImage(width: width, height: height,
                              pixels: PixelBridge.unpremultiply(premultiplied))
        return DecodedPNG(image: image, hasAlpha: hasAlpha)
    }

    /// 编码为 8 位 RGBA PNG（颜色类型含 alpha，非预乘，sRGB）。图像宽高必须大于 0。
    public static func encode(_ image: RGBAImage) -> Data {
        precondition(image.width > 0 && image.height > 0, "PNG 图像尺寸必须大于 0")
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData),
              let cgImage = CGImage(width: image.width, height: image.height,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: image.width * 4,
                                    space: PixelBridge.sRGB, bitmapInfo: bitmapInfo,
                                    provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent)
        else { preconditionFailure("无法构造 CGImage") }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { preconditionFailure("无法创建 PNG 输出") }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { preconditionFailure("PNG 编码失败") }
        return output as Data
    }
}

/// 预乘 / 非预乘像素与 CoreGraphics 之间的转换，供 `PNGCodec` 与 `CGResampler` 共用。
enum PixelBridge {
    static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 8 位 sRGB `premultipliedLast` 位图上下文，初始全透明。
    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 把 `image` 画满 `width × height` 的预乘上下文，返回行优先、从上到下的预乘 RGBA 字节。
    static func drawPremultiplied(_ image: CGImage, width: Int, height: Int,
                                  quality: CGInterpolationQuality = .none) -> [UInt8]? {
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.interpolationQuality = quality
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes(of: context)
    }

    /// 读出上下文的像素。CGBitmapContext 内存第一行即图像顶行，与 `RGBAImage` 行序一致。
    static func bytes(of context: CGContext) -> [UInt8]? {
        guard let data = context.data else { return nil }
        let width = context.width, height = context.height, rowBytes = context.bytesPerRow
        let base = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let src = base + y * rowBytes
            out.withUnsafeMutableBufferPointer { buffer in
                (buffer.baseAddress! + y * width * 4).update(from: src, count: width * 4)
            }
        }
        return out
    }

    /// 非预乘 → 预乘：`c' = round(c · a / 255)`。
    static func premultiply(_ pixels: [UInt8]) -> [UInt8] {
        var out = pixels
        var i = 0
        while i < out.count {
            let a = UInt32(out[i + 3])
            if a == 0 {
                out[i] = 0; out[i + 1] = 0; out[i + 2] = 0
            } else if a < 255 {
                for c in 0..<3 { out[i + c] = UInt8((UInt32(out[i + c]) * a + 127) / 255) }
            }
            i += 4
        }
        return out
    }

    /// 预乘 → 非预乘：`c = min(255, round(c' · 255 / a))`；alpha 为 0 的像素颜色置 0。
    static func unpremultiply(_ pixels: [UInt8]) -> [UInt8] {
        var out = pixels
        var i = 0
        while i < out.count {
            let a = UInt32(out[i + 3])
            if a == 0 {
                out[i] = 0; out[i + 1] = 0; out[i + 2] = 0
            } else if a < 255 {
                for c in 0..<3 {
                    out[i + c] = UInt8(min(255, (UInt32(out[i + c]) * 255 + a / 2) / a))
                }
            }
            i += 4
        }
        return out
    }

    /// 由预乘 RGBA 字节构造 sRGB `premultipliedLast` 的 `CGImage`。
    static func makePremultipliedImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}
