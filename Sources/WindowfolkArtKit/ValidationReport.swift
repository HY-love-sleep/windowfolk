import Foundation
import WindowfolkCore

// 目录校验报告（design.md「输出与报告」，Requirement 6.1、6.8、6.9）。
//
// 纯逻辑：目录列举与逐文件解码、校验由调用方完成，这里只把结果组织成报告。

/// 对一个目录运行 Asset_Validator 的报告。
public struct ValidationReport: Hashable, Sendable {
    /// 按 Asset_Catalog 顺序的 45 行，每个 Asset_Key 一行（R6.1）。
    public var lines: [String]
    /// 不对应任何 Asset_Key 的 `.png` 文件名，按字典序、去重（R6.9）。
    public var unknownFiles: [String]
    /// 45 个 Asset_Key 是否全部「通过」；与未知文件无关（R6.8、R6.9）。
    public var allPassed: Bool

    public init(lines: [String], unknownFiles: [String], allPassed: Bool) {
        self.lines = lines
        self.unknownFiles = unknownFiles
        self.allPassed = allPassed
    }

    /// 完整输出：45 行结果之后逐个列出未知文件，标为「未知文件」。
    public var outputLines: [String] {
        lines + unknownFiles.map { "\($0)  \(ValidationReport.unknownFileLabel)" }
    }

    /// 退出码：全部通过为 0，否则为 1（R6.8）。
    public var exitCode: Int32 { allPassed ? 0 : 1 }

    public static let unknownFileLabel = "未知文件"
}

extension AssetVerdict {
    /// 报告行中键名之后的状态文字：`通过`、`缺失`，或
    /// `未通过：像素尺寸、四角透明（空帧：第 2、3 帧）`。
    public var reportText: String {
        switch self {
        case .pass:
            return "通过"
        case .missing:
            return "缺失"
        case .fail(let rules, let emptyFrames):
            var text = "未通过：" + rules.map(\.rawValue).joined(separator: "、")
            if !emptyFrames.isEmpty {
                text += "（空帧：第 " + emptyFrames.map(String.init).joined(separator: "、") + " 帧）"
            }
            return text
        }
    }
}

extension AssetValidator {
    /// 生成目录报告。
    ///
    /// - Parameters:
    ///   - directoryListing: 被检查目录中的文件名（不含路径）。
    ///   - verdicts: 已校验文件的结论，以 Asset_Key 为键。
    ///
    /// 目录中没有 `<Asset_Key>.png`（文件名大小写必须完全一致）时该键为「缺失」，
    /// 不看 `verdicts`；文件存在但 `verdicts` 中没有结论时同样按「缺失」处理。
    /// 扩展名为 `.png`（不区分大小写）且不等于任何 Asset_Key 文件名的文件列为未知文件，
    /// 包括与键名只差大小写的文件。
    public static func report(directoryListing: [String], verdicts: [String: AssetVerdict]) -> ValidationReport {
        let present = Set(directoryListing)

        var lines: [String] = []
        lines.reserveCapacity(AssetCatalog.all.count)
        var allPassed = true
        for spec in AssetCatalog.all {
            let verdict: AssetVerdict = present.contains(spec.fileName)
                ? (verdicts[spec.key] ?? .missing)
                : .missing
            if verdict != .pass { allPassed = false }
            lines.append("\(spec.key)  \(verdict.reportText)")
        }

        let knownFileNames = Set(AssetCatalog.all.map(\.fileName))
        let unknownFiles = present
            .filter { $0.lowercased().hasSuffix(".png") && !knownFileNames.contains($0) }
            .sorted()

        return ValidationReport(lines: lines, unknownFiles: unknownFiles, allPassed: allPassed)
    }
}
