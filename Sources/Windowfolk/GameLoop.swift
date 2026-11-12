import AppKit
import WindowfolkCore

/// 驱动「轮询窗口 → WorldEngine.step → 渲染」的主线程循环（design.md「每帧更新顺序」）。
///
/// - 使用加入 `.common` run loop 模式的 `Timer`，菜单打开或拖动窗口时也继续运行。
/// - 启动时以 Active_Poll_Rate 运行（Requirement 24.1）；每帧按 `StepOutput.nextRate`
///   （由 Core 的 `PollRatePolicy` 给出）调整定时器间隔，SKView 的渲染频率随之调整；
///   画面不变时 `RenderGate` 跳过渲染（任务 17.2，Requirement 29.1）。
/// - `WorldEngine` 只在这里、只在主线程上调用（design.md「线程模型」）。
@MainActor
final class GameLoop {
    private let engine: WorldEngine
    private var source: CGWindowSource
    private let renderer: SceneRenderer
    private var screen: ScreenInfo

    private var timer: Timer?
    private var currentRate: PollRate = .active
    /// 菜单命令先排队，下一帧随 FrameInput 一起交给 `step`。
    private var pendingCommands: [Command] = []
    /// 鼠标事件来源（Overlay 的内容视图），每帧取出排队的事件。
    private weak var pointerSource: PointerBridge?
    /// 鼠标穿透计时器，每帧拿到最新的命中区域。
    private weak var hitTestTimer: HitTestTimer?
    /// 事件记录写入器；每帧把 `StepOutput.events` 交给它在后台追加（Requirement 21.2）。
    private let eventLog: EventLogWriter?
    /// 存档控制；每帧检查是否满 Autosave_Interval（Requirement 22.2）。
    private let saveController: SaveController?
    /// 全屏检测（任务 17.6）；每次轮询后判定一次。
    var fullscreenMonitor: FullscreenMonitor?
    /// 当前是否因前台应用全屏而隐藏世界（Requirement 23.1、23.2）。
    private(set) var isWorldHidden = false

    init(engine: WorldEngine, source: CGWindowSource, renderer: SceneRenderer,
         screen: ScreenInfo, pointerSource: PointerBridge? = nil, hitTestTimer: HitTestTimer? = nil,
         eventLog: EventLogWriter? = nil, saveController: SaveController? = nil) {
        self.engine = engine
        self.source = source
        self.renderer = renderer
        self.screen = screen
        self.pointerSource = pointerSource
        self.hitTestTimer = hitTestTimer
        self.eventLog = eventLog
        self.saveController = saveController
    }

    /// 退出时停止循环并同步保存（Requirement 1.9、22.1）。重复调用只保存一次。
    func saveForTermination() {
        guard !savedForTermination else { return }
        savedForTermination = true
        stop()
        saveController?.saveNow(engine.makeSave(now: Date()))
    }

    private var savedForTermination = false

