import AppKit

// 入口：启动 NSApplication 并挂上 AppDelegate。
// NSApplication.delegate 是弱引用，这里用顶层常量保持 AppDelegate 存活。
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
