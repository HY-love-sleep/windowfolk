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
    /// v2 LLM 设置（Requirement 11）：`settings.json` 与钥匙串中的 API Key。
    private var settingsModel: LLMSettingsModel?
    private var settingsWindow: SettingsWindowController?
    /// 日记批次调度（Requirement 13）。强引用：GameLoop 和 Diary_Window 都不持有它的所有权。
    private var diaryCoordinator: DiaryCoordinator?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 在启动完成前设置，避免 Dock 图标闪一下。
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenu()
        createOverlay()
        startGameLoop()
    }

    /// 组装 v2 的 LLM 设置、Settings_Window、日记与小心思（Requirement 11.2、13.12）。
    /// 数据目录为 `~/Library/Application Support/Windowfolk/`（`settings.json`、`diary.jsonl` 都在这里）；
    /// 无法确定目录时不提供设置和日记，世界照常运行。返回交给 GameLoop 的小心思协调器。
    private func makeLLMComponents(eventLog: EventLogWriter?) -> ThoughtCoordinator? {
        guard let appSupport = FileEventSink.defaultDirectory() else { return nil }
        let settingsStore = FileLLMSettingsStore(directory: appSupport)
        let secrets = KeychainSecretStore()
        let model = LLMSettingsModel(store: settingsStore, secrets: secrets)
        let client = URLSessionLLMClient()
        settingsModel = model
        let settingsWindow = SettingsWindowController(model: model)
        self.settingsWindow = settingsWindow
        statusMenu?.onShowSettings = { [weak settingsWindow] in
            settingsWindow?.show()
        }

        if let diary = DiaryCoordinator.makeDefault(eventLog: eventLog, settings: settingsStore,
                                                   secrets: secrets, client: client) {
            diaryCoordinator = diary
            statusMenu?.onShowDiary = { [weak diary] in
                diary?.showWindow()
            }
            // 启动补写早于今天、缺日记的日期（Requirement 13.3）。不阻塞启动。
            Task { await diary.startup() }
        }
        return ThoughtCoordinator(client: client, settings: model)
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
        let eventLog = EventLogWriter.makeDefault()
        let thoughts = makeLLMComponents(eventLog: eventLog)
        let loop = GameLoop(engine: engine, source: source, renderer: renderer,
                            screen: screen, pointerSource: panel.skView, hitTestTimer: hitTest,
                            eventLog: eventLog, saveController: saves,
                            thoughtCoordinator: thoughts, diaryCoordinator: diaryCoordinator)

        statusMenu?.onToggleSurfaces = { [weak loop] _ in
            loop?.enqueue(.toggleSurfaces)
        }
        // 调试子菜单（Requirement 26.1、v2 Requirement 17.1）：按顺序为「让都都去找嘟嘟」「给都都一个花盆」「快进」
        // 「重置世界」（v1「重新开始剧情」更名）「触发心愿 ▸」「昼夜 ▸」「解锁全部物件」。
        statusMenu?.addDebugItem("让都都去找嘟嘟") { [weak loop] in
            loop?.enqueue(.debugSeek)
        }
        statusMenu?.addDebugItem("给都都一个花盆") { [weak loop] in
            loop?.enqueue(.debugGiveFlower)
        }
        statusMenu?.addDebugItem("快进") { [weak loop] in
            loop?.enqueue(.fastForward)
        }
        statusMenu?.addDebugItem("重置世界") { [weak loop] in
            loop?.enqueue(.resetWorld)
        }
        statusMenu?.addWishTriggerMenu(nextFlowerGiver: { [weak loop] in
            loop?.nextFlowerGiver ?? .a
        }, trigger: { [weak loop] type, resident in
            loop?.enqueue(.triggerWish(type, resident))
        })
        // 启动为「自动」，与 WorldState.dayNightOverride 的初值一致（v2 Requirement 17.4）。
        statusMenu?.addDayNightMenu { [weak loop] value in
            loop?.enqueue(.setDayNight(value))
        }
        statusMenu?.addDebugItem("解锁全部物件") { [weak loop] in
            loop?.enqueue(.unlockAllDecor)
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
    /// 同时写入尚未保存的 LLM 设置（v2 Requirement 11.4）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        settingsModel?.flush()
        gameLoop?.saveForTermination()
        return .terminateNow
    }

    /// 兜底：没有经过 applicationShouldTerminate 的退出路径也保存一次（已保存过则跳过）。
    func applicationWillTerminate(_ notification: Notification) {
        settingsModel?.flush()
        gameLoop?.saveForTermination()
    }
}
