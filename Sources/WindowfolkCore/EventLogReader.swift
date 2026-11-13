import Foundation

/// 读取 `events.jsonl` 的内容（Requirement 13.1）。
///
/// 按 `\n` 分行，每行用 `EventCodec.decodeLine` 解码。非法 JSON、缺字段、类型未知、
/// `time` 无法解析的行都跳过；写了一半的末行解码会失败，同样跳过。其余行保持文件中的顺序。
public enum EventLogReader {
    public static func parse(_ data: Data) -> [EventRecord] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? EventCodec.decodeLine(Data($0))
        }
    }
}
