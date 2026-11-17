import Foundation
import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

// 非法清单的属性测试（design.md Property 2，任务 2.6）。
// 合法清单来自共享生成器 `Gen.manifest`（Support/ManifestGen.swift）；本文件只负责注入缺陷。
// 固定样例见 ManifestParserTests。

/// 可注入的单一缺陷。
fileprivate enum Mutation: String, CaseIterable, Sendable {
    case deleteEntry            // 缺 Asset_Key 条目（R2.1）
    case duplicateEntry         // 重复 Asset_Key（R2.1）
    case unknownKey             // 目录外的 Asset_Key（R2.1）
    case emptyDescription       // 描述为空（R2.2）
    case longDescription        // 描述超过 1000 字符（R2.2）
    case wrongFrames            // 帧数与 Asset_Catalog 不符（R2.4）
    case badLayout              // layout 不是 horizontal_no_gap（R2.2）
    case badCanvas              // 画布不是两个正整数（R2.2）
    case deletePaletteGroup     // 缺整组 Palette（R1.6）
    case deletePaletteColor     // 缺必需颜色（R1.6）
    case badColorValue          // 色值不是 #RRGGBB（R1.6）
    case missingReference       // 参考图不存在（R2.6）
    case residentOtherSheet     // 居民条目列出另一位的设定图（R2.13）
    case nonResidentSheet       // 非居民条目列出设定图（R2.13）
}

/// 一次变异计划：非空的缺陷子集和决定具体目标与取值的种子。
fileprivate struct MutationPlan: Sendable, CustomStringConvertible {
    var mutations: [Mutation]
    var seed: UInt64
    var description: String { "\(mutations.map(\.rawValue)) seed=\(seed)" }
}

/// 文本层面的缺陷：在第 line 行插入非法字符或非 UTF-8 字节。
fileprivate struct LineDefect: Sendable, CustomStringConvertible {
    var nonUTF8: Bool
    var lineSelector: Int
    var columnSelector: Int
    var choice: Int
    var description: String {
        "nonUTF8=\(nonUTF8) line#\(lineSelector) col#\(columnSelector) choice=\(choice)"
    }
}

/// 由种子驱动的确定性随机数（SplitMix64），用于在一次计划内挑目标和取值。
fileprivate struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

fileprivate let mutationPlans: Generator<MutationPlan, some SendableSequenceType> = zip(
    Gen.shuffled(Mutation.allCases),
    Gen<Int>.int(in: 1...Mutation.allCases.count),
    Gen<UInt64>.value(in: 0...UInt64.max)
).map { kinds, count, seed in
    MutationPlan(mutations: Array(kinds.prefix(count)), seed: seed)
}

fileprivate let lineDefects: Generator<LineDefect, some SendableSequenceType> = zip(
    Gen<Bool>.bool,
    Gen<Int>.int(in: 0...100_000),
    Gen<Int>.int(in: 0...100_000),
    Gen<Int>.int(in: 0...100)
).map { LineDefect(nonUTF8: $0, lineSelector: $1, columnSelector: $2, choice: $3) }

@Suite struct ManifestRejectionTests {

    static let sheetPaths = ResidentOwner.allCases.map(ManifestParser.characterSheetPath)

    static var badLayouts: [Any] { ["vertical", "horizontal", "Horizontal_No_Gap", "horizontal_no_gap ", "", 1] }
    static var badCanvases: [Any] { [
        "0x16", "16x0", "x16", "16x", "16X16", "abc", "", "16x16x16", "-16x16", "16 x16", "１６x16", "+16x16", 1024,
    ] }
    static var badColors: [Any] { [
        "#12345G", "123456", "#12345", "#1234567", "#GGGGGG", "red", "#12 456", " #123456", 0x123456,
    ] }
    static let illegalASCII: [UInt8] = Array("@#;'\\x*=".utf8)
    static let invalidUTF8Bytes: [UInt8] = [0xFF, 0xFE, 0xC0, 0xC1, 0x80, 0xBF, 0xF5]

    static func issues(_ result: Result<PromptManifest, ManifestIssues>) -> [ManifestIssue]? {
        if case .failure(let issues) = result { return issues.issues }
        return nil
    }

