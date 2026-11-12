import AppKit

/// 菜单栏图标及其菜单（Requirement 1.7、1.8）。
/// 菜单从上到下依次为：「显示路面」开关、「调试」子菜单、「退出」。
@MainActor
final class StatusMenu: NSObject {
    /// 「显示路面」开关变化时调用，参数为新状态。任务 3.6 在这里发送 `toggleSurfaces` 命令。
    var onToggleSurfaces: ((Bool) -> Void)?
    /// 选择「退出」时调用。为空时直接结束应用；任务 16.3 会在退出前保存。
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let surfacesItem: NSMenuItem
    /// 调试子菜单，后续任务（8.5、11.3、13.5）往里加项。
    let debugMenu = NSMenu(title: "调试")

    /// 「显示路面」开关的当前状态，启动时默认关闭。
    private(set) var showSurfaces = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        surfacesItem = NSMenuItem(title: "显示路面", action: nil, keyEquivalent: "")
        super.init()

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "window.awning", accessibilityDescription: "窗间")
                ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: "窗间") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "窗"
            }
        }

        menu.autoenablesItems = false
        debugMenu.autoenablesItems = false

        surfacesItem.target = self
        surfacesItem.action = #selector(toggleSurfaces(_:))
        surfacesItem.state = .off
        menu.addItem(surfacesItem)

        let debugItem = NSMenuItem(title: "调试", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu
        menu.addItem(debugItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// 调试项的回调，按菜单项保存。
    private var debugHandlers: [ObjectIdentifier: () -> Void] = [:]

    /// 在调试子菜单末尾追加一项（Requirement 26.1）。各项按调用顺序排列，任意 Story_Stage 下都可选。
    @discardableResult
    func addDebugItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(debugItemSelected(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        debugHandlers[ObjectIdentifier(item)] = handler
        debugMenu.addItem(item)
        return item
    }

    @objc private func debugItemSelected(_ sender: NSMenuItem) {
        debugHandlers[ObjectIdentifier(sender)]?()
    }

    @objc private func toggleSurfaces(_ sender: NSMenuItem) {
        showSurfaces.toggle()
        surfacesItem.state = showSurfaces ? .on : .off
        onToggleSurfaces?(showSurfaces)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        if let onQuit {
            onQuit()
        } else {
            NSApp.terminate(nil)
        }
    }
}
