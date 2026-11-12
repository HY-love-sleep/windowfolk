import AppKit
import SpriteKit

/// 铺满主显示器的透明覆盖层（Requirement 1.2 至 1.5）。
///
/// - 无边框、非激活面板，不会成为 key / main window，点击后原前台应用保持前台。
/// - 透明背景、无阴影，`.floating` 层级，加入所有桌面空间。
/// - 默认 `ignoresMouseEvents = true`，鼠标事件全部穿透；之后由 HitTestTimer 按命中区域切换。
@MainActor
final class OverlayPanel: NSPanel {
    /// 内容视图，同时负责把鼠标事件转成 Core 的 `PointerEvent`。
    let skView: PointerBridge
    let scene: SKScene

    init(frame: CGRect) {
        skView = PointerBridge(frame: CGRect(origin: .zero, size: frame.size))
        scene = SKScene(size: frame.size)

        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        // 接收鼠标事件时也不成为 key window，前台应用和键盘焦点保持不变（Requirement 1.5）。
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = false

        skView.allowsTransparency = true
        skView.autoresizingMask = [.width, .height]
        scene.backgroundColor = .clear
        scene.anchorPoint = CGPoint(x: 0, y: 0)
        scene.scaleMode = .resizeFill
        skView.presentScene(scene)

        contentView = skView
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 主显示器完整 frame（含菜单栏和 Dock 区域）。必须用 `screens.first`，
    /// `NSScreen.main` 指的是当前 key window 所在的屏幕。
    static func mainDisplayFrame() -> CGRect? {
        NSScreen.screens.first?.frame
    }

    /// 屏幕参数变化时重设尺寸，场景随之调整。
    func resize(to frame: CGRect) {
        setFrame(frame, display: true)
        scene.size = frame.size
    }
}
