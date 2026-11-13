import Foundation
import PropertyBased
import Testing
@testable import WindowfolkCore

/// 任意 visibleFrame（Dock 大小和位置任意变化，v1 Requirement 8.4），混入常见屏幕配置。
/// 从 v1 的 InteractionTests 迁入。
private var anyScreenGen: Generator<ScreenInfo, some SendableSequenceType> {
    zip(
        Gen<Bool>.bool,
        Gen<ScreenInfo>.screen,
        Gen<Double>.double(in: 0...300),     // 左侧裁掉的宽度
        Gen<Double>.double(in: 0...300),     // 右侧裁掉的宽度
        Gen<Double>.double(in: 0...60),      // 顶部（菜单栏）
        Gen<Double>.double(in: 0...300)      // 底部（Dock）
    ).map { useCommon, common, left, right, top, bottom in
        if useCommon { return common }
        let frame = common.frame
        let visible = Rect(
            minX: left, minY: top,
            width: frame.width - left - right, height: frame.height - top - bottom)
        return ScreenInfo(frame: frame, visibleFrame: visible)
    }
}

/// Unlocked_Decor 的任意子集（含空集，覆盖 Requirement 2.8 的 v1 布局）。
private var unlockedGen: Generator<Set<DecorType>, some SendableSequenceType> {
    zip(Gen<Bool>.bool, Gen<Bool>.bool).map { chair, lamp in
        var s = Set<DecorType>()
        if chair { s.insert(.chair) }
        if lamp { s.insert(.lamp) }
        return s
    }
}

/// `sub` 是否为 `full` 的子序列（保持相对顺序）。
private func isSubsequence(_ sub: [ToolboxZone], of full: [ToolboxZone]) -> Bool {
    var it = full.makeIterator()
    return sub.allSatisfy { z in
        while let next = it.next() { if next == z { return true } }
        return false
    }
}

@Suite struct ToolboxLayoutTests {
    // Feature: V2, Property 3: Toolbox 布局
    // 取代 v1 Property 15（v1 Requirement 8.1、8.4）：unlocked 为空时即 v1 的两区布局。
    // **Validates: Requirements 1.7, 2.1, 2.2, 2.8**
    @Test func toolboxLayoutWithDecorSlots() async {
        await propertyCheck(
            count: 200,
            input: anyScreenGen,
            unlockedGen,
            Gen<Double>.double(in: -0.2...1.2),   // 探测点在外框内的相对位置（含外侧）
            Gen<Double>.double(in: -0.2...1.2)
        ) { screen, unlocked, u, v in
            let zones = ToolboxLayout.zones(unlocked: unlocked)
            let f = ToolboxLayout.frame(screen: screen, unlocked: unlocked)

            // 顺序：[plank, ladder] 后接已解锁的 chair、lamp（Requirement 1.7、2.1、2.8）
            let expected: [ToolboxZone] = [.plank, .ladder]
                + [DecorType.chair, .lamp].filter(unlocked.contains).map(ToolboxZone.decor)
            #expect(zones == expected)

            // 底边与 Ground（visibleFrame 底边）对齐，右边距在 [0, 16]pt 内
            #expect(f.maxY == screen.visibleFrame.maxY)
            let gap = screen.visibleFrame.maxX - f.maxX
            #expect(gap >= 0 && gap <= 16, "右边距 \(gap)")
            #expect(f.width > 0 && f.height > 0)

            // 每个取物区非空、在外框内；未解锁的 Decor_Slot 没有矩形
            var frames: [(ToolboxZone, Rect)] = []
            for z in zones {
                guard let r = ToolboxLayout.zoneFrame(z, screen: screen, unlocked: unlocked) else {
                    Issue.record("已显示的取物区 \(z) 没有矩形")
                    continue
                }
                #expect(r.width > 0 && r.height > 0)
                #expect(r.minX >= f.minX && r.maxX <= f.maxX && r.minY >= f.minY && r.maxY <= f.maxY,
                        "取物区 \(z) 超出外框")
                frames.append((z, r))
            }
            for t in DecorType.allCases where !unlocked.contains(t) {
                #expect(ToolboxLayout.zoneFrame(.decor(t), screen: screen, unlocked: unlocked) == nil)
            }

            // 两两相交面积为 0
            for i in frames.indices {
                for j in frames.indices where j > i {
                    let a = frames[i].1, b = frames[j].1
                    let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                    let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                    #expect(w <= 0 || h <= 0, "\(frames[i].0) 与 \(frames[j].0) 重叠 \(w)×\(h)")
                }
            }

            // 外框内的点恰好落在所归的取物区内，外框外的点不属于任何区
            let p = Point(x: f.minX + u * f.width, y: f.minY + v * f.height)
            let hit = ToolboxLayout.zone(at: p, screen: screen, unlocked: unlocked)
            if f.contains(p) {
                if let hit, let zf = frames.first(where: { $0.0 == hit })?.1 {
                    #expect(zf.contains(p), "点 \(p) 归入 \(hit)，但不在该区矩形内")
                } else {
                    Issue.record("外框内的点 \(p) 没有归入已显示的取物区：\(String(describing: hit))")
                }
            } else {
                #expect(hit == nil, "外框外的点 \(p) 被归入 \(String(describing: hit))")
            }

            // 新解锁的 Decor_Slot 不打乱已有取物区的相对顺序（Requirement 2.2）
            for t in DecorType.allCases where !unlocked.contains(t) {
                let grown = ToolboxLayout.zones(unlocked: unlocked.union([t]))
                #expect(isSubsequence(zones, of: grown), "解锁 \(t) 后 \(zones) 不是 \(grown) 的子序列")
            }
        }
    }

    /// 空集时与 v1 完全相同：外框 72pt 宽，Plank 区为左半、Ladder 区为右半（Requirement 2.8）。
    @Test func emptyUnlockedMatchesV1() {
        let screen = ScreenInfo(
            frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
            visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))
        let f = ToolboxLayout.frame(screen: screen, unlocked: [])
        #expect(f == Rect(minX: 1440 - 8 - 72, minY: 825 - SpriteMetrics.toolbox.height,
                          width: 72, height: SpriteMetrics.toolbox.height))
        #expect(ToolboxLayout.zoneFrame(.plank, screen: screen).maxX == f.midX)
        #expect(ToolboxLayout.zoneFrame(.ladder, screen: screen).minX == f.midX)
        // 两区之间边上的点归右侧区
        #expect(ToolboxLayout.zone(at: Point(x: f.midX, y: f.midY), screen: screen) == .ladder)
    }

    /// 解锁全部 Decor 后外框向左扩展到 4 区，右边缘不动，边上的点归右侧区。
    @Test func allUnlockedExtendsLeft() {
        let screen = ScreenInfo(
            frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
            visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))
        let all = Set(DecorType.allCases)
        let f = ToolboxLayout.frame(screen: screen, unlocked: all)
        #expect(f.width == 4 * ToolboxLayout.zoneWidth)
        #expect(f.maxX == ToolboxLayout.frame(screen: screen).maxX)
        let lamp = ToolboxLayout.zoneFrame(.decor(.lamp), screen: screen, unlocked: all)
        #expect(lamp?.maxX == f.maxX)
        if let lamp {
            #expect(ToolboxLayout.zone(at: Point(x: lamp.minX, y: lamp.midY), screen: screen, unlocked: all)
                == .decor(.lamp))
        }
    }
}
