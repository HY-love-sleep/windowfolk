import Testing
@testable import WindowfolkCore

struct AttachmentUnitTests {
    let screen = ScreenInfo(
        frame: Rect(minX: 0, minY: 0, width: 1440, height: 900),
        visibleFrame: Rect(minX: 0, minY: 25, width: 1440, height: 800)
    )

    func win(_ id: WindowID, z: Int, x: Double, y: Double, w: Double, h: Double) -> WindowSnapshot {
        WindowSnapshot(id: id, ownerName: "App\(id)", ownerPID: 1,
                       frame: Rect(minX: x, minY: y, width: w, height: h), zIndex: z)
    }

    func table(_ snaps: [WindowSnapshot], existing extra: Set<WindowID> = []) -> WindowTable {
        var t = WindowTable()
        t.apply(.success(eligible: snaps, existingIDs: Set(snaps.map(\.id)).union(extra)))
        return t
    }

    @Test func windowAttachmentFollowsTranslation() {
        let w = win(1, z: 0, x: 100, y: 200, w: 400, h: 300)
        var t = table([w])
        let a = Attachment.window(1, offset: 50)
        #expect(AttachmentResolver.screenPosition(a, windows: t, screen: screen) == Point(x: 150, y: 200))

        var moved = w
        moved.frame.minX = 300
        moved.frame.minY = 120
        t.apply(.success(eligible: [moved], existingIDs: [1]))
        #expect(AttachmentResolver.screenPosition(a, windows: t, screen: screen) == Point(x: 350, y: 120))
    }

    @Test func hiddenOrUnknownWindowHasNoPosition() {
        var t = table([win(1, z: 0, x: 100, y: 200, w: 400, h: 300)])
        t.apply(.success(eligible: [], existingIDs: [1]))   // 隐藏
        #expect(AttachmentResolver.screenPosition(.window(1, offset: 10), windows: t, screen: screen) == nil)
        #expect(AttachmentResolver.screenPosition(.window(9, offset: 10), windows: t, screen: screen) == nil)
    }

    @Test func groundAndFreePositions() {
        let t = WindowTable()
        #expect(AttachmentResolver.screenPosition(.ground(x: 42), windows: t, screen: screen) == Point(x: 42, y: 825))
        #expect(AttachmentResolver.screenPosition(.free(Point(x: 1, y: 2)), windows: t, screen: screen) == Point(x: 1, y: 2))
        #expect(AttachmentResolver.screenPosition(.plank(PlankID(1), t: 0.5), windows: t, screen: screen) == nil)
    }

    @Test func clampKeepsOffsetInsideLedge() {
        let w = win(1, z: 0, x: 100, y: 200, w: 400, h: 300)
        let ledges = SurfaceBuilder.build(windows: [w], screen: screen)
        #expect(AttachmentResolver.clamp(offset: 0, window: w, ledges: ledges) == 0)
        #expect(AttachmentResolver.clamp(offset: 250, window: w, ledges: ledges) == 250)
        #expect(AttachmentResolver.clamp(offset: 400, window: w, ledges: ledges) == 400)
    }

    @Test func clampMovesToNearestRemainingLedge() {
        // 后方窗口 1：上沿 [100, 700]；前方窗口 2 遮住 [300, 500] → 剩 [100,300] 和 [500,700]
        let back = win(1, z: 1, x: 100, y: 200, w: 600, h: 300)
        let front = win(2, z: 0, x: 300, y: 150, w: 200, h: 200)
        let ledges = SurfaceBuilder.build(windows: [back, front], screen: screen)
        #expect(AttachmentResolver.clamp(offset: 250, window: back, ledges: ledges) == 200)   // x=350 → 300
        #expect(AttachmentResolver.clamp(offset: 350, window: back, ledges: ledges) == 400)   // x=450 → 500
        #expect(AttachmentResolver.clamp(offset: 300, window: back, ledges: ledges) == 200)   // 等距取 index 0
        // 窗口变窄：offset 超出右边缘
        var narrow = win(3, z: 0, x: 100, y: 600, w: 200, h: 200)
        narrow.frame.width = 150
        let l2 = SurfaceBuilder.build(windows: [narrow], screen: screen)
        #expect(AttachmentResolver.clamp(offset: 190, window: narrow, ledges: l2) == 150)
    }

    @Test func clampReturnsNilWhenFullyCovered() {
        let back = win(1, z: 1, x: 100, y: 200, w: 400, h: 300)
        let front = win(2, z: 0, x: 50, y: 100, w: 600, h: 300)
        let ledges = SurfaceBuilder.build(windows: [back, front], screen: screen)
        #expect(AttachmentResolver.clamp(offset: 100, window: back, ledges: ledges) == nil)
    }

    @Test func landingAttachment() {
        let w = win(1, z: 0, x: 100, y: 200, w: 400, h: 300)
        let t = table([w])
        let ledges = SurfaceBuilder.build(windows: [w], screen: screen)
        let ledge = ledges.first { $0.id == .ledge(1, index: 0) }!
        let ground = ledges.first { $0.id == .ground }!
        #expect(AttachmentResolver.attachment(landingOn: ledge, atX: 180, windows: t) == .window(1, offset: 80))
        #expect(AttachmentResolver.attachment(landingOn: ground, atX: 700, windows: t) == .ground(x: 700))
    }
}
