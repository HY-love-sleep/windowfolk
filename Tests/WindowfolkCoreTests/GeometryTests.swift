import Testing
@testable import WindowfolkCore

struct GeometryTests {
    @Test func rectDerivedEdges() {
        let r = Rect(minX: 10, minY: 20, width: 100, height: 50)
        #expect(r.maxX == 110)
        #expect(r.maxY == 70)
        #expect(r.center == Point(x: 60, y: 45))
    }

    @Test func groundYIsVisibleFrameBottom() {
        let s = ScreenInfo(
            frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
            visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800))
        #expect(s.groundY == 825)
    }

    @Test func subtractNoCuts() {
        #expect(IntervalMath.subtract(Interval(lo: 0, hi: 10), []) == [Interval(lo: 0, hi: 10)])
    }

    @Test func subtractMiddleCut() {
        let r = IntervalMath.subtract(Interval(lo: 0, hi: 10), [Interval(lo: 3, hi: 5)])
        #expect(r == [Interval(lo: 0, hi: 3), Interval(lo: 5, hi: 10)])
    }

    @Test func subtractOverlappingUnsortedCuts() {
        let r = IntervalMath.subtract(
            Interval(lo: 0, hi: 100),
            [Interval(lo: 60, hi: 80), Interval(lo: 10, hi: 30), Interval(lo: 20, hi: 40), Interval(lo: -5, hi: 2)])
        #expect(r == [Interval(lo: 2, hi: 10), Interval(lo: 40, hi: 60), Interval(lo: 80, hi: 100)])
    }

    @Test func subtractFullCoverYieldsEmpty() {
        #expect(IntervalMath.subtract(Interval(lo: 0, hi: 10), [Interval(lo: -1, hi: 11)]).isEmpty)
        #expect(IntervalMath.subtract(Interval(lo: 0, hi: 10), [Interval(lo: 0, hi: 5), Interval(lo: 5, hi: 10)]).isEmpty)
    }

    @Test func subtractDropsZeroLengthPieces() {
        // 切口恰好贴着端点，不产生 0 长度片段
        let r = IntervalMath.subtract(Interval(lo: 0, hi: 10), [Interval(lo: 0, hi: 0), Interval(lo: 10, hi: 12)])
        #expect(r == [Interval(lo: 0, hi: 10)])
        #expect(IntervalMath.subtract(Interval(lo: 5, hi: 5), []).isEmpty)
    }

    @Test func tunableDefaults() {
        let t = Tunables()
        #expect(t.minWindowSize == 120)
        #expect(t.carrySpeedRatio > 0 && t.carrySpeedRatio <= 0.8)
        #expect((2 * 3000 / t.fallGravity).squareRoot() <= 2)
    }
}
