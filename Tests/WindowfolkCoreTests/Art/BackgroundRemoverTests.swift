import Foundation
import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 去背景（R4.3）的测试（任务 6.4）。
@Suite struct BackgroundRemoverTests {

    // Feature: 美术, Property 9: 去背景只移除与边缘相连的背景
    // **Validates: Requirements 4.3**
    @Test func removesOnlyEdgeConnectedBackground() async {
        let input = Gen<RawImageSample>.rawImage(among: AssetCatalog.all.map(\.key))
        await propertyCheck(count: 200, input: input) { sample in
            let image = sample.image
            let output = BackgroundRemover.remove(image)
            #expect(output.width == image.width && output.height == image.height)

            if sample.isTransparentBackground {
                // 四角 alpha 都为 0：原样返回。
                #expect(output == image, "四角透明时输出应与输入相同：\(sample)")
                return
            }

            for y in 0..<image.height {
                for x in 0..<image.width {
                    if sample.isShapePixel(x: x, y: y) {
                        if output[x, y] != image[x, y] {
                            Issue.record("图形像素 (\(x), \(y)) 被改动：\(image[x, y]) → \(output[x, y])；\(sample)")
                            return
                        }
                    } else if output[x, y].a != 0 {
                        Issue.record("背景像素 (\(x), \(y)) 未被移除：\(output[x, y])；\(sample)")
                        return
                    }
                }
            }
        }
    }

    // MARK: - 示例

    /// 被图形包围、不与边缘相连的背景色像素保留。
    @Test func keepsEnclosedBackgroundColoredPixels() {
        let bg = RGBA(r: 100, g: 100, b: 100, a: 255)
        let red = RGBA(r: 220, g: 30, b: 30, a: 255)
        var image = RGBAImage(width: 7, height: 7, fill: bg)
        for y in 1...5 {
            for x in 1...5 where x == 1 || x == 5 || y == 1 || y == 5 { image[x, y] = red }
        }
        let output = BackgroundRemover.remove(image)
        #expect(output[3, 3] == bg, "环内背景色像素不应被移除")
        #expect(output[2, 2] == bg)
        #expect(output[1, 1] == red)
        #expect(output[0, 0] == .clear)
        #expect(output[6, 3] == .clear)
    }

    /// 每通道差 ≤ 24 可通过，任一通道差 25 则不可通过。
    @Test func toleranceIsInclusiveAt24() {
        let bg = RGBA(r: 100, g: 100, b: 100, a: 255)
        var image = RGBAImage(width: 5, height: 3, fill: bg)
        image[1, 0] = RGBA(r: 124, g: 76, b: 124, a: 255)
        image[3, 0] = RGBA(r: 125, g: 100, b: 100, a: 255)
        let output = BackgroundRemover.remove(image)
        #expect(output[1, 0] == .clear)
        #expect(output[3, 0] == image[3, 0])
        #expect(output[2, 1] == .clear)
    }
}
