import Foundation
import PropertyBased
import Testing
import WindowfolkArtKit
import WindowfolkCore

/// 目录报告的属性测试（任务 7.5）。
/// _Requirements: 6.1, 6.8, 6.9_

/// 一个 Asset_Key 在被检查目录中的情形。
fileprivate enum KeyCase: Sendable, CustomStringConvertible {
    /// 目录中没有 `<key>.png`；`strayVerdict` 为真时 verdicts 里仍放一个「通过」，报告应忽略它。
    case absent(strayVerdict: Bool)
    /// 文件存在且校验通过。
    case pass
    /// 文件存在但校验未通过。
    case fail([ValidationRule], emptyFrames: [Int])
    /// 文件存在但 verdicts 中没有结论，按「缺失」处理。
    case presentWithoutVerdict

    var description: String {
        switch self {
        case .absent(let stray): return stray ? "absent(stray)" : "absent"
        case .pass: return "pass"
        case .fail(let rules, let frames): return "fail(\(rules.map(\.rawValue)), \(frames))"
        case .presentWithoutVerdict: return "presentWithoutVerdict"
        }
    }
}

/// 目录中额外的文件。
fileprivate enum ExtraFile: Sendable {
    /// 应列为未知文件的 `.png`（扩展名大小写任意，含与键名只差大小写的文件）。
    case unknownPNG(String)
    /// 非 `.png` 文件，报告应忽略。
    case ignored(String)

    var name: String {
        switch self {
        case .unknownPNG(let n), .ignored(let n): return n
        }
    }
}

fileprivate struct ReportCase: Sendable, CustomStringConvertible {
    var keyCases: [KeyCase]          // 与 AssetCatalog.all 一一对应
    var extras: [ExtraFile]
    var listing: [String]            // 打乱、含重复的目录列表
    var verdicts: [String: AssetVerdict]

    var description: String {
        let keys = zip(AssetCatalog.all, keyCases).map { "\($0.key)=\($1)" }.joined(separator: ", ")
        return "keys: [\(keys)] listing: \(listing)"
    }
}

fileprivate let catalogKeys = AssetCatalog.all.map(\.key)
fileprivate let nameAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
fileprivate let pngExtensions = [".png", ".PNG", ".Png", ".pNg"]
fileprivate let otherExtensions = [".txt", ".png.bak", ".jpg", "", ".pn", ".DS_Store"]

/// 规则子集（非空，按 allCases 顺序）与空帧序号（仅含「空帧」时非空，升序去重）。
fileprivate let failGen = zip(
    Gen<Int>.int(in: 1...((1 << ValidationRule.allCases.count) - 1)),
    Gen<Int>.int(in: 1...8).array(of: 1...4)
).map { mask, frames -> KeyCase in
    let rules = ValidationRule.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
    let emptyFrames = rules.contains(.emptyFrame) ? Array(Set(frames)).sorted() : []
    return .fail(rules, emptyFrames: emptyFrames)
}

fileprivate let keyCaseGen = zip(Gen<Int>.int(in: 0...4), failGen).map { kind, fail -> KeyCase in
    switch kind {
    case 0: return .absent(strayVerdict: false)
    case 1: return .absent(strayVerdict: true)
    case 2: return .pass
    case 3: return fail
    default: return .presentWithoutVerdict
    }
}

/// 与键名只差大小写或扩展名大小写的文件名，保证不等于该键的 fileName。
fileprivate func caseVariant(of key: String, flip: Int, ext: Int) -> String {
    var chars = Array(key)
    let letters = chars.indices.filter { chars[$0].isLetter }
    if !letters.isEmpty {
        let i = letters[flip % letters.count]
        let c = chars[i]
        chars[i] = c.isUppercase ? Character(c.lowercased()) : Character(c.uppercased())
    }
    let name = String(chars) + pngExtensions[ext % pngExtensions.count]
    return name == key + ".png" ? key.uppercased() + ".PNG" : name
}

fileprivate let extraGen = zip(
    Gen<Int>.int(in: 0...3),
    Gen<Int>.int(in: 0...(catalogKeys.count - 1)),
    Gen<Int>.int(in: 0...63),
    Gen<Int>.int(in: 0...7),
    Gen<Int>.int(in: 0...(nameAlphabet.count - 1)).array(of: 1...10)
).map { kind, keyIndex, flip, ext, chars -> ExtraFile in
    let key = catalogKeys[keyIndex]
    // 前缀 `zz~` 不出现在任何键名中，保证随机名不与键文件名重合。
    let random = "zz~" + String(chars.map { nameAlphabet[$0] })
    switch kind {
    case 0: return .unknownPNG(caseVariant(of: key, flip: flip, ext: ext))
    case 1: return .unknownPNG(random + pngExtensions[ext % pngExtensions.count])
    case 2: return .ignored(key + otherExtensions[ext % otherExtensions.count])
    default: return .ignored(random + otherExtensions[ext % otherExtensions.count])
    }
}

