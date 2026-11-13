import Foundation
import WindowfolkCore

/// 应用层的事件记录写入器（design.md「线程模型」）。
///
/// 在主线程把 `EventRecord` 编码成一行 JSON，再交给后台串行队列追加到 `events.jsonl`。
/// 串行队列保证行顺序与事件发生顺序一致（Requirement 21.2）；写入失败由
/// `FileEventSink` 吞掉，不重试、不提示，不影响世界状态（Requirement 21.11）。
/// v1 只写不读（Requirement 21.12）。
@MainActor
final class EventLogWriter {
    private let sink: FileEventSink
    private let queue = DispatchQueue(label: "windowfolk.events", qos: .utility)

    init(sink: FileEventSink) {
        self.sink = sink
    }

    /// 默认写到 `~/Library/Application Support/Windowfolk/events.jsonl`；无法确定目录时返回 nil。
    static func makeDefault() -> EventLogWriter? {
        guard let dir = FileEventSink.defaultDirectory() else { return nil }
        return EventLogWriter(sink: FileEventSink(directory: dir))
    }

    func write(_ records: [EventRecord]) {
        guard !records.isEmpty else { return }
        let lines = records.map { EventCodec.encodeLine($0) }
        let sink = self.sink
        queue.async {
            for line in lines { sink.append(line) }
        }
    }

    /// 读取 `events.jsonl` 全部内容（V2 日记用，design.md「线程模型」）。
    ///
    /// 读取排在同一个串行队列上，因此不会与正在追加的行交错；文件不存在或无法读取时为 nil。
    /// 可在任意线程调用，不占主线程。
    nonisolated func readAll() async -> Data? {
        let url = sink.fileURL
        let queue = self.queue
        return await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: try? Data(contentsOf: url)) }
        }
    }
}
