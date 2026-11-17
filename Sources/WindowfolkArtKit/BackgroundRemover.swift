import Foundation
import WindowfolkCore

/// 去背景（R4.3）：以四角中 alpha > 0 的像素的平均 RGB 为背景色，
/// 从四条边上的全部像素出发做 4 邻域洪泛，把与边缘连通的背景像素设为 `(0,0,0,0)`。
///
/// 可通过的像素：alpha = 0，或 R、G、B 每个通道与背景色相差都不超过 `tolerance`。
/// 四角都透明时没有背景色，原样返回。
/// 是否跳过（输入已等于 Expected_Pixel_Size）由调用方 `PostProcessor` 判断。
public enum BackgroundRemover {
    public static func remove(_ image: RGBAImage, tolerance: Int = 24) -> RGBAImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let bg = backgroundColor(of: image) else { return image }

        let px = image.pixels
        func passable(_ index: Int) -> Bool {
            let o = index * 4
            if px[o + 3] == 0 { return true }
            return abs(Int(px[o]) - bg.r) <= tolerance
                && abs(Int(px[o + 1]) - bg.g) <= tolerance
                && abs(Int(px[o + 2]) - bg.b) <= tolerance
        }

        var visited = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        stack.reserveCapacity(2 * (w + h))

        func push(_ index: Int) {
            guard !visited[index], passable(index) else { return }
            visited[index] = true
            stack.append(index)
        }

        // 种子：四条边上的全部像素。
        for x in 0..<w {
            push(x)
            push((h - 1) * w + x)
        }
        for y in 0..<h {
            push(y * w)
            push(y * w + w - 1)
        }

        var out = px
        while let index = stack.popLast() {
            let o = index * 4
            out[o] = 0
            out[o + 1] = 0
            out[o + 2] = 0
            out[o + 3] = 0

            let x = index % w, y = index / w
            if x > 0 { push(index - 1) }
            if x < w - 1 { push(index + 1) }
            if y > 0 { push(index - w) }
            if y < h - 1 { push(index + w) }
        }

        return RGBAImage(width: w, height: h, pixels: out)
    }

    /// 四角中 alpha > 0 的像素的平均 RGB（四舍五入到整数）；没有这样的角时返回 nil。
    static func backgroundColor(of image: RGBAImage) -> (r: Int, g: Int, b: Int)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]
        var sumR = 0, sumG = 0, sumB = 0, count = 0
        for (x, y) in corners {
            let p = image[x, y]
            guard p.a > 0 else { continue }
            sumR += Int(p.r)
            sumG += Int(p.g)
            sumB += Int(p.b)
            count += 1
        }
        guard count > 0 else { return nil }
        func avg(_ s: Int) -> Int { (s * 2 + count) / (count * 2) }
        return (avg(sumR), avg(sumG), avg(sumB))
    }
}
