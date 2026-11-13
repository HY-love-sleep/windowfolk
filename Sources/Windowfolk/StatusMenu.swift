import AppKit
import WindowfolkCore

/// 菜单栏图标及其菜单（Requirement 1.7、1.8；v2 design.md「StatusMenu」）。
/// 菜单从上到下依次为：「显示路面」开关、「日记」、「设置…」、「调试」子菜单、「退出」。
/// 所有菜单项在任意 Wish_State 和 Story_Stage 下都可以选择（v2 Requirement 17.1）。
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    /// 「显示路面」开关变化时调用，参数为新状态。任务 3.6 在这里发送 `toggleSurfaces` 命令。
    var onToggleSurfaces: ((Bool) -> Void)?
    /// 选择「日记」时调用（v2 Requirement 13.12）。
    var onShowDiary: (() -> Void)?
    /// 选择「设置…」时调用（v2 Requirement 11.2）。
    var onShowSettings: (() -> Void)?
    /// 选择「退出」时调用。为空时直接结束应用；任务 16.3 会在退出前保存。
    var onQuit: (() -> Void)?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let surfacesItem: NSMenuItem
    /// 调试子菜单。
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

        let diaryItem = NSMenuItem(title: "日记", action: #selector(showDiary(_:)), keyEquivalent: "")
        diaryItem.target = self
        menu.addItem(diaryItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

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
        let item = makeItem(title, handler: handler)
        debugMenu.addItem(item)
        return item
    }

    private func makeItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(debugItemSelected(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        debugHandlers[ObjectIdentifier(item)] = handler
        return item
    }

    private func makeSubmenu(_ title: String) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        item.submenu = sub
        return (item, sub)
    }

    // MARK: - 触发心愿（v2 Requirement 17.1、17.2）

    /// 「送花 ▸」唯一的子项：标题为下一次 Flower_Wish 的 Giver 名字，每次展开子菜单时刷新。
    private var flowerGiverItem: NSMenuItem?
    private var flowerSubmenu: NSMenu?
    private var nextFlowerGiver: (() -> ResidentID)?

    /// 居民在菜单中显示的名字。
    static func displayName(_ r: ResidentID) -> String {
        switch r {
        case .a: return "都都"
        case .b: return "嘟嘟"
        }
    }

    /// 在调试子菜单末尾加入「触发心愿 ▸」：送花（一个子项，为 `nextFlowerGiver()`）；椅子、台灯、去看看、追逐
    /// 各含「都都」「嘟嘟」。选择后调用 `trigger(type, resident)`（送花时 resident 为 nil，由 Core 取下一位 Giver）。
    func addWishTriggerMenu(nextFlowerGiver: @escaping () -> ResidentID,
                            trigger: @escaping (WishType, ResidentID?) -> Void) {
        let (root, wishMenu) = makeSubmenu("触发心愿")
        self.nextFlowerGiver = nextFlowerGiver

        let (flowerItem, flowerMenu) = makeSubmenu("送花")
        let giverItem = makeItem(Self.displayName(nextFlowerGiver())) {
            trigger(.flower, nil)
        }
        flowerMenu.addItem(giverItem)
        flowerMenu.delegate = self
        flowerGiverItem = giverItem
        flowerSubmenu = flowerMenu
        wishMenu.addItem(flowerItem)

        let titles: [(WishType, String)] = [(.chair, "椅子"), (.lamp, "台灯"), (.visit, "去看看"), (.chase, "追逐")]
        for (type, title) in titles {
            let (item, sub) = makeSubmenu(title)
            for r in ResidentID.allCases {
                sub.addItem(makeItem(Self.displayName(r)) { trigger(type, r) })
            }
            wishMenu.addItem(item)
        }
        debugMenu.addItem(root)
    }

    // MARK: - 昼夜（v2 Requirement 17.1、17.4）

    /// 「昼夜」当前选中项。不保存，每次启动为 `.auto`。
    private(set) var dayNight: DayNightOverride = .auto
    private var dayNightItems: [DayNightOverride: NSMenuItem] = [:]

    /// 在调试子菜单末尾加入「昼夜 ▸」：自动、白天、夜晚，当前选中项显示勾选。选择后调用 `select`。
    func addDayNightMenu(select: @escaping (DayNightOverride) -> Void) {
        let (root, sub) = makeSubmenu("昼夜")
        let titles: [(DayNightOverride, String)] = [(.auto, "自动"), (.day, "白天"), (.night, "夜晚")]
        for (value, title) in titles {
            let item = makeItem(title) { [weak self] in
                self?.setDayNight(value)
                select(value)
            }
            dayNightItems[value] = item
            sub.addItem(item)
        }
        setDayNight(.auto)
        debugMenu.addItem(root)
    }

    private func setDayNight(_ value: DayNightOverride) {
        dayNight = value
        for (v, item) in dayNightItems {
            item.state = v == value ? .on : .off
        }
    }

    // MARK: - NSMenuDelegate

    /// 展开「送花 ▸」前刷新子项名字（下一位 Giver 随 Flower_Wish 次数变化，v2 Requirement 8.1）。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === flowerSubmenu, let nextFlowerGiver else { return }
        flowerGiverItem?.title = Self.displayName(nextFlowerGiver())
    }

    // MARK: - 动作

    @objc private func debugItemSelected(_ sender: NSMenuItem) {
        debugHandlers[ObjectIdentifier(sender)]?()
    }

    @objc private func toggleSurfaces(_ sender: NSMenuItem) {
        showSurfaces.toggle()
        surfacesItem.state = showSurfaces ? .on : .off
        onToggleSurfaces?(showSurfaces)
    }

    @objc private func showDiary(_ sender: NSMenuItem) {
        onShowDiary?()
    }

    @objc private func showSettings(_ sender: NSMenuItem) {
        onShowSettings?()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        if let onQuit {
            onQuit()
        } else {
            NSApp.terminate(nil)
        }
    }
}
