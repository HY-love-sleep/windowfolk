import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WindowfolkArtIO
import WindowfolkArtKit

/// PNG 编解码与 CoreGraphics 缩放（R4.1、R4.4、R6.2）的单元测试（任务 10.2）。全部在内存中完成。
@Suite struct PNGCodecTests {

    // MARK: - 辅助

    /// 用 ImageIO 把 `CGImage` 编码为指定类型的数据。
    private static func encode(_ image: CGImage, type: UTType) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// 由每像素 4 字节（第 4 字节被忽略）构造不含 alpha 的 sRGB `noneSkipLast` 图像。
    private static func opaqueCGImage(width: Int, height: Int, bytes: [UInt8]) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// alpha 只取 0 或 255 的测试图；alpha 为 0 的像素用 `(0,0,0,0)`。
    private static func mixedAlphaImage(width: Int, height: Int) -> RGBAImage {
        var image = RGBAImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width where (x + 2 * y) % 3 != 0 {
                image[x, y] = RGBA(r: UInt8((x * 37 + y * 11) % 256),
                                   g: UInt8((x * 5 + y * 73) % 256),
                                   b: UInt8((x * y * 13 + 7) % 256),
                                   a: 255)
            }
        }
        return image
    }

    // MARK: - 编解码

    @Test func encodeThenDecodeKeepsEveryPixel() throws {
        let image = Self.mixedAlphaImage(width: 13, height: 7)
        let decoded = try #require(PNGCodec.decode(PNGCodec.encode(image)))
        #expect(decoded.hasAlpha)
        #expect(decoded.image.width == image.width && decoded.image.height == image.height)
        for y in 0..<image.height {
            for x in 0..<image.width where decoded.image[x, y] != image[x, y] {
                Issue.record("像素 (\(x), \(y))：\(image[x, y]) → \(decoded.image[x, y])")
            }
        }
    }

    @Test func roundTripOfExtremeValuesAndSinglePixel() throws {
        let colors: [RGBA] = [.clear,
                              RGBA(r: 0, g: 0, b: 0, a: 255),
                              RGBA(r: 255, g: 255, b: 255, a: 255),
                              RGBA(r: 255, g: 0, b: 128, a: 255)]
        for color in colors {
            let image = RGBAImage(width: 1, height: 1, fill: color)
            let decoded = try #require(PNGCodec.decode(PNGCodec.encode(image)))
            #expect(decoded.image == image, "\(color)")
            #expect(decoded.hasAlpha)
        }
    }

    @Test func encodedPNGIsEightBitWithAlpha() throws {
        let data = PNGCodec.encode(Self.mixedAlphaImage(width: 4, height: 4))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyDepth] as? Int == 8)
        #expect(properties[kCGImagePropertyHasAlpha] as? Bool == true)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 4)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 4)
    }

    @Test func pngWithoutAlphaReportsNoAlphaAndOpaquePixels() throws {
        let width = 3, height = 2
        var bytes = [UInt8]()
        for i in 0..<(width * height) {
            // 第 4 字节为被跳过的填充位，故意填 0，解码后 alpha 仍应为 255。
            bytes += [UInt8(i * 40), UInt8(200 - i * 30), UInt8(i * 7), 0]
        }
        let data = Self.encode(Self.opaqueCGImage(width: width, height: height, bytes: bytes),
                               type: .png)
        let decoded = try #require(PNGCodec.decode(data))
        #expect(decoded.hasAlpha == false)
        #expect(decoded.image.width == width && decoded.image.height == height)
        for i in 0..<(width * height) {
            let p = decoded.image[i % width, i / width]
            #expect(p == RGBA(r: bytes[i * 4], g: bytes[i * 4 + 1], b: bytes[i * 4 + 2], a: 255),
                    "像素 \(i)：\(p)")
        }
    }

    @Test func nonPNGDataDecodesToNil() {
        #expect(PNGCodec.decode(Data()) == nil)
        #expect(PNGCodec.decode(Data("not a png".utf8)) == nil)

        // PNG 签名后跟垃圾数据。
        let truncated = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
        #expect(PNGCodec.decode(truncated) == nil)

        // 能被 ImageIO 解码、但类型不是 PNG 的图像。
        let image = Self.opaqueCGImage(width: 2, height: 2, bytes: [UInt8](repeating: 128, count: 16))
        let jpeg = Self.encode(image, type: .jpeg)
        #expect(!jpeg.isEmpty)
        #expect(PNGCodec.decode(jpeg) == nil)
    }

    // MARK: - CGResampler

    @Test func resamplerOutputHasRequestedSize() {
        let source = Self.mixedAlphaImage(width: 12, height: 8)
        let sizes = [PixelSize(width: 24, height: 16), PixelSize(width: 5, height: 3),
                     PixelSize(width: 1, height: 1), PixelSize(width: 30, height: 2)]
        for size in sizes {
            let output = CGResampler().resize(source, to: size)
            #expect(output.width == size.width && output.height == size.height, "\(size)")
            #expect(output.pixels.count == size.width * size.height * 4)
        }
    }

    @Test func resamplerEmptyCasesReturnTransparentImage() {
        let source = Self.mixedAlphaImage(width: 4, height: 4)
        #expect(CGResampler().resize(source, to: PixelSize(width: 0, height: 5))
                == RGBAImage(width: 0, height: 5))
        #expect(CGResampler().resize(source, to: PixelSize(width: 3, height: 0))
                == RGBAImage(width: 3, height: 0))
        #expect(CGResampler().resize(RGBAImage(width: 0, height: 0), to: PixelSize(width: 3, height: 2))
                == RGBAImage(width: 3, height: 2))
    }

    @Test func resamplerSameSizeReturnsInput() {
        let source = Self.mixedAlphaImage(width: 6, height: 5)
        #expect(CGResampler().resize(source, to: PixelSize(width: 6, height: 5)) == source)
    }

    @Test func resamplerDoesNotDarkenTransparentEdges() {
        // 透明背景 (0,0,0,0) 中央一块不透明白色；放大和缩小后，半透明边缘的颜色应仍接近白色。
        var source = RGBAImage(width: 8, height: 8)
        for y in 2..<6 {
            for x in 2..<6 { source[x, y] = RGBA(r: 255, g: 255, b: 255, a: 255) }
        }
        for size in [PixelSize(width: 21, height: 21), PixelSize(width: 5, height: 5)] {
            let output = CGResampler().resize(source, to: size)
            var sawPartial = false
            for y in 0..<output.height {
                for x in 0..<output.width {
                    let p = output[x, y]
                    if p.a > 0 && p.a < 255 { sawPartial = true }
                    // 极低 alpha 的反预乘有量化误差，只检查 alpha ≥ 32 的像素。
                    if p.a >= 32 && min(p.r, p.g, p.b) < 240 {
                        Issue.record("\(size) 像素 (\(x), \(y)) 边缘发黑：\(p)")
                    }
                }
            }
            #expect(sawPartial, "\(size) 应产生半透明边缘，否则本测试没有意义")
        }
    }
}
