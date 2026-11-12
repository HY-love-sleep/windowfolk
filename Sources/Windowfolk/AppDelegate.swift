import AppKit
import SpriteKit
import WindowfolkCore

/// 应用外壳（Requirement 1.1）：以 `.accessory` 激活策略运行，
/// 只在菜单栏显示图标，不出现在 Dock 和 Command-Tab 中。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?
    /// 整个应用只有这一个 Overlay（Requirement 1.2）。
    private var overlay: OverlayPanel?
    private var geometry: ScreenGeometry?
    private var gameLoop: GameLoop?
    private var hitTestTimer: HitTestTimer?
    private var screenObserver: ScreenObserver?
    private var fullscreenMonitor: FullscreenMonitor?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 在启动完成前设置，避免 Dock 图标闪一下。
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenu()
        createOverlay()
        startGameLoop()
    }

    private func createOverlay() {
        guard overlay == nil,
              let frame = OverlayPanel.mainDisplayFrame(),
              let geometry = ScreenGeometry.current() else { return }
        self.geometry = geometry

        let panel = OverlayPanel(frame: frame)
        // orderFrontRegardless：不激活本应用，前台应用保持不变（Requirement 1.5）。
        panel.orderFrontRegardless()
        overlay = panel
    }

    /// 组装 WorldEngine、CGWindowSource、SceneRenderer 和 GameLoop，并接上「显示路面」开关。
    private func startGameLoop() {
        guard gameLoop == nil,
              let panel = overlay,
              let geometry,
              let main = NSScreen.screens.first else { return }

        let screen = geometry.screenInfo(frame: main.frame, visibleFrame: main.visibleFrame)
        let constants = Tunables()
        // 启动时读取存档：不存在则首次开局，损坏或版本不符则备份后首次开局（Requirement 22.11、22.12）。
        let saves = SaveController.makeDefault(interval: constants.autosaveInterval)
        let restored = saves?.loadAtLaunch()
        let engine = WorldEngine(constants: constants, clockStart: Date(), screen: screen, restored: restored)
        let source = CGWindowSource(screen: screen, minSize: constants.minWindowSize)
        let renderer = SceneRenderer(scene: panel.scene, geometry: geometry, overlayFrame: panel.frame,
                                     constants: constants)
        panel.skView.geometry = geometry
        let hitTest = HitTestTimer(panel: panel, bridge: panel.skView, geometry: geometry)
        let loop = GameLoop(engine: engine, source: source, renderer: renderer,
                            screen: screen, pointerSource: panel.skView, hitTestTimer: hitTest,
                            eventLog: EventLogWriter.makeDefault(), saveController: saves)

        statusMenu?.onToggleSurfaces = { [weak loop] _ in
            loop?.enqueue(.toggleSurfaces)
        }
        // 调试子菜单（Requirement 26.1）：按顺序为「让都都去找嘟嘟」「给都都一个花盆」「快进」「重新开始剧情」。
        statusMenu?.addDebugItem("让都都去找嘟嘟") { [weak loop] in
            loop?.enqueue(.debugSeek)
        }
        statusMenu?.addDebugItem("给都都一个花盆") { [weak loop] in
            loop?.enqueue(.debugGiveFlower)
        }
        statusMenu?.addDebugItem("快进") { [weak loop] in
            loop?.enqueue(.fastForward)
        }
        statusMenu?.addDebugItem("重新开始剧情") { [weak loop] in
            loop?.enqueue(.restartStory)
        }
        // 「退出」走 NSApp.terminate，由 applicationShouldTerminate 同步保存后结束进程（Requirement 1.9）。
        statusMenu?.onQuit = {
            NSApp.terminate(nil)
        }
        // 全屏检测（任务 17.6）：前台应用或桌面空间变化时立即重新判定；首帧起每次轮询后也判定。
        let fullscreen = FullscreenMonitor { [weak loop] in
            loop?.refreshNow()
        }
        loop.fullscreenMonitor = fullscreen
        loop.start()
        hitTest.start()
        gameLoop = loop
        hitTestTimer = hitTest
        fullscreen.start()
        fullscreenMonitor = fullscreen

        let observer = ScreenObserver { [weak self] in
            self?.displayDidChange()
        }
        observer.start()
        screenObserver = observer
    }

    /// 唤醒或屏幕参数变化后重建 Overlay 和屏幕信息（Requirement 23.5、23.6）。幂等：
    /// 主显示器 frame 和 `visibleFrame` 都没变时只让下一帧重新渲染。没有屏幕时暂停循环（design.md「Error Handling」）。
    private func displayDidChange() {
        guard let loop = gameLoop, let panel = overlay else { return }
        guard let main = NSScreen.screens.first else {
            loop.suspend()
            hitTestTimer?.stop()
            panel.ignoresMouseEvents = true
            return
        }
        let geometry = ScreenGeometry(mainScreenHeight: Double(main.frame.height))
        let screen = geometry.screenInfo(frame: main.frame, visibleFrame: main.visibleFrame)
        if panel.frame != main.frame {
            panel.resize(to: main.frame)
        }
        // 唤醒后 Overlay 可能被系统移出前台层级，重新放到最前（不激活本应用，Requirement 1.5）。
        panel.orderFrontRegardless()
        self.geometry = geometry
        loop.displayDidChange(screen: screen, geometry: geometry, overlayFrame: panel.frame)
        if loop.isSuspended {
            loop.resume()
            hitTestTimer?.start()
        }
    }

    /// 同步保存后立即退出（Requirement 1.9、1.10、22.1）。保存失败时原文件不变，照常退出。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        gameLoop?.saveForTermination()
        return .terminateNow
    }

    /// 兜底：没有经过 applicationShouldTerminate 的退出路径也保存一次（已保存过则跳过）。
    func applicationWillTerminate(_ notification: Notification) {
        gameLoop?.saveForTermination()
    }
}
