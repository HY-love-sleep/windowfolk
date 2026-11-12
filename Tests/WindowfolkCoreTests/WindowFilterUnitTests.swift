import Testing
@testable import WindowfolkCore

struct WindowFilterUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )
    let ownPID: Int32 = 999

    func raw(_ id: WindowID, pid: Int32 = 1, x: Double = 100, y: Double = 100,
             w: Double = 400, h: Double = 300, layer: Int = 0, alpha: Double = 1) -> RawWindowInfo {
        RawWindowInfo(id: id, ownerName: "App\(id)", ownerPID: pid,
                      bounds: Rect(minX: x, minY: y, width: w, height: h),
                      layer: layer, alpha: alpha, isOnScreen: true)
    }

    func eligible(_ r: WindowPollResult) -> [WindowSnapshot] {
        if case let .success(e, _) = r { return e }
        Issue.record("expected success")
        return []
    }

    @Test func emptyInputGivesEmptyResult() {
        let r = WindowFilter.makeResult(onScreen: [], all: [], ownPID: ownPID, screen: screen, minSize: 120)
        #expect(r == .success(eligible: [], existingIDs: []))
    }

    @Test func filtersIneligibleAndRenumbersZIndex() {
        let onScreen = [
            raw(1),
            raw(2, layer: 25),                 // 非普通层级
            raw(3, alpha: 0),                  // 透明
            raw(4, w: 119),                    // 过窄
            raw(5, pid: ownPID),               // 本进程（Overlay）
            raw(6, x: 1400, y: 100, w: 400),   // 中心 x = 1600，屏外
            raw(7, w: .nan),                   // 非法尺寸
            raw(8, h: -300),                   // 负尺寸
            raw(9, w: 120, h: 120),            // 恰好 Min_Window_Size
        ]
        let all = onScreen + [raw(10)]          // 10：最小化窗口
        let r = WindowFilter.makeResult(onScreen: onScreen, all: all, ownPID: ownPID, screen: screen, minSize: 120)
        let e = eligible(r)
        #expect(e.map(\.id) == [1, 9])
        #expect(e.map(\.zIndex) == [0, 1])
        #expect(e[0].frame == onScreen[0].bounds)
        #expect(e[0].ownerName == "App1")
        guard case let .success(_, ids) = r else { return }
        #expect(ids == Set(1...10))
    }

    @Test func centerOnScreenEdgeIsKept() {
        // 中心点恰好在屏幕右边缘
        let r = WindowFilter.makeResult(onScreen: [raw(1, x: 1240, w: 400)], all: [],
                                        ownPID: ownPID, screen: screen, minSize: 120)
        #expect(eligible(r).map(\.id) == [1])
    }
}
