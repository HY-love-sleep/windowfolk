import Foundation
import WindowfolkArtIO
import WindowfolkArtKit
import WindowfolkCore

// 命令行测试的公共夹具（任务 11.3 及 11.4 至 11.14）。
//
// - `ArtCommandFixture`：临时仓库根目录、`LocalFileStore`、捕获的输出、合法的 Prompt_Manifest 与两张设定图。
// - `ArtImageFixture`：按 Asset_Catalog 规格合成「必定通过校验」的素材图，以及必定不合规的变体。
//
// 夹具只在 `FileManager.default.temporaryDirectory` 下写文件，测试结束后调用 `remove()`。

struct ArtCommandFixture {
    let root: URL
    let store: LocalFileStore
    let standardOutput: CapturedOutput
    let standardError: CapturedOutput

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("windowfolk-art-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = LocalFileStore(
            root: root,
            timeZone: TimeZone(identifier: "UTC")!,
            now: { Date(timeIntervalSince1970: 1_700_000_000) })
        standardOutput = CapturedOutput()
        standardError = CapturedOutput()
    }

    /// 删除临时目录。
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    var stdout: String { standardOutput.text }
    var stderr: String { standardError.text }

    /// 子命令运行环境。`variables` 默认带一个测试用 Key。
    func environment(
        transport: any ImageTransport = FakeTransport([]),
        variables: [String: String] = ["OPENAI_API_KEY": defaultAPIKey]
    ) -> CommandEnvironment {
        CommandEnvironment(
            variables: variables,
            fileStore: store,
            transport: transport,
            standardOutput: standardOutput,
            standardError: standardError)
    }

    static let defaultAPIKey = "sk-test-0123456789abcdef"

    // MARK: - 清单

    /// 设计文档「Palette 初始色值」表中的四组颜色。
    static let palettes: [PaletteGroup: [PaletteColorName: RGB]] = [
        .residentA: [
            .main: RGB(r: 0xC7, g: 0xCC, b: 0xD4),
            .shadow: RGB(r: 0x9E, g: 0xA3, b: 0xAD),
            .highlight: RGB(r: 0xF2, g: 0xF3, b: 0xF5),
            .outline: RGB(r: 0x73, g: 0x78, b: 0x85),
            .blush: RGB(r: 0xFF, g: 0x9E, b: 0xA8),
        ],
        .residentB: [
            .main: RGB(r: 0xF5, g: 0xC2, b: 0x4D),
            .shadow: RGB(r: 0xD9, g: 0x9A, b: 0x3A),
            .highlight: RGB(r: 0xFF, g: 0xF1, b: 0xD6),
            .outline: RGB(r: 0xA8, g: 0x75, b: 0x1F),
            .blush: RGB(r: 0xFA, g: 0xB3, b: 0x9E),
        ],
        .wood: [
            .main: RGB(r: 0xE6, g: 0xBD, b: 0x80),
            .shadow: RGB(r: 0xB8, g: 0x83, b: 0x4F),
            .highlight: RGB(r: 0xF5, g: 0xDD, b: 0xB5),
            .outline: RGB(r: 0x73, g: 0x40, b: 0x1F),
        ],
        .plant: [
            .main: RGB(r: 0x4D, g: 0xAD, b: 0x4D),
            .shadow: RGB(r: 0x35, g: 0x7A, b: 0x3A),
            .highlight: RGB(r: 0x8F, g: 0xD1, b: 0x8A),
            .outline: RGB(r: 0x2A, g: 0x5A, b: 0x2E),
        ],
    ]

    /// 能通过 ManifestParser 的清单：45 条、帧数与目录一致、居民条目引用本人设定图。
    static func manifest() -> PromptManifest {
        PromptManifest(
            prefix: "Shared prefix for every prompt.",
            palettes: palettes,
            entries: AssetCatalog.all.map { spec in
                PromptEntry(
                    key: spec.key,
                    description: "Test description for \(spec.key).",
                    frames: spec.frames,
                    canvas: PixelSize(width: 1024, height: 1024),
                    references: AssetRules.rules(for: spec.key)?.owner.map {
                        [ManifestParser.characterSheetPath($0)]
                    } ?? [])
            })
    }

    /// 写入 `art/prompt-manifest.json`。
    @discardableResult
    func writeManifest(_ manifest: PromptManifest = ArtCommandFixture.manifest()) throws -> PromptManifest {
        try store.overwrite(ManifestPrinter.print(manifest), to: GenerateCommand.manifestPath)
        return manifest
    }

    /// 写入两张 1×1 的设定图，使 `generate` 的参考图存在性检查通过。
    func writeCharacterSheets() throws {
        let pixel = RGBAImage(width: 1, height: 1, fill: RGBA(r: 1, g: 2, b: 3, a: 255))
        let data = PNGCodec.encode(pixel)
        for owner in ResidentOwner.allCases {
            try store.overwrite(data, to: ManifestParser.characterSheetPath(owner))
        }
    }

    // MARK: - 文件

    /// 把图像编码为 PNG 写入 `path`（覆盖已有文件）。
    func writePNG(_ image: RGBAImage, to path: String) throws {
        try store.overwrite(PNGCodec.encode(image), to: path)
    }

    /// 目录中的文件名；目录不存在时为空。
    func files(in directory: String) -> [String] {
        (try? store.listDirectory(directory)) ?? []
    }
}

