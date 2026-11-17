import Foundation
import Testing
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

/// 仓库 `Assets/` 的素材测试（任务 12.1）。
///
/// 从 `#filePath` 推出仓库根目录，读 `Assets/`：
/// - 没有任何 Final_Asset 时整个测试标记为跳过（R6.14）；
/// - 有 1 到 44 个时逐个校验已存在的文件，并打印缺失的数量和名单，不因缺失失败（R6.15）；
/// - 45 个都存在时另外检查 R8.6、R8.8、R8.9、R8.10 中可计算的几何条件。
@Suite struct RepositoryAssetsTests {

    // MARK: - 路径

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Art
            .deletingLastPathComponent()  // WindowfolkCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
    }

    static var assetsDirectory: URL {
        packageRoot.appendingPathComponent(AssetCatalog.directoryName, isDirectory: true)
    }

    static func fileURL(for spec: AssetSpec) -> URL {
        assetsDirectory.appendingPathComponent(spec.fileName)
    }

    static func exists(_ spec: AssetSpec) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: spec).path)
    }

    /// 仓库中已有的 Asset_Key。
    static var existingKeys: [String] { AssetCatalog.all.filter(exists).map(\.key) }

    /// 缺失的 Asset_Key，按 Asset_Catalog 顺序。
    static var missingKeys: [String] { AssetCatalog.all.filter { !exists($0) }.map(\.key) }

    static var hasAnyFinalAsset: Bool { !existingKeys.isEmpty }

    static var allFinalAssetsPresent: Bool { missingKeys.isEmpty }

    // MARK: - R6.11、R6.14、R6.15

    @Test(.enabled(if: RepositoryAssetsTests.hasAnyFinalAsset, "Assets/ 中尚无 Final_Asset"))
    func existingAssetsPassValidation() throws {
        var failures: [String] = []
        for spec in AssetCatalog.all where Self.exists(spec) {
            let data: Data
            do {
                data = try Data(contentsOf: Self.fileURL(for: spec))
            } catch {
                failures.append("\(spec.key)：文件格式（无法读取）")
                continue
            }
            guard let decoded = PNGCodec.decode(data) else {
                failures.append("\(spec.key)：文件格式")
                continue
            }
            if case .fail(let rules, let emptyFrames) = AssetValidator.validate(key: spec.key, decoded: decoded) {
                var text = "\(spec.key)：未通过：" + rules.map(\.rawValue).joined(separator: "、")
                if !emptyFrames.isEmpty {
                    text += "（空帧：第 " + emptyFrames.map(String.init).joined(separator: "、") + " 帧）"
                }
                failures.append(text)
            }
        }
        for failure in failures { Issue.record("\(failure)") }

        if !Self.missingKeys.isEmpty {
            print("Assets/ 中缺少 \(Self.missingKeys.count) 个 Final_Asset："
                  + Self.missingKeys.joined(separator: "、"))
        }
    }

    // MARK: - R8.6、R8.8、R8.9、R8.10

    @Test(.enabled(if: RepositoryAssetsTests.allFinalAssetsPresent, "需要 45 个 Final_Asset"))
    func finalAssetsMatchGeometricRules() throws {
        // R8.6：toolbox 最下方不透明行位于底部 2 像素以内。
        let toolbox = try Self.image(for: "toolbox")
        #expect(Self.bottomGap(toolbox) <= 2, "toolbox 未贴底：底部空隙 \(Self.bottomGap(toolbox)) 像素")

        // R8.8：decor_lamp_on 有半透明光晕，且四角透明。
        let lampOn = try Self.image(for: "decor_lamp_on")
        #expect(Self.hasPartialAlpha(lampOn), "decor_lamp_on 没有 alpha 在 1 至 254 之间的光晕像素")
        #expect(Self.cornersTransparent(lampOn), "decor_lamp_on 的四角不透明")

        // R8.9：三张花的花盆、两张台灯的底座位置一致。
        let flowers = try ["flower_pot", "flower_sprout", "flower_bloom"].map { try Self.image(for: $0) }
        let flowerBottoms = flowers.map(Self.bottomRow)
        let flowerCenters = flowers.map(Self.anchorCenter2)
        for i in 1..<flowers.count {
            #expect(abs(flowerBottoms[i] - flowerBottoms[0]) <= 1,
                    "花盆底边行不一致：\(flowerBottoms)")
            #expect(abs(flowerCenters[i] - flowerCenters[0]) <= 2,
                    "花盆水平中心不一致（两倍坐标）：\(flowerCenters)")
        }
        let lampOff = try Self.image(for: "decor_lamp_off")
        #expect(abs(Self.bottomRow(lampOff) - Self.bottomRow(lampOn)) <= 1, "台灯底座底边行不一致")
        #expect(abs(Self.anchorCenter2(lampOff) - Self.anchorCenter2(lampOn)) <= 2,
                "台灯底座水平中心不一致（两倍坐标）")

        // R8.10：planting、celebrating、sleeping 的边界框关系。
        for owner in ResidentOwner.allCases {
            let id = owner.residentID
            let idleKey = AssetCatalog.residentKey(id, .idle)
            let idle = try Self.frameBounds(Self.image(for: idleKey), key: idleKey)[0]
            let plantingKey = AssetCatalog.residentKey(id, .planting)
            let planting = try Self.frameBounds(Self.image(for: plantingKey), key: plantingKey)
            for index in 0..<4 {
                #expect(planting[index].height < idle.height,
                        "\(id.rawValue) planting 第 \(index + 1) 帧没有蹲下（\(planting[index].height) ≥ idle \(idle.height)）")
            }
            let frameHeight = Int(AssetCatalog.residentSize.height * AssetCatalog.pixelScale)
            #expect(planting[4...].contains { Self.bottomGap($0, frameHeight: frameHeight) >= 4 },
                    "\(id.rawValue) planting 第 5、6 帧没有跳起")

            let celebratingKey = AssetCatalog.residentKey(id, .celebrating)
            let celebrating = try Self.frameBounds(Self.image(for: celebratingKey), key: celebratingKey)
            let last = celebrating[celebrating.count - 1]
            #expect(Self.bottomGap(last, frameHeight: frameHeight) <= 2,
                    "\(id.rawValue) celebrating 最后一帧未回到站姿")
            #expect(abs(last.height - idle.height) <= Int(Double(idle.height) * 0.10),
                    "\(id.rawValue) celebrating 最后一帧高度 \(last.height) 与 idle \(idle.height) 相差超过 10%")

            let sleepingKey = AssetCatalog.residentKey(id, .sleeping)
            for (index, bounds) in try Self.frameBounds(Self.image(for: sleepingKey), key: sleepingKey).enumerated() {
                #expect(bounds.width > bounds.height,
                        "\(id.rawValue) sleeping 第 \(index + 1) 帧不是横躺（\(bounds.width)×\(bounds.height)）")
            }
        }
    }

    // MARK: - 辅助

    static func image(for key: String) throws -> RGBAImage {
        let spec = try #require(AssetCatalog.spec(key))
        let data = try Data(contentsOf: fileURL(for: spec))
        return try #require(PNGCodec.decode(data)).image
    }

    /// 每帧的不透明边界框；有空帧时抛出，因为几何规则只对完整素材有意义。
    static func frameBounds(_ image: RGBAImage, key: String) throws -> [PixelRect] {
        let spec = try #require(AssetCatalog.spec(key))
        let rects = FrameSlicer.frameRects(width: image.width, height: image.height, frames: spec.frames)
        return try rects.map { rect in
            try #require(image.opaqueBounds(in: rect), "\(key) 有空帧")
        }
    }

    /// 最下方不透明行距图像底边的距离；没有不透明像素时返回 `Int.max`。
    static func bottomGap(_ image: RGBAImage) -> Int {
        guard let bounds = image.opaqueBounds() else { return Int.max }
        return image.height - 1 - bounds.maxY
    }

    static func bottomGap(_ bounds: PixelRect, frameHeight: Int) -> Int {
        frameHeight - 1 - bounds.maxY
    }

    /// 最下方不透明行；没有不透明像素时返回 `-1`。
    static func bottomRow(_ image: RGBAImage) -> Int {
        image.opaqueBounds()?.maxY ?? -1
    }

    /// 最下方 4 行不透明像素边界框的水平中心，用两倍坐标表示（避免半像素）。
    static func anchorCenter2(_ image: RGBAImage) -> Int {
        guard let bounds = image.opaqueBounds() else { return 0 }
        let top = max(bounds.minY, bounds.maxY - 4)
        let region = PixelRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
        guard let base = image.opaqueBounds(in: region) else { return 0 }
        return base.minX + base.maxX
    }

    static func hasPartialAlpha(_ image: RGBAImage) -> Bool {
        for index in stride(from: 3, to: image.pixels.count, by: 4)
        where image.pixels[index] > 0 && image.pixels[index] < 255 {
            return true
        }
        return false
    }

    static func cornersTransparent(_ image: RGBAImage) -> Bool {
        guard image.width >= 2, image.height >= 2 else { return false }
        for (x, y) in [(0, 0), (image.width - 2, 0), (0, image.height - 2), (image.width - 2, image.height - 2)] {
            for dy in 0..<2 {
                for dx in 0..<2 where image.alpha(x: x + dx, y: y + dy) != 0 { return false }
            }
        }
        return true
    }
}
