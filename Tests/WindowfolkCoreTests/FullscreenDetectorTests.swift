import Testing
@testable import WindowfolkCore

/// 全屏判定（任务 17.6，Requirement 23.1、23.4）。
struct FullscreenDetectorTests {
    let screen = ScreenInfo(frame: Rect(minX: 0, minY: 0, width: 1512, height: 982),
                            visibleFrame: Rect(minX: 0, minY: 33, width: 1512, height: 880))
    let own: Int32 = 1

    func window(_ pid: Int32, _ bounds: Rect, layer: Int = 0, alpha: Double = 1) -> RawWindowInfo {
        RawWindowInfo(id: UInt32(pid) * 10, ownerName: "App\(pid)", ownerPID: pid, bounds: bounds,
                      layer: layer, alpha: alpha, isOnScreen: true)
    }

    @Test func frontWindowCoveringFullFrameIsFullscreen() {
        let list = [window(42, screen.frame), window(7, Rect(minX: 100, minY: 100, width: 400, height: 300))]
        #expect(FullscreenDetector.isFullscreen(frontPID: 42, onScreen: list, screen: screen, ownPID: own))
    }

    @Test func subPointRoundingIsTolerated() {
        let r = Rect(minX: -0.5, minY: 0.4, width: 1512.5, height: 981.8)
        #expect(FullscreenDetector.isFullscreen(frontPID: 42, onScreen: [window(42, r)], screen: screen, ownPID: own))
    }

    @Test func zoomedWindowBelowMenuBarIsNotFullscreen() {
        // 「缩放」到 visibleFrame 的普通窗口不是全屏。
        let r = Rect(minX: 0, minY: 33, width: 1512, height: 880)
        #expect(!FullscreenDetector.isFullscreen(frontPID: 42, onScreen: [window(42, r)], screen: screen, ownPID: own))
    }

    @Test func fullFrameWindowOfOtherAppDoesNotCount() {
        let list = [window(7, screen.frame), window(42, Rect(minX: 0, minY: 40, width: 500, height: 500))]
        #expect(!FullscreenDetector.isFullscreen(frontPID: 42, onScreen: list, screen: screen, ownPID: own))
    }

    @Test func nonNormalLayerTransparentOwnOrUnknownFrontAreIgnored() {
        #expect(!FullscreenDetector.isFullscreen(frontPID: 42, onScreen: [window(42, screen.frame, layer: 25)],
                                                 screen: screen, ownPID: own))
        #expect(!FullscreenDetector.isFullscreen(frontPID: 42, onScreen: [window(42, screen.frame, alpha: 0)],
                                                 screen: screen, ownPID: own))
        #expect(!FullscreenDetector.isFullscreen(frontPID: own, onScreen: [window(own, screen.frame)],
                                                 screen: screen, ownPID: own))
        #expect(!FullscreenDetector.isFullscreen(frontPID: nil, onScreen: [window(42, screen.frame)],
                                                 screen: screen, ownPID: own))
        #expect(!FullscreenDetector.isFullscreen(frontPID: 42, onScreen: [], screen: screen, ownPID: own))
    }
}