    /// 在清单的原始字典上注入计划中的缺陷，返回文件内容、fileExists 和预期的问题位置。
    fileprivate static func apply(
        _ plan: MutationPlan,
        to manifest: PromptManifest
    ) -> (data: Data, fileExists: @Sendable (String) -> Bool, expected: Set<ManifestIssue.Location>) {
        var rng = SplitMix64(state: plan.seed)
        // 不用 JSONSerialization 读：它会删掉字符串开头的 U+FEFF，改变合法描述。
        var document = try! ManifestParser.jsonObject(from: ManifestPrinter.print(manifest)) as! [String: Any]
        var palettes = document["palettes"] as! [String: Any]
        var entries = document["entries"] as! [[String: Any]]

        var existing = ManifestGen.referencedPaths(manifest)
        for sheet in sheetPaths { existing.insert(sheet); existing.insert("./" + sheet) }

        // 目标互不相同：条目缺陷各占一个 Asset_Key，Palette 缺陷各占一组。
        let keys = AssetCatalog.all.map(\.key)
        var residentKeys = keys.filter { AssetRules.rules(for: $0)?.owner != nil }.shuffled(using: &rng)
        var otherKeys = keys.filter { AssetRules.rules(for: $0)?.owner == nil }.shuffled(using: &rng)
        func anyKey() -> String {
            if Bool.random(using: &rng), !residentKeys.isEmpty { return residentKeys.removeLast() }
            return otherKeys.isEmpty ? residentKeys.removeLast() : otherKeys.removeLast()
        }
        var groups = PaletteGroup.allCases.shuffled(using: &rng)

        func edit(_ key: String, _ change: (inout [String: Any]) -> Void) {
            let i = entries.firstIndex { $0["key"] as? String == key }!
            change(&entries[i])
        }
        func appendReference(_ key: String, _ path: String) {
            edit(key) { entry in
                var refs = entry["references"] as? [String] ?? []
                refs.insert(path, at: Int.random(in: 0...refs.count, using: &rng))
                entry["references"] = refs
            }
        }

        var expected: Set<ManifestIssue.Location> = []
        // 先挑专用目标，避免通用目标占用唯一可选的键。
        let dedicated: Set<Mutation> = [.residentOtherSheet, .nonResidentSheet]
        let ordered = plan.mutations.filter(dedicated.contains) + plan.mutations.filter { !dedicated.contains($0) }
        for mutation in ordered {
            switch mutation {
            case .deleteEntry:
                let key = anyKey()
                entries.removeAll { $0["key"] as? String == key }
                expected.insert(.entry(key: key, field: "key"))
            case .duplicateEntry:
                let key = anyKey()
                let copy = entries.first { $0["key"] as? String == key }!
                entries.insert(copy, at: Int.random(in: 0...entries.count, using: &rng))
                expected.insert(.entry(key: key, field: "key"))
            case .unknownKey:
                var key = "zz_unknown_" + String(Int.random(in: 0...9999, using: &rng))
                while AssetCatalog.spec(key) != nil { key += "_x" }
                entries.insert([
                    "key": key, "description": "unknown", "frames": Int.random(in: 1...8, using: &rng),
                    "layout": FrameLayout.horizontalNoGap.rawValue, "canvas": "64x64", "references": [String](),
                ], at: Int.random(in: 0...entries.count, using: &rng))
                expected.insert(.entry(key: key, field: "key"))
            case .emptyDescription:
                let key = anyKey()
                edit(key) { $0["description"] = "" }
                expected.insert(.entry(key: key, field: "description"))
            case .longDescription:
                let key = anyKey()
                let unit = ["x", "中", "\"", "]", "\n"].randomElement(using: &rng)!
                let length = Int.random(in: (ManifestParser.maxDescriptionLength + 1)...1500, using: &rng)
                edit(key) { $0["description"] = String(repeating: unit, count: length) }
                expected.insert(.entry(key: key, field: "description"))
            case .wrongFrames:
                let key = anyKey()
                let frames = AssetCatalog.spec(key)!.frames
                var value = Int.random(in: -2...12, using: &rng)
                if value == frames { value += 1 }
                edit(key) { $0["frames"] = value }
                expected.insert(.entry(key: key, field: "frames"))
            case .badLayout:
                let key = anyKey()
                let value = badLayouts.randomElement(using: &rng)!
                edit(key) { $0["layout"] = value }
                expected.insert(.entry(key: key, field: "layout"))
            case .badCanvas:
                let key = anyKey()
                let value = badCanvases.randomElement(using: &rng)!
                edit(key) { $0["canvas"] = value }
                expected.insert(.entry(key: key, field: "canvas"))
            case .deletePaletteGroup:
                let group = groups.removeLast()
                palettes[group.rawValue] = nil
                expected.insert(.palette(group: group.rawValue, color: nil))
            case .deletePaletteColor:
                let group = groups.removeLast()
                let color = group.requiredColors.randomElement(using: &rng)!
                var row = palettes[group.rawValue] as! [String: Any]
                row[color.rawValue] = nil
                palettes[group.rawValue] = row
                expected.insert(.palette(group: group.rawValue, color: color.rawValue))
            case .badColorValue:
                let group = groups.removeLast()
                let color = group.requiredColors.randomElement(using: &rng)!
                var row = palettes[group.rawValue] as! [String: Any]
                row[color.rawValue] = badColors.randomElement(using: &rng)!
                palettes[group.rawValue] = row
                expected.insert(.palette(group: group.rawValue, color: color.rawValue))
            case .missingReference:
                let key = anyKey()
                var path = "art/missing/\(Int.random(in: 0...9999, using: &rng)).png"
                while existing.contains(path) { path += "_" }
                appendReference(key, path)
                expected.insert(.entry(key: key, field: "references"))
            case .residentOtherSheet:
                let key = residentKeys.removeLast()
                let owner = AssetRules.rules(for: key)!.owner!
                let other = ResidentOwner.allCases.first { $0 != owner }!
                let path = ManifestParser.characterSheetPath(other)
                appendReference(key, Bool.random(using: &rng) ? path : "./" + path)
                expected.insert(.entry(key: key, field: "references"))
            case .nonResidentSheet:
                let key = otherKeys.removeLast()
                let path = sheetPaths.randomElement(using: &rng)!
                appendReference(key, Bool.random(using: &rng) ? path : "./" + path)
                expected.insert(.entry(key: key, field: "references"))
            }
        }

        document["palettes"] = palettes
        document["entries"] = entries
        let data = try! JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        let paths = existing
        return (data, { paths.contains($0) }, expected)
    }

