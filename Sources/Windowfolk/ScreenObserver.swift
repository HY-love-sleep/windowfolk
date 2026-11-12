import AppKit

/// 监听系统唤醒和屏幕参数变化（Requirement 23.5、23.6）。
///
/// 收到 `NSWorkspace.didWakeNotification` 或 `NSApplication.didChangeScreenParametersNotification` 后
/// 立即调用 `onChange`，并在 0.5 秒和 1.5 秒后各再调用一次：唤醒后显示器可能晚一点才报告最终尺寸，
/// 补发保证 2 秒内按最终的主显示器尺寸完成重建。`onChange` 应是幂等的。
@MainActor
final class ScreenObserver {
    /// 补发的延迟（秒）。
    static let followUpDelays: [TimeInterval] = [0.5, 1.5]

    private let onChange: @MainActor () -> Void
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    /// 每次通知递增；只有最近一次通知安排的补发会执行。
    private var generation = 0

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let app = NotificationCenter.default
        tokens.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle() }
            }))
        tokens.append((app, app.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle() }
            }))
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func handle() {
        generation += 1
        let current = generation
        onChange()
        for delay in Self.followUpDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.onChange()
                }
            }
        }
    }
}
