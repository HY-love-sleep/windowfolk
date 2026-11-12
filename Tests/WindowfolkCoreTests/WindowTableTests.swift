import Testing
@testable import WindowfolkCore

// WindowTable 与 FakeWindowSource 的单元测试（任务 2.6）。
// Requirements: 2.8, 5.1, 5.2, 5.8, 27.4

private func wtWindow(_ id: WindowID, x: Double = 0, y: Double = 100, w: Double = 300, h: Double = 200,
                      owner: String = "App") -> WindowSnapshot {
    WindowSnapshot(id: id, ownerName: owner, ownerPID: 100 + Int32(id),
                   frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: 0)
}

/// 用初始窗口构造假源和已同步一次的窗口表。
private func wtSetup(_ snaps: [WindowSnapshot]) -> (FakeWindowSource, WindowTable) {
    var src = FakeWindowSource()
    for s in snaps { src.add(s) }
    var table = WindowTable()
    table.apply(src.poll())
    return (src, table)
}

private func wtEligible(_ r: WindowPollResult) -> [WindowSnapshot] {
    guard case let .success(eligible, _) = r else { return [] }
    return eligible
}

private func wtExisting(_ r: WindowPollResult) -> Set<WindowID> {
    guard case let .success(_, existing) = r else { return [] }
    return existing
}

@Suite("WindowTable")
struct WindowTableTests {
    @Test("首次轮询：全部窗口报告为新出现且可见")
    func firstPollAppears() {
        var src = FakeWindowSource()
        src.add(wtWindow(2))
        src.add(wtWindow(1))
        var table = WindowTable()
        let changes = table.apply(src.poll())
        #expect(changes.appeared == [1, 2])
        #expect(changes.closed.isEmpty && changes.hidden.isEmpty)
        #expect(table.visibleSnapshots.map(\.id) == [2, 1])
    }

    @Test("最小化或切到其他桌面空间：判为隐藏，保留最后可见快照")
    func hideKeepsLastSnapshot() {
        var (src, table) = wtSetup([wtWindow(1, x: 10), wtWindow(2, x: 500)])
        let before = table.records[1]!.snapshot
        src.hide(1)
        let changes = table.apply(src.poll())
        #expect(changes.hidden == [1])
        #expect(changes.closed.isEmpty)
        #expect(table.isHidden(1))
        #expect(table.visibleSnapshot(1) == nil)
        #expect(table.records[1]?.snapshot == before)

        // 隐藏期间再次轮询不重复报告
        let again = table.apply(src.poll())
        #expect(again.isEmpty)
    }

    @Test("隐藏后重新显示：报告 shown，位置变化时同时报告 geometryChanged")
    func showAfterHide() {
        var (src, table) = wtSetup([wtWindow(1, x: 10)])
        src.hide(1)
        table.apply(src.poll())
        src.show(1)
        let c1 = table.apply(src.poll())
        #expect(c1.shown == [1])
        #expect(c1.geometryChanged.isEmpty)
        #expect(table.visibleSnapshot(1) != nil)

        src.hide(1)
        table.apply(src.poll())
        src.move(1, to: Point(x: 80, y: 40))
        src.show(1)
        let c2 = table.apply(src.poll())
        #expect(c2.shown == [1])
        #expect(c2.geometryChanged == [1])
        #expect(table.visibleSnapshot(1)?.frame.minX == 80)
    }

    @Test("ID 消失：判为关闭，删除记录并附带最后可见快照")
    func closeReportsLastSnapshot() {
        var (src, table) = wtSetup([wtWindow(1, x: 10), wtWindow(2, x: 500)])
        src.move(1, to: Point(x: 30, y: 60))
        table.apply(src.poll())
        let last = table.records[1]!.snapshot
        src.close(1)
        let changes = table.apply(src.poll())
        #expect(changes.closed == [last])
        #expect(changes.closed.first?.frame.minX == 30)
        #expect(table.records[1] == nil)
        #expect(table.records[2] != nil)
    }

    @Test("隐藏后关闭：附带的是隐藏前最后一次可见的快照")
    func hiddenThenClosed() {
        var (src, table) = wtSetup([wtWindow(1, x: 10, y: 100)])
        src.hide(1)
        table.apply(src.poll())
        // 隐藏期间窗口被移动（看不见），表中仍保留隐藏前的快照
        src.move(1, to: Point(x: 900, y: 700))
        table.apply(src.poll())
        src.close(1)
        let changes = table.apply(src.poll())
        #expect(changes.closed.count == 1)
        #expect(changes.closed.first?.frame.minX == 10)
        #expect(changes.closed.first?.frame.minY == 100)
        #expect(changes.hidden.isEmpty)
        #expect(table.records.isEmpty)
    }

