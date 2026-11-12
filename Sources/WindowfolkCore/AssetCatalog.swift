import Foundation

// 素材清单（design.md「素材清单与占位图形」）。
//
// 这里是素材键、显示尺寸和帧数的唯一来源：
// - 应用层 AssetProvider 按这里的尺寸生成占位图形，并在任务 17.7 中按这里校验 PNG；
// - SpriteMetrics（任务 6.4）的命中区域尺寸应取自这里；
// - `docs/art-spec.md`（任务 17.7）为每个键写一个文件名，任务 17.8 用本清单校验。

/// 显示尺寸，单位 pt。PNG 按 @2x 像素提供。
public struct AssetSize: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// 图形在显示时的平铺方式。木板沿水平方向平铺，梯子沿竖直方向平铺。
public enum AssetTiling: Hashable, Sendable {
    case none
    case horizontal
    case vertical
}

/// 气泡图标的种类。全部是图形，不含文字（Requirement 15.9）。
public enum BubbleIcon: String, Hashable, Sendable, CaseIterable {
    /// 「花盆 + Receiver 头像」许愿气泡；头像由渲染层叠加。
    case wish
    /// 「...」等待气泡。
    case dots
    /// 「?」戳居民气泡（问号为图形）。
    case question
    /// 心形气泡。
    case heart
}

/// 花的生长阶段在素材键中的名称。`GrowthStage.assetStage` 映射到这里的取值，
/// 键名保持 `flower_pot` / `flower_sprout` / `flower_bloom`。
public enum FlowerAssetStage: String, Hashable, Sendable, CaseIterable {
    case pot, sprout, bloom
}

/// 一项素材的规格。
public struct AssetSpec: Hashable, Sendable {
    /// 素材键，同时是文件名主干，例如 `resident_a_walking`。
    public var key: String
    /// 每帧的显示尺寸（pt）。
    public var size: AssetSize
    /// sprite sheet 帧数；单帧素材为 1。
    public var frames: Int
    public var tiling: AssetTiling

    public init(key: String, size: AssetSize, frames: Int = 1, tiling: AssetTiling = .none) {
        self.key = key
        self.size = size
        self.frames = frames
        self.tiling = tiling
    }

    /// 对应的 PNG 文件名。
    public var fileName: String { "\(key).png" }

    /// PNG 的期望像素尺寸：@2x，帧水平排列，宽度 = 每帧宽 × 帧数。
    public var expectedPixelWidth: Int { Int((size.width * AssetCatalog.pixelScale).rounded()) * frames }
    public var expectedPixelHeight: Int { Int((size.height * AssetCatalog.pixelScale).rounded()) }
}

public enum AssetCatalog {
    /// PNG 像素与 pt 的比例（@2x）。
    public static let pixelScale: Double = 2

    // MARK: 尺寸

    public static let residentSize = AssetSize(width: 32, height: 32)
    public static let flowerSize = AssetSize(width: 20, height: 24)
    public static let fruitSize = AssetSize(width: 16, height: 16)
    /// 木板一个平铺单元的尺寸；整块木板沿水平方向平铺到实际长度。
    public static let plankTileSize = AssetSize(width: 16, height: 6)
    /// 梯子一个平铺单元的尺寸；整架梯子沿竖直方向平铺到实际高度。
    public static let ladderTileSize = AssetSize(width: 16, height: 16)
    public static let toolboxSize = AssetSize(width: 72, height: 40)
    public static let bubbleSize = AssetSize(width: 24, height: 24)

    // MARK: 键

    public static func residentKey(_ id: ResidentID, _ state: ResidentState) -> String {
        "\(id.rawValue)_\(state.rawValue)"
    }

    public static func flowerKey(_ stage: FlowerAssetStage) -> String { "flower_\(stage.rawValue)" }
    public static func flowerKey(growth stage: GrowthStage) -> String { flowerKey(stage.assetStage) }
    public static func bubbleKey(_ icon: BubbleIcon) -> String { "bubble_\(icon.rawValue)" }
    public static let fruitKey = "fruit"
    public static let plankKey = "plank"
    public static let ladderKey = "ladder"
    public static let toolboxKey = "toolbox"

    /// 每个 Resident_State 的动画帧数（两位居民相同）。
    public static func frameCount(for state: ResidentState) -> Int {
        switch state {
        case .idle: return 4
        case .walking: return 6
        case .carrying: return 6
        case .waiting: return 4
        case .falling: return 2
        case .hanging: return 2
        case .climbing: return 4
        case .planting: return 6
        case .celebrating: return 6
        }
    }

    // MARK: 清单

