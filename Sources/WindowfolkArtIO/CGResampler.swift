import CoreGraphics
import WindowfolkArtKit

/// 基于 CoreGraphics 的高质量 `Resampler`（R4.4）。
///
/// 先把非预乘输入预乘，再以 `interpolationQuality = .high` 画到目标尺寸，最后反预乘。
/// 在预乘空间插值，透明像素的颜色不会混进边缘，避免透明边缘发黑。
public struct CGResampler: Resampler {
    public init() {}

    /// 源图或目标尺寸为空时返回目标尺寸（负值按 0）的全透明图像。
    public func resize(_ image: RGBAImage, to size: PixelSize) -> RGBAImage {
        let dw = max(0, size.width), dh = max(0, size.height)
        guard image.width > 0, image.height > 0, dw > 0, dh > 0 else {
            return RGBAImage(width: dw, height: dh)
        }
        if image.width == dw && image.height == dh { return image }

        guard let source = PixelBridge.makePremultipliedImage(
                  PixelBridge.premultiply(image.pixels), width: image.width, height: image.height),
              let drawn = PixelBridge.drawPremultiplied(source, width: dw, height: dh, quality: .high)
        else { preconditionFailure("CoreGraphics 缩放失败") }
        return RGBAImage(width: dw, height: dh, pixels: PixelBridge.unpremultiply(drawn))
    }
}