fileprivate let reportCaseGen = zip(
    keyCaseGen.array(of: AssetCatalog.all.count),
    Gen<Int>.int(in: 0...3),                        // 0：45 键全部通过
    extraGen.array(of: 0...8),
    Gen<Int>.int(in: 0...3).array(of: 0...6),       // 重复列出的条目
    Gen<Int>.int(in: 0...Int.max)                   // 打乱种子
).map { rawCases, allPassMode, extras, dupes, seed -> ReportCase in
    let keyCases = allPassMode == 0 ? Array(repeating: KeyCase.pass, count: rawCases.count) : rawCases

    var listing: [String] = []
    var verdicts: [String: AssetVerdict] = [:]
    for (spec, c) in zip(AssetCatalog.all, keyCases) {
        switch c {
        case .absent(let stray):
            if stray { verdicts[spec.key] = .pass }
        case .pass:
            listing.append(spec.fileName)
            verdicts[spec.key] = .pass
        case .fail(let rules, let frames):
            listing.append(spec.fileName)
            verdicts[spec.key] = .fail(rules, emptyFrames: frames)
        case .presentWithoutVerdict:
            listing.append(spec.fileName)
        }
    }
    listing += extras.map(\.name)
    for d in dupes where !listing.isEmpty {
        listing.append(listing[(d * 7919) % listing.count])
    }
    var rng = SplitMix(seed: UInt64(seed))
    listing.shuffle(using: &rng)
    return ReportCase(keyCases: keyCases, extras: extras, listing: listing, verdicts: verdicts)
}

/// 确定性的打乱用随机数。
fileprivate struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 期望的状态文字，按 R6.1 与实现约定独立构造。
fileprivate func expectedStatus(_ c: KeyCase) -> String {
    switch c {
    case .absent, .presentWithoutVerdict:
        return "缺失"
    case .pass:
        return "通过"
    case .fail(let rules, let frames):
        var text = "未通过：" + rules.map(\.rawValue).joined(separator: "、")
        if !frames.isEmpty {
            text += "（空帧：第 " + frames.map(String.init).joined(separator: "、") + " 帧）"
        }
        return text
    }
}

@Suite struct ValidationReportTests {

    // Feature: 美术, Property 20: 目录报告
    /// **Validates: Requirements 6.1, 6.8, 6.9**
    @Test func reportListsCatalogKeysThenUnknownFiles() async {
        await propertyCheck(count: 200, input: reportCaseGen) { c in
            let report = AssetValidator.report(directoryListing: c.listing, verdicts: c.verdicts)

            // R6.1：按 Asset_Catalog 顺序恰好 45 行，每行「键名  状态」。
            let expectedLines = zip(AssetCatalog.all, c.keyCases).map { "\($0.key)  \(expectedStatus($1))" }
            #expect(report.lines.count == 45)
            #expect(report.lines == expectedLines, "\(c)")

            // R6.9：未知 `.png` 去重、字典序，全部列在 45 行之后；非 png 忽略。
            let expectedUnknown = Set(c.extras.compactMap { e -> String? in
                if case .unknownPNG(let n) = e { return n } else { return nil }
            }).sorted()
            #expect(report.unknownFiles == expectedUnknown, "\(c)")
            #expect(report.outputLines == expectedLines + expectedUnknown.map { "\($0)  未知文件" }, "\(c)")

            // R6.8：只看 45 个键，与未知文件无关。
            let allPass = c.keyCases.allSatisfy { if case .pass = $0 { true } else { false } }
            #expect(report.allPassed == allPass, "\(c)")
            #expect(report.exitCode == (allPass ? 0 : 1), "\(c)")
        }
    }

    /// 示例：全部通过但有与键名只差大小写的文件和非 png 文件时，退出码仍为 0。
    @Test func caseVariantIsUnknownAndDoesNotAffectExitCode() {
        let listing = AssetCatalog.all.map(\.fileName) + ["Fruit.png", "fruit.PNG", "notes.txt", "Fruit.png"]
        let verdicts = Dictionary(uniqueKeysWithValues: AssetCatalog.all.map { ($0.key, AssetVerdict.pass) })
        let report = AssetValidator.report(directoryListing: listing, verdicts: verdicts)
        #expect(report.unknownFiles == ["Fruit.png", "fruit.PNG"])
        #expect(report.exitCode == 0)
        #expect(report.outputLines.suffix(2) == ["Fruit.png  未知文件", "fruit.PNG  未知文件"])
    }

    /// 示例：空目录 45 行全为缺失，退出码 1。
    @Test func emptyDirectoryAllMissing() {
        let report = AssetValidator.report(directoryListing: [], verdicts: [:])
        #expect(report.lines == AssetCatalog.all.map { "\($0.key)  缺失" })
        #expect(report.unknownFiles.isEmpty)
        #expect(report.exitCode == 1)
    }
}
