import Foundation
import os
import SpriteKit

/// 只在画面有变化时让 SKView 渲染（任务 17.2，Requirement 29.1）。
///
/// SKView 按 `preferredFramesPerSecond` 每帧重绘整个全屏透明 Overlay，场景没变时这些重绘都是浪费。
/// 用 `isPaused` 逐帧开关会让 SpriteKit 反复重建 CVDisplayLink（实测出现几十个 CVDisplayLink 线程），
/// 因此这里改用 `SKViewDelegate`：在 `view(_:shouldRenderAtTime:)` 中只在 GameLoop 标记过变化之后
/// 放行若干帧，其余帧跳过。跳过的帧不改变 Overlay 上已显示的内容。
///
/// 渲染回调可能不在主线程上调用，因此计数用锁保护。
final class RenderGate: NSObject, SKViewDelegate, Sendable {
    /// 每次变化后放行的帧数。多放行一帧，防止变化恰好发生在某一帧渲染途中而没有画出来。
    static let framesPerChange = 2

    private let pending = OSAllocatedUnfairLock(initialState: RenderGate.framesPerChange)

    /// 场景节点有变化，接下来的帧需要渲染。只在主线程（GameLoop）调用。
    func markChanged() {
        pending.withLock { $0 = Self.framesPerChange }
    }

    func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
        pending.withLock { count in
            guard count > 0 else { return false }
            count -= 1
            return true
        }
    }
}
