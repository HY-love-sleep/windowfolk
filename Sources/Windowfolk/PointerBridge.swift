import AppKit
import SpriteKit
import WindowfolkCore

/// Overlay 内容视图：接收鼠标左键事件，转成 Core 坐标的 `PointerEvent` 排队，
/// 由 GameLoop 在下一帧随 `FrameInput.pointer` 交给 `WorldEngine.step`（Requirement 7.3、7.11）。
///
/// 只有 HitTestTimer 让 Overlay 接收鼠标事件时（指针在命中区域内或手势进行中）这里才会收到事件；
/// Overlay 接收事件时，这些事件不会传给下方应用。
/// 坐标只经 `ScreenGeometry` 转换（Requirement 2.5）：用全局 `NSEvent.mouseLocation`，
/// 与 Overlay 自身位置无关。
@MainActor
final class PointerBridge: SKView {
    /// 坐标转换；屏幕参数变化时由外部更新。
    var geometry: ScreenGeometry?
    /// 自上一帧以来的事件，按发生顺序排列。
    private var queue: [PointerEvent] = []
    /// 收到左键按下时调用（任务 17.2）：GameLoop 在低频档位下立即处理这次按下并切回 Active_Poll_Rate，
    /// 不必等下一个 100ms 周期（Requirement 24.5）。
    var onMouseDown: (() -> Void)?
    /// 左键已在 Overlay 上按下、尚未松开。HitTestTimer 在此期间保持 Overlay 接收事件，
    /// 避免 `step` 还没处理按下事件时就切回穿透。
    private(set) var isPressed = false

    /// 取出并清空排队的事件。
    func drain() -> [PointerEvent] {
        let events = queue
        queue.removeAll()
        return events
    }

    /// 非激活面板上的第一次点击也直接送达，不需要先「激活」窗口。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        enqueue(.down(currentPoint()))
        onMouseDown?()
    }

    override func mouseDragged(with event: NSEvent) {
        enqueue(.moved(currentPoint()))
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        enqueue(.up(currentPoint()))
    }

    // 右键、滚轮在命中区域内被 Overlay 接收但不做任何事（Requirement 7.3、7.10）。
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    private func enqueue(_ event: PointerEvent) {
        // 连续拖动事件只保留最后一个位置，减少每帧处理量；按下和松开都保留。
        if case .moved = event, case .moved? = queue.last {
            queue[queue.count - 1] = event
        } else {
            queue.append(event)
        }
    }

    private func currentPoint() -> Point {
        let global = NSEvent.mouseLocation
        guard let geometry else { return ScreenGeometry.point(global) }
        return geometry.corePoint(fromAppKit: global)
    }
}
