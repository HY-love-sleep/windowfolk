import AppKit
import WindowfolkCore

/// 鼠标穿透切换（Requirement 7.2 至 7.4）。
///
/// 每 50ms 读取一次 `NSEvent.mouseLocation`，经 `ScreenGeometry` 转为 Core 坐标后与最近一帧
/// `WorldView.hitRegions` 比较：命中时 Overlay 接收鼠标事件，否则全部穿透到下方应用。
/// 独立于 GameLoop，GameLoop 降频时切换延迟仍不超过 100ms；对象移动经过静止的指针同样适用。
/// 手势进行中（从按下到松开）始终保持接收。
@MainActor
final class HitTestTimer {
    static let interval: TimeInterval = 0.05

    private let panel: OverlayPanel
    private let bridge: PointerBridge
    var geometry: ScreenGeometry
    /// 最近一帧的世界快照，由 GameLoop 每帧更新。
    var view: WorldView?
    /// 世界被隐藏（全屏，任务 17.6）时为 true：始终穿透。
    var isSuppressed = false

    private var timer: Timer?

    init(panel: OverlayPanel, bridge: PointerBridge, geometry: ScreenGeometry) {
        self.panel = panel
        self.bridge = bridge
        self.geometry = geometry
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        update()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 立即按当前指针位置重新判定一次。
    func update() {
        let receive = shouldReceive()
        if panel.ignoresMouseEvents == receive {
            panel.ignoresMouseEvents = !receive
        }
    }

    private func shouldReceive() -> Bool {
        if isSuppressed { return false }
        // 手势进行中保持接收，直到松开（Requirement 7.11、24.6）。
        if bridge.isPressed || view?.isInteracting == true { return true }
        // 鼠标键已在别处按下（例如正在拖动下方应用的窗口）时不抢事件。
        if NSEvent.pressedMouseButtons != 0 { return false }
        guard let view else { return false }
        let p = geometry.corePoint(fromAppKit: NSEvent.mouseLocation)
        return HitTesting.hitTest(p, regions: view.hitRegions) != nil
    }
}
