import Foundation
import WindowfolkCore

/// 应用层的存档控制（design.md「线程模型」、任务 16.3）。
///
/// - 启动时读取 `world.json`：不存在则首次开局，解析失败或版本不符则备份后首次开局（Requirement 22.11、22.12）。
/// - 运行中每满 Autosave_Interval 在主线程取存档，交给后台串行队列原子写入；
///   失败时原文件不变，下一个周期重试（Requirement 22.2、22.5）。
/// - 退出时在主线程同步写入，先等后台队列中未完成的自动保存结束，保证写入顺序（Requirement 1.9、22.1）。
@MainActor
final class SaveController {
    private let store: FileSaveStore
    private let interval: Double
    private let queue = DispatchQueue(label: "windowfolk.save", qos: .utility)

    /// 最近一次成功保存的时间。
    private(set) var lastSaveAt: Date?
    /// 最近一次尝试保存（成功或失败）的时间；下一次自动保存在此之后满 `interval` 时进行。
    private var lastAttemptAt: Date
    /// 后台写入进行中时不再排新的自动保存。
    private var writeInFlight = false

    init(store: FileSaveStore, interval: Double, now: Date = Date()) {
        self.store = store
        self.interval = interval
        self.lastAttemptAt = now
    }

    /// 默认写到 `~/Library/Application Support/Windowfolk/world.json`；无法确定目录时返回 nil。
    static func makeDefault(interval: Double) -> SaveController? {
        guard let dir = FileSaveStore.defaultDirectory() else { return nil }
        return SaveController(store: FileSaveStore(directory: dir), interval: interval)
    }

    /// 启动时读取存档；返回 nil 表示按首次开局处理。
    func loadAtLaunch(now: Date = Date()) -> SaveFile? {
        switch store.loadSave(now: now) {
        case let .loaded(save): return save
        case .missing, .corrupt: return nil
        }
    }

    /// 每帧调用：满 Autosave_Interval 时在后台写入 `makeSave()` 的结果。
    func autosaveIfDue(now: Date, makeSave: () -> SaveFile) {
        guard !writeInFlight, now.timeIntervalSince(lastAttemptAt) >= interval else { return }
        lastAttemptAt = now
        writeInFlight = true
        let save = makeSave()
        let store = self.store
        queue.async { [weak self] in
            let ok = store.save(save)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.writeInFlight = false
                    if ok { self.lastSaveAt = now }
                }
            }
        }
    }

    /// 退出时同步保存。先排在后台队列之后执行，避免旧的自动保存覆盖退出时的存档。
    /// 存档为 KB 级，原子写入远小于 2 秒；失败时原文件不变（Requirement 1.10）。
    @discardableResult
    func saveNow(_ save: SaveFile, now: Date = Date()) -> Bool {
        let store = self.store
        let ok = queue.sync { store.save(save) }
        lastAttemptAt = now
        if ok { lastSaveAt = now }
        return ok
    }
}
