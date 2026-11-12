import AppKit
import WindowfolkCore

/// 全屏检测的应用层部分（任务 17.6，Requirement 23.1 至 23.4）。
///
/// - 记录前台应用 pid：启动时读取 `NSWorkspace.shared.frontmostApplication`，之后随
///   `NSWorkspace.didActivateApplicationNotification` 更新。
/// - 前台应用变化或切换桌面空间（`activeSpaceDidChangeNotification`）时调用 `onTrigger`，
///   GameLoop 随即走一帧重新判定；其余时间由 GameLoop 每次轮询后调用 `isFullscreen` 判定，
///   低频档位下也每 100ms 判定一次，满足 1 秒内隐藏和恢复的要求。
/// - 判定本身是 Core 的纯函数 `WindowfolkCore.FullscreenDetector.isFullscreen`，输入复用
///   `CGWindowSource` 本次轮询已读到的屏上列表，不额外调用 `CGWindowListCopyWindowInfo`，也不需要任何权限。
@MainActor
final class FullscreenMonitor {
    private let ownPID: Int32
    private(set) var frontPID: Int32?
    private let onTrigger: @MainActor () -> Void
    private var tokens: [NSObjectProtocol] = []

    init(ownPID: Int32 = ProcessInfo.processInfo.processIdentifier,
         onTrigger: @escaping @MainActor () -> Void) {
        self.ownPID = ownPID
        self.onTrigger = onTrigger
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func start() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.frontPID = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
                    self.onTrigger()
                }
            })
        tokens.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    self.onTrigger()
                }
            })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    /// 按本次轮询的屏上列表判定前台应用是否在主显示器上全屏。
    func isFullscreen(onScreen: [RawWindowInfo], screen: ScreenInfo) -> Bool {
        FullscreenDetector.isFullscreen(frontPID: frontPID, onScreen: onScreen, screen: screen, ownPID: ownPID)
    }
}