    func start() {
        guard timer == nil else { return }
        pointerSource?.onMouseDown = { [weak self] in
            self?.handleMouseDown()
        }
        pointerSource?.delegate = renderGate
        applyRenderRate(currentRate)
        tick()
        schedule(rate: currentRate)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 加入一条菜单命令，下一帧生效。
    func enqueue(_ command: Command) {
        pendingCommands.append(command)
    }

    /// 低频档位下收到按下事件时立即走一帧，`step` 看到鼠标事件后给出 `.active`，
    /// 循环随即切回 Active_Poll_Rate（Requirement 24.5）。高频档位下等下一帧即可。
    private func handleMouseDown() {
        guard timer != nil, currentRate == .idle else { return }
        tick()
    }

    /// 前台应用或桌面空间变化时立即走一帧，重新判定全屏（任务 17.6）。
    func refreshNow() {
        guard timer != nil else { return }
        tick()
    }

    /// 按全屏判定隐藏或恢复世界（Requirement 23.1 至 23.4）。只改显示和鼠标穿透，
    /// 世界照常 `step`，状态不变（Requirement 23.3）。
    private func applyFullscreen(_ hidden: Bool) {
        guard hidden != isWorldHidden else { return }
        isWorldHidden = hidden
        renderer.isWorldHidden = hidden
        hitTestTimer?.isSuppressed = hidden
        // 立即切到穿透（或按指针位置恢复接收），不等下一个 50ms 周期。
        hitTestTimer?.update()
        setNeedsRender()
    }

    // MARK: - 循环

    private func schedule(rate: PollRate) {
        timer?.invalidate()
        let interval = 1.0 / rate.hertz(engine.constants)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Timer 加在主 run loop 上，回调必然在主线程。
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        // 允许少量误差，系统可以合并唤醒（Requirement 29.1）。
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        currentRate = rate
        applyRenderRate(rate)
    }

    /// SKView 的渲染频率跟随轮询频率：世界每个周期只更新一次，渲染得更快只是重复画同一帧。
    private func applyRenderRate(_ rate: PollRate) {
        pointerSource?.preferredFramesPerSecond = Int(rate.hertz(engine.constants).rounded())
        renderer.loopAnimationFPS = rate == .idle ? SceneRenderer.idleAnimationFPS
                                                  : SceneRenderer.residentAnimationFPS
    }

    /// 只在场景节点有变化时放行渲染（见 `RenderGate`，Requirement 29.1）。
    private let renderGate = RenderGate()

    /// 应用层在 `WorldView` 之外直接改了场景（例如全屏时隐藏根节点、Overlay 改变尺寸）时调用，
    /// 让接下来的帧重新渲染。
    func setNeedsRender() {
        renderGate.markChanged()
    }

    // MARK: - 显示变化（任务 17.4）

    /// 主显示器尺寸或 `visibleFrame` 变化、或系统唤醒后调用（Requirement 23.5、23.6）。
    /// 更新坐标转换、窗口读取和渲染使用的屏幕信息；下一帧 `step` 看到新的 `ScreenInfo` 后重算 Ground 和全部
    /// Window_Ledge，并把 Ground 上的对象夹紧到新 Ground 内（Requirement 23.7、23.8）。循环在运行时立即走一帧。
    func displayDidChange(screen: ScreenInfo, geometry: ScreenGeometry, overlayFrame: CGRect) {
        self.screen = screen
        source.screen = screen
        renderer.overlayDidMove(to: overlayFrame, geometry: geometry)
        hitTestTimer?.geometry = geometry
        pointerSource?.geometry = geometry
        setNeedsRender()
        if timer != nil {
            // 屏幕变化的样本让 `step` 给出 `.active`，`tick` 随即按新频率重设定时器。
            tick()
        }
    }

    /// 没有主显示器（`NSScreen.screens` 为空）时暂停循环，等屏幕参数变化后由 `resume` 恢复。
    private(set) var isSuspended = false

    func suspend() {
        guard !isSuspended, !savedForTermination else { return }
        isSuspended = true
        stop()
    }

    func resume() {
        guard isSuspended, !savedForTermination else { return }
        isSuspended = false
        start()
    }

    private func tick() {
        let poll = source.poll()
        if let fullscreenMonitor {
            applyFullscreen(fullscreenMonitor.isFullscreen(onScreen: source.lastOnScreen, screen: screen))
        }
        let commands = pendingCommands
        pendingCommands.removeAll()
        let pointer = pointerSource?.drain() ?? []

        let now = Date()
        let output = engine.step(FrameInput(poll: poll, screen: screen, pointer: pointer,
                                            commands: commands, now: now))
        // 隐藏期间节点照常更新（恢复时立即是最新画面），但不为此重新渲染隐藏的画面。
        if renderer.render(output.view), !isWorldHidden {
            renderGate.markChanged()
        }
        hitTestTimer?.view = output.view
        eventLog?.write(output.events)
        saveController?.autosaveIfDue(now: now) { engine.makeSave(now: now) }
        if !pointer.isEmpty {
            // 按下或松开后立刻按新的手势状态重新判定穿透，不等下一个 50ms 周期。
            hitTestTimer?.update()
        }

        if output.nextRate != currentRate, timer != nil {
            schedule(rate: output.nextRate)
        }
    }
}
