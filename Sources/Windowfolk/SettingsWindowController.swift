import AppKit
import SwiftUI
import WindowfolkCore

/// Settings_Window（design.md「SettingsWindowController」，Requirement 11.2、11.11）。
///
/// 由 `AppDelegate` 创建一个实例并交给 `StatusMenu`（任务 15.6）。窗口只创建一次：
/// 已打开时 `show()` 把它移到最前，不新开第二个；关闭后保留窗口对象，再次打开时复用。
/// 窗口属于本进程，`WindowFilter` 按 pid 排除，不会成为 Eligible_Window，也不生成 Window_Ledge。
/// 设置变化通过 `model.addChangeHandler` 通知其他组件。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: LLMSettingsModel
    private var window: NSWindow?

    init(model: LLMSettingsModel) {
        self.model = model
        super.init()
    }

    /// 打开设置窗口；已打开时移到最前。激活策略是 `.accessory`，需要 `NSApp.activate()` 才能拿到焦点。
    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// 关闭时立即写入尚未保存的修改。
    func windowWillClose(_ notification: Notification) {
        model.flush()
    }
}