// MARK: - 注入失败的 FileStore

/// 在指定步骤注入失败的文件操作，用于 R5.6 的「备份或写入失败时原文件保持完整」。
struct FailingFileStore: FileStore {
    enum Step: Sendable { case backup, overwrite }
    var base: any FileStore
    var failing: Step
    var reason = "测试注入的失败"

    func url(for path: String) -> URL { base.url(for: path) }
    func fileExists(_ path: String) -> Bool { base.fileExists(path) }
    func directoryExists(_ path: String) -> Bool { base.directoryExists(path) }
    func listDirectory(_ path: String) throws(FileStoreError) -> [String] { try base.listDirectory(path) }
    func read(_ path: String) throws(FileStoreError) -> Data { try base.read(path) }
    func writeNew(_ data: Data, to path: String) throws(FileStoreError) { try base.writeNew(data, to: path) }

    func overwrite(_ data: Data, to path: String) throws(FileStoreError) {
        if failing == .overwrite {
            throw FileStoreError(step: .write, path: path, reason: reason)
        }
        try base.overwrite(data, to: path)
    }

    func backup(_ path: String, key: String) throws(FileStoreError) -> String {
        if failing == .backup {
            throw FileStoreError(step: .backup, path: path, reason: reason)
        }
        return try base.backup(path, key: key)
    }
}

// MARK: - 合成素材

/// 按 Asset_Catalog 规格合成素材图。
///
/// `compliantImage(for:)` 的输出必定通过 `AssetValidator.validate`：
/// - 尺寸等于 Expected_Pixel_Size；
/// - 每帧画一个不透明的实心矩形，各帧宽度不同，因此没有空帧、也没有「帧内容相同」；
/// - Grounded 居民与 `centeredBottom` 素材贴底且水平居中；
/// - Framed_Asset 四角 2×2 透明；
/// - `plank` 用整行同色（左右列相同），`ladder` 用整列同色（上下行相同）。
enum ArtImageFixture {
    /// 合规素材图。`key` 必须存在于 Asset_Catalog。
    static func compliantImage(for key: String) -> RGBAImage {
        guard let rules = AssetRules.rules(for: key) else {
            preconditionFailure("未知 Asset_Key：\(key)")
        }
        let spec = rules.spec
        let frameWidth = spec.expectedPixelWidth / spec.frames
        let height = spec.expectedPixelHeight
        var image = RGBAImage(width: frameWidth * spec.frames, height: height)

        if case .tile(let tiling) = rules.alignment {
            switch tiling {
            case .horizontal:
                // 每条着色行横向同色，最左列与最右列自然相同。
                for y in (height / 3)..<(height * 2 / 3) {
                    for x in 0..<image.width {
                        image[x, y] = RGBA(r: 0xE6, g: 0xBD, b: 0x80, a: 255)
                    }
                }
            case .vertical:
                // 每条着色列纵向同色，最上行与最下行自然相同。
                for x in (image.width / 3)..<(image.width * 2 / 3) {
                    for y in 0..<height {
                        image[x, y] = RGBA(r: 0xE6, g: 0xBD, b: 0x80, a: 255)
                    }
                }
            case .none:
                break
            }
        } else {
            for i in 0..<spec.frames {
                let width = min(frameWidth - 4, frameWidth / 3 + i * 2)
                let boxHeight = max(4, height / 2)
                let x = i * frameWidth + (frameWidth - width) / 2
                let y = height - boxHeight
                let color = RGBA(r: UInt8(40 + i * 20), g: 90, b: 160, a: 255)
                for py in y..<height {
                    for px in x..<(x + width) {
                        image[px, py] = color
                    }
                }
            }
        }

        if rules.isFramed {
            for i in 0..<spec.frames {
                let left = i * frameWidth
                for (ox, oy) in [(0, 0), (frameWidth - 2, 0), (0, height - 2), (frameWidth - 2, height - 2)] {
                    for y in oy..<(oy + 2) {
                        for x in (left + ox)..<(left + ox + 2) {
                            image[x, y] = .clear
                        }
                    }
                }
            }
        }
        return image
    }

    /// 必定不合规的素材图：宽度少 1 像素，校验时规则「像素尺寸」未通过。
    static func invalidImage(for key: String) -> RGBAImage {
        let image = compliantImage(for: key)
        return image.crop(PixelRect(x: 0, y: 0, width: max(1, image.width - 1), height: image.height))
    }

    /// 素材每帧的矩形。
    static func frameRects(_ key: String) -> [PixelRect] {
        guard let spec = AssetCatalog.spec(key) else { return [] }
        return FrameSlicer.frameRects(width: spec.expectedPixelWidth,
                                      height: spec.expectedPixelHeight,
                                      frames: spec.frames)
    }
}
