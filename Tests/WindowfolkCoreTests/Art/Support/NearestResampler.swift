import WindowfolkArtKit

// 测试用最近邻缩放（design.md「属性测试」：不需要高质量缩放的属性用测试内的最近邻 `Resampler`）。
//
// 不插值、不混色：输出像素都是输入中某个像素的原值，因此纯色图形缩放后仍为纯色，alpha 只有原有的取值。
// 用法：`PostProcessor.process(raw, key: key, resampler: NearestResampler())`。

/// 最近邻 `Resampler`：目标像素 `(x, y)` 取源像素
/// `(⌊(x + 0.5) · 源宽 / 目标宽⌋, ⌊(y + 0.5) · 源高 / 目标高⌋)`，即目标像素中心对应的源像素。
/// 源图或目标尺寸为空时返回目标尺寸的全透明图像。
struct NearestResampler: Resampler {
    func resize(_ image: RGBAImage, to size: PixelSize) -> RGBAImage {
        let dw = max(0, size.width), dh = max(0, size.height)
        var out = RGBAImage(width: dw, height: dh)
        guard image.width > 0, image.height > 0, dw > 0, dh > 0 else { return out }
        // 整数运算：⌊(2x + 1) · sw / (2 · dw)⌋，结果落在 0..<sw。
        let sx = (0..<dw).map { x in min(image.width - 1, (2 * x + 1) * image.width / (2 * dw)) }
        for y in 0..<dh {
            let srcY = min(image.height - 1, (2 * y + 1) * image.height / (2 * dh))
            for x in 0..<dw {
                out[x, y] = image[sx[x], srcY]
            }
        }
        return out
    }
}
