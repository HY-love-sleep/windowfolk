import Testing
@testable import WindowfolkCore

struct DecorUnitTests {
    @Test func decorTypeOrderIsChairThenLamp() {
        #expect(DecorType.allCases == [.chair, .lamp])
        #expect(DecorType.chair < DecorType.lamp)
        #expect([DecorType.lamp, .chair].sorted() == [.chair, .lamp])
    }

    @Test func unlockReturnsTrueOnlyWhenNewAndNeverShrinks() {
        var s = DecorStore()
        let first = s.unlock(.chair)
        let again = s.unlock(.chair)
        let lamp = s.unlock(.lamp)
        #expect(first && !again && lamp)
        #expect(s.unlocked == [.chair, .lamp])
    }

    @Test func makeDecorCreatesFreshDraggedAndRespectsMax() throws {
        var s = DecorStore()
        let off = Point(x: 3, y: 4)
        let a0 = s.makeDecor(.chair, grabOffset: off, max: 2)
        let a = try #require(a0)
        let b0 = s.makeDecor(.lamp, grabOffset: off, max: 2)
        let b = try #require(b0)
        #expect(a < b)
        #expect(s.decors[a]?.placement == .dragged(grabOffset: off, fresh: true))
        #expect(s.decors[a]?.type == .chair)
        // count 含拖动中的 Decor；满额返回 nil 且数量不变
        #expect(s.count == 2)
        let full = s.makeDecor(.chair, grabOffset: off, max: 2)
        #expect(full == nil)
        #expect(s.count == 2)
        #expect(s.sortedIDs == [a, b])
    }

    @Test func markPlacedAssignsIncreasingSeq() throws {
        var s = DecorStore()
        let a0 = s.makeDecor(.chair, grabOffset: Point(x: 0, y: 0), max: 20)
        let a = try #require(a0)
        let b0 = s.makeDecor(.chair, grabOffset: Point(x: 0, y: 0), max: 20)
        let b = try #require(b0)
        s.markPlaced(b)
        s.markPlaced(a)
        let sa = try #require(s.decors[a]?.placedSeq)
        let sb = try #require(s.decors[b]?.placedSeq)
        #expect(sb > 0 && sa > sb)
        s.markPlaced(b)
        #expect(s.decors[b]!.placedSeq > sa)
        s.markPlaced(DecorID(999))  // 不存在：无变化
        #expect(s.count == 2)
    }

    @Test func removedDecorFreesCapacityWithoutReusingID() throws {
        var s = DecorStore()
        let a0 = s.makeDecor(.lamp, grabOffset: Point(x: 0, y: 0), max: 1)
        let a = try #require(a0)
        s.decors[a] = nil
        let b0 = s.makeDecor(.lamp, grabOffset: Point(x: 0, y: 0), max: 1)
        let b = try #require(b0)
        #expect(b != a)
    }
}