    // Feature: 美术, Property 2: 非法清单被拒绝并定位
    // **Validates: Requirements 1.6, 2.1, 2.2, 2.4, 2.6, 2.9, 2.13**
    @Test func mutatedManifestRejectedWithLocations() async {
        await propertyCheck(count: 100, input: Gen.manifest, mutationPlans) { manifest, plan in
            let (data, fileExists, expected) = Self.apply(plan, to: manifest)
            guard let issues = Self.issues(ManifestParser.parse(data, fileExists: fileExists)) else {
                Issue.record("mutated manifest parsed successfully: \(plan)")
                return
            }
            let locations = Set(issues.map(\.location))
            // 每个缺陷至少对应一条问题，且没有落在未注入缺陷位置的问题。
            #expect(expected.subtracting(locations).isEmpty, "missing locations for \(plan)")
            #expect(locations.subtracting(expected).isEmpty, "unexpected locations for \(plan): \(issues)")
        }
    }

    // Feature: 美术, Property 2: 非法清单被拒绝并定位（语法错误与非 UTF-8 定位到行）
    // **Validates: Requirements 1.6, 2.1, 2.2, 2.4, 2.6, 2.9, 2.13**
    @Test func textDefectReportsLine() async {
        await propertyCheck(count: 100, input: Gen.manifest, lineDefects) { manifest, defect in
            var bytes = Array(ManifestPrinter.print(manifest))
            // 每行的起止字节偏移（不含换行符）；文件以换行结尾，最后的空行不计。
            var lines: [Range<Int>] = []
            var start = 0
            for (i, byte) in bytes.enumerated() where byte == 0x0A {
                lines.append(start..<i)
                start = i + 1
            }
            if start < bytes.count { lines.append(start..<bytes.count) }

            let index = defect.lineSelector % lines.count
            let line = lines[index]
            let offset: Int
            let inserted: UInt8
            if defect.nonUTF8 {
                // 行内任意字节位置（含行尾换行符之前）。
                offset = line.lowerBound + defect.columnSelector % (line.count + 1)
                inserted = Self.invalidUTF8Bytes[defect.choice % Self.invalidUTF8Bytes.count]
            } else {
                // 行首缩进内的任意位置：每行都从字符串之外开始，插入的字符一定不是合法记号。
                let indent = bytes[line].prefix { $0 == 0x20 }.count
                offset = line.lowerBound + defect.columnSelector % (indent + 1)
                inserted = Self.illegalASCII[defect.choice % Self.illegalASCII.count]
            }
            bytes.insert(inserted, at: offset)

            let k = index + 1
            guard let issues = Self.issues(ManifestParser.parse(Data(bytes)) { _ in true }) else {
                Issue.record("defective text parsed successfully: \(defect)")
                return
            }
            #expect(issues.map(\.location) == [.line(k)], "\(defect) inserted 0x\(String(inserted, radix: 16)) on line \(k)")
        }
    }
}