    @Test("轮询失败：不改动记录，不判任何窗口关闭；下一次成功轮询照常处理")
    func failedPollChangesNothing() {
        var (src, table) = wtSetup([wtWindow(1), wtWindow(2, x: 500)])
        let before = table
        src.close(1)
        src.failNextPoll = true
        let changes = table.apply(src.poll())
        #expect(changes.isEmpty)
        #expect(table == before)

        let next = table.apply(src.poll())
        #expect(next.closed.map(\.id) == [1])
    }

    @Test("层级变化报告为 geometryChanged")
    func zOrderChange() {
        var (src, table) = wtSetup([wtWindow(1), wtWindow(2, x: 500)])
        src.bringToFront(2)
        let changes = table.apply(src.poll())
        #expect(changes.geometryChanged == [1, 2])
        #expect(table.visibleSnapshots.map(\.id) == [2, 1])
    }
}

@Suite("FakeWindowSource")
struct FakeWindowSourceTests {
    @Test("空源输出空列表")
    func empty() {
        var src = FakeWindowSource()
        let r = src.poll()
        #expect(r == .success(eligible: [], existingIDs: []))
    }

    @Test("poll 按从前到后输出并从 0 连续编号 zIndex")
    func orderAndZIndex() {
        var src = FakeWindowSource()
        src.add(wtWindow(1))
        src.add(wtWindow(2))
        src.addInFront(wtWindow(3))
        let e = wtEligible(src.poll())
        #expect(e.map(\.id) == [3, 1, 2])
        #expect(e.map(\.zIndex) == [0, 1, 2])
    }

    @Test("move 与 resize 在下一次 poll 中体现")
    func moveAndResize() {
        var src = FakeWindowSource()
        src.add(wtWindow(1, x: 0, y: 100, w: 300, h: 200))
        src.move(1, to: Point(x: 50, y: 70))
        src.resize(1, to: (400, 250))
        let f = wtEligible(src.poll()).first!.frame
        #expect(f == Rect(minX: 50, minY: 70, width: 400, height: 250))
    }

    @Test("bringToFront 与 sendBehind 改变层级")
    func reorder() {
        var src = FakeWindowSource()
        for id: WindowID in [1, 2, 3] { src.add(wtWindow(id)) }
        src.bringToFront(3)
        #expect(wtEligible(src.poll()).map(\.id) == [3, 1, 2])
        src.sendBehind(3, 2)
        #expect(wtEligible(src.poll()).map(\.id) == [1, 2, 3])
        src.sendBehind(1, 2)
        #expect(wtEligible(src.poll()).map(\.id) == [2, 1, 3])
    }

    @Test("hide 从可见列表移除但保留在 existingIDs；show 回到原层级")
    func hideShow() {
        var src = FakeWindowSource()
        for id: WindowID in [1, 2, 3] { src.add(wtWindow(id)) }
        src.hide(2)
        let r = src.poll()
        #expect(wtEligible(r).map(\.id) == [1, 3])
        #expect(wtEligible(r).map(\.zIndex) == [0, 1])
        #expect(wtExisting(r) == [1, 2, 3])
        src.show(2)
        #expect(wtEligible(src.poll()).map(\.id) == [1, 2, 3])
    }

    @Test("close 从可见列表和 existingIDs 中都移除")
    func close() {
        var src = FakeWindowSource()
        for id: WindowID in [1, 2] { src.add(wtWindow(id)) }
        src.close(1)
        let r = src.poll()
        #expect(wtEligible(r).map(\.id) == [2])
        #expect(wtExisting(r) == [2])
    }

    @Test("failNextPoll 只让下一次 poll 失败")
    func failOnce() {
        var src = FakeWindowSource()
        src.add(wtWindow(1))
        src.failNextPoll = true
        #expect(src.poll() == .failure)
        #expect(wtEligible(src.poll()).map(\.id) == [1])
    }

    @Test("支持 50 个窗口")
    func fiftyWindows() {
        var src = FakeWindowSource()
        for i in 1...50 { src.add(wtWindow(WindowID(i), x: Double(i) * 10)) }
        let r = src.poll()
        #expect(wtEligible(r).count == 50)
        #expect(wtExisting(r).count == 50)
    }
}
