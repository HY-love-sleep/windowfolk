import Foundation

// Core 坐标系：原点在主显示器左上角，x 向右，y 向下，单位 pt（Requirement 2.4）。

public struct Point: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Rect: Hashable, Sendable, Codable {
    public var minX: Double
    public var minY: Double
    public var width: Double
    public var height: Double

    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    public var maxX: Double { minX + width }
    public var maxY: Double { minY + height }
    public var midX: Double { minX + width / 2 }
    public var midY: Double { minY + height / 2 }
    public var center: Point { Point(x: midX, y: midY) }

    /// 闭区间判定：点在矩形内或边上。
    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }
}

/// 闭区间，要求 lo <= hi。
public struct Interval: Hashable, Sendable {
    public var lo: Double
    public var hi: Double

    public init(lo: Double, hi: Double) {
        self.lo = lo
        self.hi = hi
    }

    public var length: Double { hi - lo }
}

public enum IntervalMath {
    /// 从 `base` 中减去所有 `cuts`。
    /// 结果按 lo 升序、互不重叠、每段长度 > 0。
    public static func subtract(_ base: Interval, _ cuts: [Interval]) -> [Interval] {
        guard base.hi > base.lo else { return [] }
        let sorted = cuts
            .filter { $0.hi > base.lo && $0.lo < base.hi && $0.hi >= $0.lo }
            .sorted { $0.lo < $1.lo || ($0.lo == $1.lo && $0.hi < $1.hi) }

        var result: [Interval] = []
        var cursor = base.lo
        for cut in sorted {
            if cut.lo > cursor {
                result.append(Interval(lo: cursor, hi: min(cut.lo, base.hi)))
            }
            cursor = max(cursor, cut.hi)
            if cursor >= base.hi { break }
        }
        if cursor < base.hi {
            result.append(Interval(lo: cursor, hi: base.hi))
        }
        return result.filter { $0.hi > $0.lo }
    }
}

public struct ScreenInfo: Hashable, Sendable, Codable {
    /// 主显示器完整 frame（Core 坐标，原点 0,0）
    public var frame: Rect
    /// 去掉菜单栏和 Dock 后的区域（Core 坐标）
    public var visibleFrame: Rect

    public init(frame: Rect, visibleFrame: Rect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    /// Ground 的 y 坐标：visibleFrame 底边（y 向下，因此为 maxY）。
    public var groundY: Double { visibleFrame.maxY }
}
