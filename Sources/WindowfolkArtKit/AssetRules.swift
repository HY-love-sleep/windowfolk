import Foundation
import WindowfolkCore

// 素材分类（design.md「素材分类（AssetRules）」）。
//
// Framed_Asset、Grounded_State 等分类不写进 WindowfolkCore（R9.5、R9.8），
// 在这里按 Asset_Key 从 AssetCatalog 推导。Post_Processor、Asset_Validator 和
// Prompt_Composer 都从这里取分类，保证三者一致。

/// 居民素材所属的居民。由 `resident_a_` / `resident_b_` 前缀确定。
public enum ResidentOwner: Hashable, Sendable, CaseIterable {
    case a, b

    /// 对应的 WindowfolkCore 居民标识。
    public var residentID: ResidentID {
        switch self {
        case .a: return .a
        case .b: return .b
        }
    }
}

/// 后处理时每帧内容的放置方式。
public enum AlignmentMode: Hashable, Sendable {
    /// Grounded_State 居民：每帧整体边界框贴底、水平居中（R4.5）。
    case groundedPerFrame
    /// 花和台灯：以最下 4 行不透明像素的边界框中心为锚点居中贴底（R4.8、R4.9）。
    case anchoredBase
    /// 非 Grounded 居民：所有帧统一平移，帧并集贴底、水平居中（R4.15）。
    case nonGroundedUniform
    /// Fruit、气泡、Chair、Visit_Flag、Toolbox：整体边界框贴底、水平居中（R4.5）。
    case centeredBottom
    /// Plank、Ladder：水平和竖直都居中，并处理平铺接缝（R4.10、R4.11）。
    case tile(AssetTiling)
}

/// 一项素材在流水线中的分类规则。
public struct AssetRules: Hashable, Sendable {
    public let spec: AssetSpec
    /// 居民素材的所属居民；非居民素材为 nil。
    public var owner: ResidentOwner?
    /// 是否属于 Grounded_State：idle、walking、carrying、waiting、running。
    public var isGrounded: Bool
    /// 是否属于 Framed_Asset：除 plank、ladder、toolbox 外全部。
    public var isFramed: Bool
    public var alignment: AlignmentMode
    /// Prompt_Composer 为该素材附加的 Palette 组，按 `PaletteGroup.allCases` 顺序。
    public var palettes: [PaletteGroup]

    /// 脚底贴住每帧底边的居民状态（Glossary「Grounded_State」）。
    public static let groundedStates: Set<ResidentState> = [.idle, .walking, .carrying, .waiting, .running]

    /// 四角不要求透明的素材键（Glossary「Framed_Asset」）。
    public static let unframedKeys: Set<String> = [
        AssetCatalog.plankKey, AssetCatalog.ladderKey, AssetCatalog.toolboxKey,
    ]

    /// 按 Asset_Key 查规则；键不在 Asset_Catalog 中时返回 nil。
    public static func rules(for key: String) -> AssetRules? {
        table[key]
    }

    /// 按 Asset_Catalog 顺序排列的全部规则。
    public static var all: [AssetRules] {
        AssetCatalog.all.compactMap { table[$0.key] }
    }

    private static let table: [String: AssetRules] = Dictionary(
        uniqueKeysWithValues: AssetCatalog.all.map { ($0.key, make($0)) }
    )

    private static func make(_ spec: AssetSpec) -> AssetRules {
        let key = spec.key
        let isFramed = !unframedKeys.contains(key)

        if let (owner, state) = residentComponents(key) {
            let grounded = groundedStates.contains(state)
            return AssetRules(
                spec: spec, owner: owner, isGrounded: grounded, isFramed: isFramed,
                alignment: grounded ? .groundedPerFrame : .nonGroundedUniform,
                palettes: [owner == .a ? .residentA : .residentB]
            )
        }

        let alignment: AlignmentMode
        let palettes: [PaletteGroup]
        if spec.tiling != .none {
            // plank、ladder
            alignment = .tile(spec.tiling)
            palettes = [.wood]
        } else if FlowerAssetStage.allCases.contains(where: { AssetCatalog.flowerKey($0) == key }) {
            alignment = .anchoredBase
            palettes = [.wood, .plant]
        } else if key == AssetCatalog.lampOffKey || key == AssetCatalog.lampOnKey {
            alignment = .anchoredBase
            palettes = []
        } else if key == AssetCatalog.fruitKey {
            alignment = .centeredBottom
            palettes = [.plant]
        } else if key == AssetCatalog.chairKey || key == AssetCatalog.toolboxKey {
            alignment = .centeredBottom
            palettes = [.wood]
        } else {
            // 全部 bubble_*、visit_flag
            alignment = .centeredBottom
            palettes = []
        }
        return AssetRules(spec: spec, owner: nil, isGrounded: false, isFramed: isFramed,
                          alignment: alignment, palettes: palettes)
    }

    /// 从 `resident_<a|b>_<state>` 解出居民和状态；不是居民素材键时返回 nil。
    private static func residentComponents(_ key: String) -> (ResidentOwner, ResidentState)? {
        for owner in ResidentOwner.allCases {
            let prefix = owner.residentID.rawValue + "_"
            guard key.hasPrefix(prefix) else { continue }
            guard let state = ResidentState(rawValue: String(key.dropFirst(prefix.count))) else { return nil }
            return (owner, state)
        }
        return nil
    }
}
