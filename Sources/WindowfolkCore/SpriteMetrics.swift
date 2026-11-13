import Foundation

/// 各类对象在 Overlay 中显示图形的尺寸与外接矩形（Core 坐标，y 向下）。
///
/// 尺寸全部取自 `AssetCatalog`，保证命中区域与绘制的图形一致（Requirement 7.1、25.3）。
/// 定位约定：居民和物件以「底边中点」定位，底边与所站 Surface 重合；
/// 已架设木板的上表面就是 Surface 线段，木板厚度向下延伸；
/// 已架设梯子从上端（窗沿）竖直延伸到下端（落点 Surface）。
public enum SpriteMetrics {
    public static let resident = AssetCatalog.residentSize
    public static let flower = AssetCatalog.flowerSize
    public static let fruit = AssetCatalog.fruitSize
    public static let toolbox = AssetCatalog.toolboxSize
    public static let bubble = AssetCatalog.bubbleSize
    public static let chair = AssetCatalog.chairSize
    public static let lamp = AssetCatalog.lampSize
    public static let visitFlag = AssetCatalog.visitFlagSize
    /// 木板厚度（平铺单元高度）。
    public static var plankThickness: Double { AssetCatalog.plankTileSize.height }
    /// 梯子宽度（平铺单元宽度）。
    public static var ladderWidth: Double { AssetCatalog.ladderTileSize.width }

    /// 落下（未架设）或拖动中、无吸附时木板平放的显示长度（pt）：4 个平铺单元。
    public static var loosePlankLength: Double { AssetCatalog.plankTileSize.width * 4 }
    /// 落下（未架设）或拖动中、无吸附时梯子平放的显示长度（pt）：3 个平铺单元。
    /// 平放时梯子旋转 90°，显示高度等于平铺单元宽度。
    public static var looseLadderLength: Double { AssetCatalog.ladderTileSize.height * 3 }

    // MARK: - 外接矩形

    /// 以底边中点定位、尺寸为 `size` 的图形的外接矩形。
    /// `lift` 为向上的显示偏移（例如戳居民时的跳跃高度），单位 pt，向上为正。
    public static func rect(size: AssetSize, bottomCenter p: Point, lift: Double = 0) -> Rect {
        Rect(minX: p.x - size.width / 2, minY: p.y - size.height - lift, width: size.width, height: size.height)
    }

    /// 居民图形的外接矩形。`bottomCenter` 为居民底边中点（即 `ResidentView.position`）。
    public static func residentRect(bottomCenter p: Point, lift: Double = 0) -> Rect {
        rect(size: resident, bottomCenter: p, lift: lift)
    }

    /// 坐在 Chair 上的居民相对所站 Surface 的显示上移量（pt）。
    public static let chairSeatHeight: Double = 10

    /// 居民按状态的显示上移量：`sitting` 时为 `chairSeatHeight`，其余为 0。
    public static func residentSeatLift(_ state: ResidentState) -> Double {
        state == .sitting ? chairSeatHeight : 0
    }

    /// 物件图形尺寸：Flower 为花盆尺寸（各生长阶段相同），Fruit 为果子尺寸。
    public static func itemSize(_ kind: ItemKind) -> AssetSize {
        switch kind {
        case .flower: return flower
        case .fruit: return fruit
        }
    }

    /// 物件图形的外接矩形，以底边中点定位（即 `ItemView.position`）。
    public static func itemRect(kind: ItemKind, bottomCenter p: Point, lift: Double = 0) -> Rect {
        rect(size: itemSize(kind), bottomCenter: p, lift: lift)
    }

    /// Decor 图形尺寸：Chair 24×24，Lamp 16×32。
    public static func decorSize(_ type: DecorType) -> AssetSize {
        switch type {
        case .chair: return chair
        case .lamp: return lamp
        }
    }

    /// Decor 图形的外接矩形，以底边中点定位（即 `DecorView.position`）。
    public static func decorRect(type: DecorType, bottomCenter p: Point) -> Rect {
        rect(size: decorSize(type), bottomCenter: p)
    }

    /// Visit_Flag 图形的外接矩形，以底边中点定位（即 `WorldView.visitFlags` 中的点）。
    public static func visitFlagRect(bottomCenter p: Point) -> Rect {
        rect(size: visitFlag, bottomCenter: p)
    }

    /// 已架设木板的外接矩形：覆盖两端点之间的线段，并向下延伸木板厚度。木板可以倾斜。
    public static func placedPlankRect(from a: Point, to b: Point) -> Rect {
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let minY = min(a.y, b.y), maxY = max(a.y, b.y) + plankThickness
        return Rect(minX: minX, minY: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 平放木板（落下或无吸附拖动）的外接矩形，以底边中点定位。
    public static func loosePlankRect(bottomCenter p: Point) -> Rect {
        rect(size: AssetSize(width: loosePlankLength, height: plankThickness), bottomCenter: p)
    }

    /// 已架设梯子的外接矩形：以上端 x 为中心、宽为梯子宽度，从上端 y 延伸到下端 y。
    public static func placedLadderRect(top: Point, bottom: Point) -> Rect {
        let minY = min(top.y, bottom.y), maxY = max(top.y, bottom.y)
        return Rect(minX: top.x - ladderWidth / 2, minY: minY, width: ladderWidth, height: maxY - minY)
    }

    /// 平放梯子（落下或无吸附拖动）的外接矩形，以底边中点定位。
    public static func looseLadderRect(bottomCenter p: Point) -> Rect {
        rect(size: AssetSize(width: looseLadderLength, height: ladderWidth), bottomCenter: p)
    }
}
