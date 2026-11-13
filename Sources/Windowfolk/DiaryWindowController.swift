import AppKit
import SwiftUI
import WindowfolkCore

/// Diary_Window（Requirement 13.12、11.11）。
///
/// - 单例窗口：第一次 `show()` 时创建，关闭后保留，再次 `show()` 时移到最前，不新开第二个。
/// - 应用的激活策略是 `.accessory`，打开时调用 `NSApp.activate()` 才能拿到焦点。
/// - 窗口属于本进程，`WindowFilter` 按 pid 过滤，不会成为 Eligible_Window。
/// - 由 `DiaryCoordinator.make` 创建并 `attach`；协调器强持有窗口，窗口弱引用协调器。
@MainActor
final class DiaryWindowController: NSObject, NSWindowDelegate {
    private let model = DiaryViewModel()
    private var window: NSWindow?
    private weak var coordinator: DiaryCoordinator?

    func attach(_ coordinator: DiaryCoordinator) {
        self.coordinator = coordinator
        model.onWriteToday = { [weak self] in self?.writeToday() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let w = window ?? makeWindow()
        window = w
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        reload()
    }

    /// 批次结束后由协调器调用。
    func update(_ entries: [DiaryEntry]) {
        model.entries = entries
        model.loaded = true
    }

    private func reload() {
        guard let coordinator else { return }
        Task { [weak self] in
            let list = await coordinator.entries()
            self?.update(list)
        }
    }

    private func writeToday() {
        guard let coordinator, !model.isWriting else { return }
        model.isWriting = true
        Task { [weak self] in
            await coordinator.writeToday()
            // 批次结束时协调器已调用 update；这里只恢复按钮。
            self?.model.isWriting = false
        }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "日记"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: DiaryView(model: model))
        w.setContentSize(NSSize(width: 420, height: 520))
        w.delegate = self
        return w
    }
}
