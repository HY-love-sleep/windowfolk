import Foundation

// MARK: - Thought（Requirement 14）

/// 发给 LLM_Client 的一次 Thought 请求。`id` 由 `ThoughtEngine` 分配，结果按 id 交回。
public struct ThoughtRequest: Hashable, Sendable {
    public var id: UInt64
    public var resident: ResidentID
    public var payload: PromptPayload

    public init(id: UInt64, resident: ResidentID, payload: PromptPayload) {
        self.id = id
        self.resident = resident
        self.payload = payload
    }
}

/// 一次 Thought 请求的结果：LLM 返回的原始文本，或失败（超时、错误状态、空文本，Requirement 12.3）。
public enum ThoughtResult: Hashable, Sendable {
    case text(String)
    case failure
}

/// 居民头顶正在显示的 Thought。`text` 已经过 `ThoughtEngine.normalize`；`now >= until` 时移除。
public struct ThoughtDisplay: Hashable, Sendable {
    public var text: String
    public var until: Date

    public init(text: String, until: Date) {
        self.text = text
        self.until = until
    }
}

/// 进行中的 Thought 请求（至多一个，Requirement 14.9）。
public struct ThoughtInFlight: Hashable, Sendable {
    public var id: UInt64
    public var resident: ResidentID

    public init(id: UInt64, resident: ResidentID) {
        self.id = id
        self.resident = resident
    }
}

// MARK: - Thought 气泡布局（Requirement 14.4、16.6、16.7）

/// Thought 文字气泡的纯布局函数（Core 坐标，y 向下）。渲染层只负责量出单行文字宽度并按这里给出的矩形绘制。
///
/// - 宽度为文字宽度加左右各 `horizontalPadding`，且不小于图标气泡宽度；高度与图标气泡相同（同一种底框，单行）。
/// - 图标气泡贴着居民头顶、留 `gap`；有 Wish_Bubble 时 Thought 气泡画在它上方再留 `gap`，两者外接矩形不相交；
///   没有时 Thought 气泡直接贴着头顶。两种气泡都以居民头顶中点水平居中。
public enum ThoughtLayout {
    /// 文字左右内边距（pt）。
    public static let horizontalPadding: Double = 8
    /// 头顶与气泡、气泡与气泡之间的间隔（pt）。
    public static let gap: Double = 2
    /// 图标气泡尺寸（Wish_Bubble 等），Thought 气泡的最小宽度和高度。
    public static var iconBubble: AssetSize { SpriteMetrics.bubble }

    /// Thought 气泡宽度：`max(textWidth + 2 × horizontalPadding, 图标气泡宽度)`。负数或 NaN 的文字宽度按 0 计。
    public static func width(textWidth: Double) -> Double {
        let w = textWidth.isNaN ? 0 : max(0, textWidth)
        return max(w + 2 * horizontalPadding, iconBubble.width)
    }

    /// 居民图形顶边中点：`position` 向上移动居民高度、`seatLift` 和 `jumpLift`。隐藏（没有位置）时为 nil。
    public static func headTop(of r: ResidentView) -> Point? {
        guard let p = r.position else { return nil }
        return Point(x: p.x, y: p.y - SpriteMetrics.resident.height - r.seatLift - r.jumpLift)
    }

    /// 贴着头顶的图标气泡（Wish_Bubble 所在位置）的外接矩形。
    public static func iconBubbleRect(headTop: Point) -> Rect {
        SpriteMetrics.rect(size: iconBubble, bottomCenter: Point(x: headTop.x, y: headTop.y - gap))
    }

    /// Thought 气泡的外接矩形。`hasWishBubble` 为 true 时位于 `iconBubbleRect` 上方并留 `gap`。
    public static func thoughtRect(textWidth: Double, headTop: Point, hasWishBubble: Bool) -> Rect {
        let bottomY = hasWishBubble ? iconBubbleRect(headTop: headTop).minY - gap : headTop.y - gap
        let size = AssetSize(width: width(textWidth: textWidth), height: iconBubble.height)
        return SpriteMetrics.rect(size: size, bottomCenter: Point(x: headTop.x, y: bottomY))
    }
}
