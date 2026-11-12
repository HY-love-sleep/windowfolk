import PropertyBased
@testable import WindowfolkCore

// 窗口与屏幕相关的共享生成器（design.md「生成器」表）。
// 注意：在 `extension Gen where Value == X` 内部，裸写的 `Gen` 指 `Gen<X>`，
// 因此调用库自带生成器时要写明 `Gen<Int>`、`Gen<Double>`。

/// 生成器中视为「本进程」的 pid，与 `Gen.rawWindowList` 配合使用。
let testOwnPID: Int32 = 999

private let commonScreenSizes: [(Double, Double)] = [
    (1440, 900), (1512, 982), (1728, 1117), (1920, 1080),
    (2560, 1440), (3008, 1692), (1280, 800),
]
private let menuBarHeights: [Double] = [24, 25, 37]  // 含刘海屏
private let oddSizes: [Double] = [.nan, -40, -.infinity, .infinity, 119.5, 0]
private let oddLayers: [Int] = [25, 3, -1, 101]

extension Gen where Value == ScreenInfo {
    /// 常见主显示器尺寸，加随机菜单栏高度和 Dock 位置与大小。高度 ≤ 3000pt。
    static var screen: Generator<ScreenInfo, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...(commonScreenSizes.count - 1)),
            Gen<Int>.int(in: 0...(menuBarHeights.count - 1)),
            Gen<Int>.int(in: 0...3),               // Dock：0 隐藏、1 底部、2 左侧、3 右侧
            Gen<Double>.double(in: 30...120)       // Dock 厚度
        ).map { sizeIndex, menuIndex, dockPos, dock in
            let (w, h) = commonScreenSizes[sizeIndex]
            let menuBar = menuBarHeights[menuIndex]
            let frame = Rect(minX: 0, minY: 0, width: w, height: h)
            var visible = Rect(minX: 0, minY: menuBar, width: w, height: h - menuBar)
            switch dockPos {
            case 1: visible.height -= dock
            case 2: visible.minX += dock; visible.width -= dock
            case 3: visible.width -= dock
            default: break
            }
            return ScreenInfo(frame: frame, visibleFrame: visible)
        }
    }
}

extension Gen where Value == RawWindowInfo {
    /// 单个原始窗口条目，`id` 由 `rawWindowList` 重新分配。
    /// 混入 layer ≠ 0、alpha 为 0、过小、本进程、屏幕外和非法尺寸（NaN、负数、无穷）的条目。
    static var rawWindow: Generator<RawWindowInfo, some SendableSequenceType> {
        zip(
            Gen<Int>.int(in: 0...9),                  // 条目类别，7 到 9 为普通窗口
            Gen<Double>.double(in: -800...2600),      // minX（约一半条目的中心落在屏外）
            Gen<Double>.double(in: -400...1600),      // minY
            Gen<Double>.double(in: 0...1600),         // width
            Gen<Double>.double(in: 0...1200),         // height
            Gen<Int>.int(in: 0...(oddSizes.count - 1))
        ).map { kind, x, y, w, h, oddIndex in
            var info = RawWindowInfo(
                id: 0, ownerName: "App", ownerPID: Int32(100 + kind),
                bounds: Rect(minX: x, minY: y, width: max(w, 120), height: max(h, 120)),
                layer: 0, alpha: 1, isOnScreen: true
            )
            switch kind {
            case 0: info.layer = oddLayers[Int(w) % oddLayers.count]
            case 1: info.alpha = 0
            case 2: info.bounds.width = w.truncatingRemainder(dividingBy: 130)   // 常常过窄
            case 3: info.bounds.height = h.truncatingRemainder(dividingBy: 130)  // 常常过矮
            case 4: info.ownerPID = testOwnPID
            case 5:
                if Int(w) % 2 == 0 { info.bounds.width = oddSizes[oddIndex] }
                else { info.bounds.height = oddSizes[oddIndex] }
            case 6: info.alpha = h / 1200                                       // 0 到 1 之间的透明度
            default: break
            }
            return info
        }
    }

    /// 若干原始窗口条目（默认 0 到 20 个），id 从 `firstID` 起连续编号，ownerName 为 `App<id>`。
    static func rawWindowList(firstID: WindowID = 1, count: ClosedRange<Int> = 0...20)
        -> Generator<[RawWindowInfo], some SendableSequenceType>
    {
        rawWindow.array(of: count).map { list in
            list.enumerated().map { i, raw in
                var r = raw
                r.id = firstID + WindowID(i)
                r.ownerName = "App\(r.id)"
                return r
            }
        }
    }
}
