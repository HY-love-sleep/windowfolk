import CoreGraphics
import CoreText
import Foundation
import WindowfolkArtKit
import WindowfolkCore

/// 按 `PreviewLayout` 绘制深色或浅色总览图（R7.1–R7.5）。
///
/// - 背景：`PreviewTheme.background` 单一纯色填满画布，不用渐变或棋盘格（R7.2）。
/// - 帧：按 `FrameSlicer` 把素材切成帧，逐帧画进 `Strip.frameRects`，与背景做 source-over 合成。
///   比例 2 的帧矩形与素材每帧像素等大，用 `interpolationQuality = .none` 原样画；
///   比例 1 缩小到 pt 尺寸，用 `.high` 高质量缩放（R7.5）。
/// - 文字：CoreText 系统字体 12pt（画布 1 像素 = 1pt，即 12 像素），颜色为 `PreviewTheme.foreground`，
///   在 `labelRect` 写 Asset_Key（R7.3），在 `Marker.textRect` 写「缺失」或未通过规则名称（R7.4）。
/// - 标记：`Marker.rect`（Expected_Pixel_Size 大小）填 `PreviewTheme.markerFill`。
///
/// 坐标沿用 `PixelRect`：原点在左上角、y 向下。内部换算到 CoreGraphics 的 y 向上坐标。
public enum PreviewRenderer {
    /// 标签与标记文字的字号（pt）。总览图按 1 像素 = 1pt 绘制，文字高度 ≥ 10 像素（R7.3）。
    public static let fontSize: CGFloat = 12

    /// 绘制一张总览图。
    ///
    /// `images` 为正常显示（有帧条）的键对应的已解码素材，尺寸应为 Expected_Pixel_Size。
    /// 布局中有帧条但 `images` 里没有该键、或图像宽度小于帧数时，该行只画标签。
    public static func render(layout: PreviewLayout, images: [String: RGBAImage],
                              theme: PreviewTheme) -> RGBAImage {
        let width = layout.canvas.width, height = layout.canvas.height
        guard width > 0, height > 0 else { return RGBAImage(width: max(0, width), height: max(0, height)) }
        guard let context = PixelBridge.makeContext(width: width, height: height) else {
            preconditionFailure("无法创建总览图上下文")
        }
        let canvasHeight = height

        // 背景（R7.2）。
        context.setBlendMode(.copy)
        context.setFillColor(cgColor(theme.background))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.normal)

        let specs = Dictionary(uniqueKeysWithValues: AssetCatalog.all.map { ($0.key, $0) })
        let font = systemFont()
        let textColor = cgColor(theme.foreground)

        for row in layout.rows {
            drawText(row.key, in: row.labelRect, context: context, canvasHeight: canvasHeight,
                     font: font, color: textColor)

            if let marker = row.marker {
                context.setFillColor(cgColor(theme.markerFill))
                context.fill(cgRect(marker.rect, canvasHeight: canvasHeight))
                drawText(marker.text, in: marker.textRect, context: context, canvasHeight: canvasHeight,
                         font: font, color: textColor)
                continue
            }

            guard !row.strips.isEmpty, let image = images[row.key], let spec = specs[row.key],
                  image.height > 0, image.width >= spec.frames else { continue }
            let frames = frameImages(image, frames: spec.frames)
            for strip in row.strips {
                context.interpolationQuality = strip.scale == 2 ? .none : .high
                for (rect, frame) in zip(strip.frameRects, frames) {
                    context.draw(frame, in: cgRect(rect, canvasHeight: canvasHeight))
                }
            }
        }

        guard let bytes = PixelBridge.bytes(of: context) else {
            preconditionFailure("无法读取总览图像素")
        }
        return RGBAImage(width: width, height: height, pixels: PixelBridge.unpremultiply(bytes))
    }

    /// 绘制并编码为 PNG（`PNGCodec.encode`）。
    public static func renderPNG(layout: PreviewLayout, images: [String: RGBAImage],
                                 theme: PreviewTheme) -> Data {
        PNGCodec.encode(render(layout: layout, images: images, theme: theme))
    }

    /// 按 `verdicts` 生成布局（`PreviewLayout.make(verdicts:)`），为每个主题各画一张 PNG。
    /// 返回顺序同 `PreviewTheme.allCases`（深色、浅色），文件名取 `PreviewTheme.fileName`。
    public static func renderAll(verdicts: [String: AssetVerdict],
                                 images: [String: RGBAImage]) -> [(theme: PreviewTheme, png: Data)] {
        let layout = PreviewLayout.make(verdicts: verdicts)
        return PreviewTheme.allCases.map { ($0, renderPNG(layout: layout, images: images, theme: $0)) }
    }

    // MARK: 内部

    /// 把素材切成帧并转成预乘 `CGImage`，供 source-over 合成。
    private static func frameImages(_ image: RGBAImage, frames: Int) -> [CGImage] {
        FrameSlicer.columnRanges(width: image.width, frames: frames).map { columns in
            let frame = image.crop(PixelRect(x: columns.lowerBound, y: 0,
                                             width: columns.count, height: image.height))
            guard let cg = PixelBridge.makePremultipliedImage(
                PixelBridge.premultiply(frame.pixels), width: frame.width, height: frame.height)
            else { preconditionFailure("无法构造帧图像") }
            return cg
        }
    }

    /// 在 `rect` 内左对齐、垂直居中绘制单行文字，超出 `rect` 的部分被裁掉。
    private static func drawText(_ text: String, in rect: PixelRect, context: CGContext,
                                 canvasHeight: Int, font: CTFont, color: CGColor) {
        guard !text.isEmpty, !rect.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        let box = cgRect(rect, canvasHeight: canvasHeight)
        let baseline = box.minY + ((box.height - (ascent + descent)) / 2).rounded() + descent.rounded()

        context.saveGState()
        context.clip(to: box)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: box.minX, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// 系统 UI 字体 12pt；取不到时退回 Helvetica。
    private static func systemFont() -> CTFont {
        CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    }

    /// 左上原点、y 向下的像素矩形 → CoreGraphics 左下原点、y 向上的矩形。
    private static func cgRect(_ r: PixelRect, canvasHeight: Int) -> CGRect {
        CGRect(x: r.x, y: canvasHeight - r.maxY, width: r.width, height: r.height)
    }

    private static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(colorSpace: PixelBridge.sRGB,
                components: [CGFloat(c.r) / 255, CGFloat(c.g) / 255, CGFloat(c.b) / 255, CGFloat(c.a) / 255])
            ?? CGColor(gray: 0, alpha: 1)
    }
}