    /// 全部素材，按固定顺序排列：两位居民各 9 个状态、3 个生长阶段、果子、木板、梯子、工具箱、4 种气泡。
    public static let all: [AssetSpec] = {
        var specs: [AssetSpec] = []
        for id in ResidentID.allCases {
            for state in ResidentState.allCases {
                specs.append(AssetSpec(key: residentKey(id, state), size: residentSize,
                                       frames: frameCount(for: state)))
            }
        }
        for stage in FlowerAssetStage.allCases {
            specs.append(AssetSpec(key: flowerKey(stage), size: flowerSize))
        }
        specs.append(AssetSpec(key: fruitKey, size: fruitSize))
        specs.append(AssetSpec(key: plankKey, size: plankTileSize, tiling: .horizontal))
        specs.append(AssetSpec(key: ladderKey, size: ladderTileSize, tiling: .vertical))
        specs.append(AssetSpec(key: toolboxKey, size: toolboxSize))
        for icon in BubbleIcon.allCases {
            specs.append(AssetSpec(key: bubbleKey(icon), size: bubbleSize))
        }
        return specs
    }()

    private static let byKey: [String: AssetSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// 按键查找规格；不在清单中的键返回 nil。
    public static func spec(_ key: String) -> AssetSpec? { byKey[key] }

    /// 某位居民某个状态的规格。清单覆盖全部组合，因此总有结果。
    public static func residentSpec(_ id: ResidentID, _ state: ResidentState) -> AssetSpec {
        byKey[residentKey(id, state)]!
    }

    private static let byFileName: [String: AssetSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.fileName, $0) })

    /// 按文件名查找规格。文件名必须与 `AssetSpec.fileName` 完全一致（区分大小写，扩展名为小写 `.png`）。
    public static func spec(forFileName fileName: String) -> AssetSpec? { byFileName[fileName] }
}

// MARK: - PNG 校验（Requirement 25.4、25.5）

/// 一个 PNG 文件的校验结果。
public enum AssetValidation: Hashable, Sendable {
    /// 文件名、像素尺寸和帧数都符合规格。
    case valid(AssetSpec)
    /// 文件名不对应清单中的任何一项。
    case unknownFileName
    /// 高度不符，或宽度不是每帧宽度的整数倍。
    case wrongPixelSize(expectedWidth: Int, expectedHeight: Int)
    /// 高度和每帧宽度都对，但帧数不对。
    case wrongFrameCount(expected: Int, actual: Int)

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

extension AssetCatalog {
    /// 校验一个已解码 PNG 的文件名和像素尺寸。纯函数，不读文件。
    ///
    /// sprite sheet 为 @2x、帧水平排列，所以帧数由 `像素宽度 / 每帧像素宽度` 得到。
    public static func validation(fileName: String, pixelWidth: Int, pixelHeight: Int) -> AssetValidation {
        guard let spec = spec(forFileName: fileName) else { return .unknownFileName }
        let frameWidth = spec.expectedPixelWidth / spec.frames
        let expected = AssetValidation.wrongPixelSize(expectedWidth: spec.expectedPixelWidth,
                                                      expectedHeight: spec.expectedPixelHeight)
        guard pixelHeight == spec.expectedPixelHeight, frameWidth > 0,
              pixelWidth > 0, pixelWidth % frameWidth == 0 else { return expected }
        let actualFrames = pixelWidth / frameWidth
        guard actualFrames == spec.frames else {
            return .wrongFrameCount(expected: spec.frames, actual: actualFrames)
        }
        return .valid(spec)
    }

    /// `validation(...)` 的布尔版本。
    public static func validate(fileName: String, pixelWidth: Int, pixelHeight: Int) -> Bool {
        validation(fileName: fileName, pixelWidth: pixelWidth, pixelHeight: pixelHeight).isValid
    }
}

// MARK: - 素材目录（docs/art-spec.md「素材目录」）

extension AssetCatalog {
    /// 指定素材目录的环境变量。
    public static let directoryEnvironmentVariable = "WINDOWFOLK_ASSETS"
    /// `.app` 的 `Contents/Resources/` 和开发时工作目录下的素材子目录名。
    public static let directoryName = "Assets"

    /// 按优先级排列的候选素材目录：
    /// 1. 环境变量 `WINDOWFOLK_ASSETS`（非空时）；
    /// 2. `.app` 的 `Contents/Resources/Assets/`；
    /// 3. 当前工作目录下的 `Assets/`（用于 `swift run`）。
    public static func directoryCandidates(environment: [String: String],
                                           bundleResourcePath: String?,
                                           currentDirectory: String?) -> [String] {
        var result: [String] = []
        if let env = environment[directoryEnvironmentVariable], !env.isEmpty {
            result.append((env as NSString).expandingTildeInPath)
        }
        if let res = bundleResourcePath, !res.isEmpty {
            result.append((res as NSString).appendingPathComponent(directoryName))
        }
        if let cwd = currentDirectory, !cwd.isEmpty {
            result.append((cwd as NSString).appendingPathComponent(directoryName))
        }
        return result
    }

    /// 只使用第一个存在的目录；都不存在时返回 nil（全部使用占位图形，Requirement 25.6）。
    public static func selectDirectory(_ candidates: [String], isDirectory: (String) -> Bool) -> String? {
        candidates.first(where: isDirectory)
    }
}
