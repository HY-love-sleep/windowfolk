import Foundation
import WindowfolkCore

// Character_Sheet 固定布局（design.md「Character_Sheet 布局」，R1.1、R1.5）。
//
// 1536×720 透明画布：
// - 上方一行三个 512×640 视图格，从左到右依次放正面、朝右侧面、背面。
//   每个视图缩放到不透明边界框高度 560 像素（宽度超出格宽时改为按格宽缩放），
//   最下方不透明行贴格底，边界框水平居中。
// - 下方一行 5 个 48×48 纯色块，左上角 `x = 16 + i·64`、`y = 656`，
//   按 main、shadow、highlight、outline、blush 顺序由程序直接填色，alpha 为 255。
//
// 读写 PNG、把原始图三等分和去背景由调用方（`sheet compose` 子命令）完成。

public enum SheetLayout {
    /// 视图格尺寸；三个格在上方一行无间隔排列。
    public static let viewCell = PixelSize(width: 512, height: 640)
    /// 视图数量：正面、朝右侧面、背面。
    public static let viewCount = 3
    /// 每个视图不透明边界框的最小高度（R1.1）。
    public static let viewMinHeight = 256
    /// 视图缩放的目标边界框高度。
    public static let viewTargetHeight = 560
    /// 色块边长（≥ 32，R1.1）。
    public static let swatchSize = 48
    /// 相邻色块左边缘的间距。
    public static let swatchPitch = 64
    /// 第一个色块左边缘的 x 坐标。
    public static let swatchLeft = 16
    /// 色块行上边缘的 y 坐标。
    public static let swatchRowTop = 656
    /// 色块顺序，即居民 Palette 的固定顺序。
    public static let swatchOrder: [PaletteColorName] = PaletteColorName.allCases

    public static var canvas: PixelSize {
        PixelSize(width: viewCell.width * viewCount, height: 720)
    }

    /// 第 i 个视图格（0 正面、1 侧面、2 背面）。
    public static func viewCellRect(_ i: Int) -> PixelRect {
        PixelRect(x: i * viewCell.width, y: 0, width: viewCell.width, height: viewCell.height)
    }

    /// 第 i 个色块（从 0 起）的矩形。
    public static func swatchRect(_ i: Int) -> PixelRect {
        PixelRect(x: swatchLeft + i * swatchPitch, y: swatchRowTop, width: swatchSize, height: swatchSize)
    }

    /// 按 `swatchOrder` 取出居民 Palette 的 5 个颜色；缺任一色时返回 nil。
    public static func swatchColors(_ palette: [PaletteColorName: RGB]) -> [RGB]? {
        var colors: [RGB] = []
        colors.reserveCapacity(swatchOrder.count)
        for name in swatchOrder {
            guard let color = palette[name] else { return nil }
            colors.append(color)
        }
        return colors
    }

    /// 排版一张 Character_Sheet。
    ///
    /// - Parameters:
    ///   - views: 已去背景的三个视图，依次为正面、朝右侧面、背面；尺寸任意。
    ///     没有 alpha ≥ 128 像素的视图对应的格留空。
    ///   - palette: 5 个颜色，顺序为 main、shadow、highlight、outline、blush（见 `swatchColors`）。
    ///   - resampler: 缩放视图用的重采样器。
    /// - Returns: `canvas` 大小的非预乘 RGBA 图像，视图格与色块以外的像素全透明。
    public static func compose(views: [RGBAImage], palette: [RGB], resampler: Resampler) -> RGBAImage {
        precondition(views.count == viewCount, "设定图需要恰好 \(viewCount) 个视图")
        precondition(palette.count == swatchOrder.count, "设定图需要恰好 \(swatchOrder.count) 个色块颜色")

        var sheet = RGBAImage(width: canvas.width, height: canvas.height)
        for (i, view) in views.enumerated() {
            guard let placed = placedView(view, resampler: resampler) else { continue }
            let cell = viewCellRect(i)
            sheet.paste(placed.image, at: PixelPoint(x: cell.x + placed.origin.x, y: cell.y + placed.origin.y))
        }
        for (i, color) in palette.enumerated() {
            let rect = swatchRect(i)
            let block = RGBAImage(width: rect.width, height: rect.height,
                                  fill: RGBA(r: color.r, g: color.g, b: color.b, a: 255))
            sheet.paste(block, at: PixelPoint(x: rect.x, y: rect.y))
        }
        return sheet
    }

    // MARK: 内部

    /// 缩放后的视图及其在视图格内的左上角；图像已裁剪到格内。
    struct PlacedView {
        var image: RGBAImage
        var origin: PixelPoint
    }

    /// 缩放比例：边界框高度到 `viewTargetHeight`，但宽度不超过格宽。
    static func scale(for bounds: PixelRect) -> Double {
        min(Double(viewTargetHeight) / Double(bounds.height), Double(viewCell.width) / Double(bounds.width))
    }

    static func placedView(_ view: RGBAImage, resampler: Resampler) -> PlacedView? {
        guard let bounds = view.opaqueBounds() else { return nil }
        let s = scale(for: bounds)
        let target = PixelSize(
            width: min(viewCell.width, max(1, Int((Double(bounds.width) * s).rounded()))),
            height: min(viewTargetHeight, max(1, Int((Double(bounds.height) * s).rounded())))
        )
        let resized = resampler.resize(view.crop(bounds), to: target)
        // 以缩放后小图自身的不透明边界框对齐：底行贴格底，水平居中。
        guard let ob = resized.opaqueBounds() else { return nil }
        let originX = (viewCell.width - ob.width) / 2 - ob.x
        let originY = viewCell.height - ob.maxY
        // 只保留落在格内的部分，避免边缘半透明像素写进相邻格或色块行。
        let cell = PixelRect(x: 0, y: 0, width: viewCell.width, height: viewCell.height)
        let placedRect = PixelRect(x: originX, y: originY, width: resized.width, height: resized.height)
        guard let visible = placedRect.intersection(cell) else { return nil }
        let image = resized.crop(visible.offsetBy(dx: -originX, dy: -originY))
        return PlacedView(image: image, origin: PixelPoint(x: visible.x, y: visible.y))
    }
}
