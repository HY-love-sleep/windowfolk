import AppKit
import ImageIO
import os
import SpriteKit
import WindowfolkCore

/// 为渲染提供图形（Asset_Provider，Requirement 25）。
///
/// 每一项素材都按 `AssetCatalog` 的规格组织为一张 @2x 的水平 sprite sheet，再切成逐帧纹理。
/// 构造时（SceneRenderer 创建、Overlay 首次渲染之前）同步扫描一次素材目录，
/// 把文件名、解码、像素尺寸和帧数都合格的 PNG 放进 `loadedSheets`；其余项使用程序生成的占位图形。
/// 因为两者的 sheet 格式相同，渲染层不区分图形来源，替换 PNG 后显示尺寸和位置不变（Requirement 25.3）。
@MainActor
final class AssetProvider {
    /// 按素材键缓存的逐帧纹理。
    private var frameCache: [String: [SKTexture]] = [:]
    /// 已加载并通过校验的 PNG sprite sheet。键为素材键。
    private var loadedSheets: [String: CGImage] = [:]
    /// 本次使用的素材目录；没有任何候选目录存在时为 nil。
    private(set) var assetDirectory: String?

    /// 按 docs/art-spec.md 的查找顺序选择素材目录并加载 PNG。
    convenience init() {
        let candidates = AssetCatalog.directoryCandidates(
            environment: ProcessInfo.processInfo.environment,
            bundleResourcePath: Bundle.main.resourcePath,
            currentDirectory: FileManager.default.currentDirectoryPath
        )
        let directory = AssetCatalog.selectDirectory(candidates) { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        self.init(directory: directory)
    }

    /// 从指定目录加载 PNG；`directory` 为 nil 时全部使用占位图形（Requirement 25.6）。
    init(directory: String?) {
        assetDirectory = directory
        #if DEBUG
        let issues = Self.placeholderSelfCheckIssues()
        if issues.isEmpty {
            AssetLog.logger.debug("占位图形自检通过")
        } else {
            AssetLog.logger.fault("占位图形自检发现问题：\(issues.joined(separator: "；"), privacy: .public)")
        }
        #endif
        guard let directory else {
            AssetLog.logger.info("未找到素材目录，全部使用占位图形")
            return
        }
        loadedSheets = PNGAssetLoader.load(from: directory)
        AssetLog.logger.info("素材目录 \(directory, privacy: .public)：加载 \(self.loadedSheets.count) / \(AssetCatalog.all.count) 项 PNG")
    }

    /// 某项素材是否使用了 PNG（而非占位图形）。
    func isUsingPNG(_ key: String) -> Bool { loadedSheets[key] != nil }

    /// 某项素材的全部帧。不在清单中的键返回空数组。
    func frames(for key: String) -> [SKTexture] {
        if let cached = frameCache[key] { return cached }
        guard let spec = AssetCatalog.spec(key), let sheet = sheetImage(for: spec) else { return [] }

        let sheetTexture = SKTexture(cgImage: sheet)
        sheetTexture.filteringMode = .linear
        let frameWidth = 1.0 / Double(spec.frames)
        let textures = (0..<spec.frames).map { index -> SKTexture in
            let rect = CGRect(x: Double(index) * frameWidth, y: 0, width: frameWidth, height: 1)
            let frame = SKTexture(rect: rect, in: sheetTexture)
            frame.filteringMode = .linear
            return frame
        }
        frameCache[key] = textures
        return textures
    }

    /// 某项素材的第 `frame` 帧（按帧数取模）。
    func texture(for key: String, frame: Int = 0) -> SKTexture? {
        let all = frames(for: key)
        guard !all.isEmpty else { return nil }
        let count = all.count
        return all[((frame % count) + count) % count]
    }

    /// 某位居民某个状态的第 `frame` 帧。
    func residentTexture(_ id: ResidentID, _ state: ResidentState, frame: Int) -> SKTexture? {
        texture(for: AssetCatalog.residentKey(id, state), frame: frame)
    }

    /// 只有气泡底框、不含图标的纹理（尺寸同图标气泡），供 Thought 文字气泡横向拉伸（v2 Requirement 16.6）。
    /// 与占位图标气泡用同一个底框绘制函数；不属于素材清单，不从 PNG 加载。
    private(set) lazy var bubbleBaseTexture: SKTexture? = {
        guard let image = PlaceholderArt.bubbleBaseSheet() else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        return texture
    }()

    /// 显示尺寸（pt）。
    static func displaySize(_ size: AssetSize) -> CGSize {
        CGSize(width: size.width, height: size.height)
    }

    // MARK: - Sheet 来源

    private func sheetImage(for spec: AssetSpec) -> CGImage? {
        if let png = loadedSheets[spec.key] { return png }
        return PlaceholderArt.sheet(for: spec)
    }
}

// MARK: - PNG 加载

private enum AssetLog {
    static let logger = Logger(subsystem: "app.windowfolk", category: "assets")
}

/// 逐项加载并校验素材 PNG。任一项不合格只跳过该项，不弹出提示（Requirement 25.5）。
private enum PNGAssetLoader {
    static func load(from directory: String) -> [String: CGImage] {
        // 只认目录中实际存在、且与清单文件名完全一致（区分大小写）的文件。
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
        var sheets: [String: CGImage] = [:]
        for spec in AssetCatalog.all where names.contains(spec.fileName) {
            let path = (directory as NSString).appendingPathComponent(spec.fileName)
            guard let image = decode(path) else {
                AssetLog.logger.notice("\(spec.fileName, privacy: .public) 无法解码，使用占位图形")
                continue
            }
            let result = AssetCatalog.validation(fileName: spec.fileName,
                                                 pixelWidth: image.width, pixelHeight: image.height)
            guard result.isValid else {
                AssetLog.logger.notice("\(spec.fileName, privacy: .public) 不符合规格（\(String(describing: result), privacy: .public)，实际 \(image.width)×\(image.height)），使用占位图形")
                continue
            }
            sheets[spec.key] = image
        }
        return sheets
    }

    /// 用 ImageIO 解码 PNG，得到真实像素尺寸（不受 PNG 中 DPI 元数据影响）。
    private static func decode(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        let options = [kCGImageSourceShouldCache: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url, options),
              let type = CGImageSourceGetType(source),
              (type as String) == "public.png",
              CGImageSourceGetCount(source) >= 1 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

// MARK: - 占位图形

/// 程序生成的占位图形。坐标单位为 pt，原点在每帧左下角，y 向上（CoreGraphics 默认）。
private enum PlaceholderArt {
    static func sheet(for spec: AssetSpec) -> CGImage? {
        render(spec) { index, size, ctx in
            draw(spec.key, frame: index, frames: spec.frames, size: size, in: ctx)
        }
    }

    /// 只画气泡底框（图标气泡尺寸）。
    static func bubbleBaseSheet() -> CGImage? {
        render(AssetSpec(key: "bubble_base", size: AssetCatalog.bubbleSize)) { _, size, ctx in
            drawBubbleBase(size: size, in: ctx)
        }
    }

    /// 按规格的尺寸和帧数生成一张 @2x sprite sheet，逐帧调用 `drawFrame`（坐标为该帧的 pt）。
    private static func render(_ spec: AssetSpec, _ drawFrame: (Int, CGSize, CGContext) -> Void) -> CGImage? {
        let scale = AssetCatalog.pixelScale
        let frameW = spec.size.width
        let frameH = spec.size.height
        guard let ctx = CGContext(
            data: nil,
            width: spec.expectedPixelWidth,
            height: spec.expectedPixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for index in 0..<spec.frames {
            ctx.saveGState()
            ctx.translateBy(x: Double(index) * frameW, y: 0)
            ctx.clip(to: CGRect(x: 0, y: 0, width: frameW, height: frameH))
            drawFrame(index, CGSize(width: frameW, height: frameH), ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private static func draw(_ key: String, frame: Int, frames: Int, size: CGSize, in ctx: CGContext) {
        for id in ResidentID.allCases {
            for state in ResidentState.allCases where AssetCatalog.residentKey(id, state) == key {
                drawResident(id, state, frame: frame, in: ctx)
                return
            }
        }
        for stage in FlowerAssetStage.allCases where AssetCatalog.flowerKey(stage) == key {
            drawFlower(stage, in: ctx)
            return
        }
        for icon in BubbleIcon.allCases where AssetCatalog.bubbleKey(icon) == key {
            drawBubble(icon, size: size, in: ctx)
            return
        }
        switch key {
        case AssetCatalog.fruitKey: drawFruit(in: ctx)
        case AssetCatalog.plankKey: drawPlankTile(size: size, in: ctx)
        case AssetCatalog.ladderKey: drawLadderTile(size: size, in: ctx)
        case AssetCatalog.toolboxKey: drawToolbox(size: size, in: ctx)
        case AssetCatalog.chairKey: drawChair(size: size, in: ctx)
        case AssetCatalog.lampOffKey: drawLamp(lit: false, size: size, in: ctx)
        case AssetCatalog.lampOnKey: drawLamp(lit: true, size: size, in: ctx)
        case AssetCatalog.visitFlagKey: drawVisitFlag(size: size, in: ctx)
        default: break
        }
    }

    // MARK: 颜色

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static let ink = rgb(0.16, 0.14, 0.14)
    private static let cheek = rgb(1.0, 0.62, 0.66, 0.85)

    private struct Palette {
        var fill: CGColor
        var stroke: CGColor
        var innerEar: CGColor
    }

    private static func palette(_ id: ResidentID) -> Palette {
        switch id {
        case .a: // 都都：银渐层小猫，银灰色
            return Palette(fill: rgb(0.78, 0.80, 0.83), stroke: rgb(0.45, 0.47, 0.52), innerEar: rgb(0.95, 0.75, 0.78))
        case .b: // 嘟嘟：金丝熊，金黄色
            return Palette(fill: rgb(0.96, 0.76, 0.30), stroke: rgb(0.66, 0.46, 0.12), innerEar: rgb(0.98, 0.70, 0.62))
        }
    }

    // MARK: 居民

    /// 一帧居民的姿态参数。默认朝右，渲染层用 xScale = -1 表示朝左。
    private struct Pose {
        var bodyY: Double = 2         // 身体底边离帧底的高度
        var bodyHeight: Double = 21
        var bodyWidth: Double = 24
        var eyeLift: Double = 0       // 视线上抬（抬头张望）
        var eyeRadius: Double = 1.6
        var happyEyes = false         // 「^ ^」笑眼
        var leftFootLift: Double = 0
        var rightFootLift: Double = 0
        var armsUp = false            // 双手举过头顶
        var armsUpReach: Double = 6   // 手臂向上伸出的长度
        var climbArm: Int? = nil      // 爬梯时交替举起的手（0 左、1 右）
        var armsForward = false       // 抱着东西
        var sparkle = false           // 庆祝时的小星星
        // v2 新状态用到的参数
        var closedEyes = false        // 「︶ ︶」闭眼（睡觉）
        var headShift: Double = 0     // 头部（耳朵、五官、条纹）相对身体中心的水平偏移
        var earSpread: Double? = nil  // 耳朵分布宽度；nil 时取身体宽度
        var earsBack: Double = 0      // 耳朵向后（朝左）倒的距离
        var showFeet = true
        var legsForward = false       // 坐着时双腿向前伸
        var pawsOnLap = false         // 坐着时双手搭在腿上
        var leftFootDX: Double = 0    // 跑步时的步幅
        var rightFootDX: Double = 0
        var lean: Double = 0          // 身体前倾角度（弧度，正值向右前方倾）
        var speedLines = false        // 跑步时身后的速度线
    }

    private static func pose(_ state: ResidentState, frame: Int) -> Pose {
        var p = Pose()
        switch state {
        case .idle:
            // 呼吸：身体轻微起伏。
            p.bodyHeight = (frame % 2 == 0) ? 21 : 20
        case .sitting:
            // 坐在椅面上：身体压扁、双腿向前伸、双手搭在腿上，轻微呼吸。不画椅子。
            p.bodyY = 3
            p.bodyHeight = (frame % 2 == 0) ? 17 : 16.5
            p.bodyWidth = 25
            p.legsForward = true
            p.pawsOnLap = true
        case .sleeping:
            // 横躺、闭眼：身体扁长，头在右侧，随呼吸起伏。
            let breath: [Double] = [13, 13.5, 14, 13.5]
            p.bodyY = 1
            p.bodyHeight = breath[frame % breath.count]
            p.bodyWidth = 28
            p.headShift = 3
            p.earSpread = 22
            p.eyeLift = 1.5
            p.closedEyes = true
            p.showFeet = false
        case .running:
            // 前倾奔跑、耳朵向后，步幅比 walking 大，身后有速度线。
            let stride: [Double] = [-3, -1.5, 0, 3, 1.5, 0]
            let lift: [Double] = [3, 4.5, 3, 3, 4.5, 3]
            let phase = frame % 6
            p.bodyY = lift[phase]
            p.bodyHeight = 20
            p.leftFootDX = stride[phase]
            p.rightFootDX = -stride[phase]
            p.leftFootLift = phase < 3 ? 2.5 : 0
            p.rightFootLift = phase >= 3 ? 2.5 : 0
            p.lean = 0.16
            p.earsBack = 2.5
            p.speedLines = true
        case .walking, .carrying:
            let phase = frame % 3
            p.leftFootLift = phase == 0 ? 2 : 0
            p.rightFootLift = phase == 2 ? 2 : 0
            p.bodyY = phase == 1 ? 3 : 2
            p.armsForward = state == .carrying
        case .waiting:
            p.eyeLift = 2.5
            p.bodyHeight = (frame % 2 == 0) ? 21 : 20.5
        case .falling:
            p.armsUp = true
            p.eyeRadius = 2.2
            p.bodyY = 3 + Double(frame % 2)
            p.bodyHeight = 19
        case .hanging:
            p.armsUp = true
            p.armsUpReach = 8
            p.eyeRadius = 2.2
            p.bodyY = 1 + Double(frame % 2) * 0.5
            p.bodyHeight = 19
        case .climbing:
            p.climbArm = frame % 2
            p.leftFootLift = frame % 2 == 0 ? 2 : 0
            p.rightFootLift = frame % 2 == 1 ? 2 : 0
            p.eyeLift = 1.5
        case .planting:
            // 前半蹲下，后半跳一下。
            let squat: [Double] = [21, 18, 16, 18, 21, 21]
            let lift: [Double] = [2, 2, 2, 2, 6, 3]
            p.bodyHeight = squat[frame % squat.count]
            p.bodyWidth = 24 + (21 - p.bodyHeight) * 0.6
            p.bodyY = lift[frame % lift.count]
            p.happyEyes = frame % 6 >= 4
        case .celebrating:
            let lift: [Double] = [2, 4, 6, 4, 2, 2]
            p.bodyY = lift[frame % lift.count]
            p.armsUp = frame % 6 != 5
            p.happyEyes = true
            p.sparkle = frame % 2 == 0
            p.bodyHeight = 20
        }
        return p
    }

    private static func drawResident(_ id: ResidentID, _ state: ResidentState, frame: Int, in ctx: CGContext) {
        let pal = palette(id)
        let p = pose(state, frame: frame)
        let cx = 16.0
        let body = CGRect(x: cx - p.bodyWidth / 2, y: p.bodyY, width: p.bodyWidth, height: p.bodyHeight)
        let top = body.maxY
        let hx = cx + p.headShift
        let spread = p.earSpread ?? p.bodyWidth

        // 速度线不随身体前倾，画在身后（默认朝右，所以在左侧）。
        if p.speedLines {
            ctx.setStrokeColor(pal.stroke.copy(alpha: 0.55) ?? pal.stroke)
            ctx.setLineWidth(1)
            for (y, length) in [(9.0, 4.0), (14.0, 5.0), (19.0, 3.5)] {
                ctx.move(to: CGPoint(x: 1, y: y)); ctx.addLine(to: CGPoint(x: 1 + length, y: y))
            }
            ctx.strokePath()
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        if p.lean != 0 {
            // 以脚底中心为轴旋转；CoreGraphics 中负角度为顺时针，即向右前方倾。
            ctx.translateBy(x: cx, y: 0)
            ctx.rotate(by: -p.lean)
            ctx.translateBy(x: -cx, y: 0)
        }

        ctx.setLineWidth(1.2)
        ctx.setStrokeColor(pal.stroke)

        // 脚
        ctx.setFillColor(pal.stroke)
        if p.legsForward {
            // 坐姿：两只脚伸在身体前方（右侧），一前一后。
            ctx.fillEllipse(in: CGRect(x: cx + 5, y: body.minY - 1.5, width: 7, height: 3))
            ctx.fillEllipse(in: CGRect(x: cx + 8, y: body.minY + 0.5, width: 7, height: 3))
        } else if p.showFeet {
            let footY = max(0, p.bodyY - 2)
            ctx.fillEllipse(in: CGRect(x: cx - 8 + p.leftFootDX, y: footY + p.leftFootLift, width: 5, height: 3))
            ctx.fillEllipse(in: CGRect(x: cx + 3 + p.rightFootDX, y: footY + p.rightFootLift, width: 5, height: 3))
        }

        // 耳朵（画在身体后面）
        switch id {
        case .a: // 三角猫耳
            for side in [-1.0, 1.0] {
                let baseInner = hx + side * 3
                let baseOuter = hx + side * (spread / 2 - 1)
                let tip = CGPoint(x: hx + side * (spread / 2 - 2.5) - p.earsBack,
                                  y: min(31.5, top + 6 - p.earsBack * 0.6))
                let ear = CGMutablePath()
                ear.move(to: CGPoint(x: baseInner, y: top - 2))
                ear.addLine(to: tip)
                ear.addLine(to: CGPoint(x: baseOuter, y: top - 3))
                ear.closeSubpath()
                ctx.setFillColor(pal.fill)
                ctx.addPath(ear); ctx.drawPath(using: .fillStroke)
                let inner = CGMutablePath()
                inner.move(to: CGPoint(x: (baseInner + tip.x) / 2 + side * 0.5, y: top))
                inner.addLine(to: CGPoint(x: tip.x, y: tip.y - 2.5))
                inner.addLine(to: CGPoint(x: (baseOuter + tip.x) / 2, y: top - 0.5))
                inner.closeSubpath()
                ctx.setFillColor(pal.innerEar)
                ctx.addPath(inner); ctx.fillPath()
            }
        case .b: // 圆耳
            for side in [-1.0, 1.0] {
                let center = CGPoint(x: hx + side * (spread / 2 - 4.5) - p.earsBack * 0.6,
                                     y: min(28.5, top + 1 - p.earsBack * 0.4))
                let r = 3.6
                ctx.setFillColor(pal.fill)
                ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                ctx.drawPath(using: .fillStroke)
                ctx.setFillColor(pal.innerEar)
                ctx.fillEllipse(in: CGRect(x: center.x - 1.8, y: center.y - 1.8, width: 3.6, height: 3.6))
            }
        }

        // 举起的手臂（身体后面）
        ctx.setStrokeColor(pal.stroke)
        ctx.setLineWidth(2.4)
        if p.armsUp {
            for side in [-1.0, 1.0] {
                let start = CGPoint(x: cx + side * (p.bodyWidth / 2 - 2), y: top - 6)
                ctx.move(to: start)
                ctx.addLine(to: CGPoint(x: start.x + side * 2, y: min(31.5, top - 6 + p.armsUpReach + 4)))
            }
            ctx.strokePath()
        } else if let arm = p.climbArm {
            let side: Double = arm == 0 ? -1 : 1
            let start = CGPoint(x: cx + side * (p.bodyWidth / 2 - 3), y: top - 6)
            ctx.move(to: start)
            ctx.addLine(to: CGPoint(x: start.x, y: min(31.5, top + 4)))
            ctx.strokePath()
        }

        // 身体：圆角方块
        ctx.setLineWidth(1.2)
        ctx.setFillColor(pal.fill)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.drawPath(using: .fillStroke)

        // 都都的银渐层：头顶几道深色条纹
        if id == .a {
            ctx.setStrokeColor(pal.stroke.copy(alpha: 0.6) ?? pal.stroke)
            ctx.setLineWidth(1)
            for dx in [-3.0, 0, 3] {
                ctx.move(to: CGPoint(x: hx + dx, y: top - 1))
                ctx.addLine(to: CGPoint(x: hx + dx, y: top - 4))
            }
            ctx.strokePath()
        } else {
            // 嘟嘟：浅色肚皮
            ctx.setFillColor(rgb(1, 0.95, 0.82))
            ctx.fillEllipse(in: CGRect(x: cx - 6, y: body.minY + 1.5, width: 12, height: min(9, p.bodyHeight * 0.45)))
        }

        // 脸：默认朝右，五官稍偏右
        let faceX = hx + 1.5
        let eyeY = top - 8.5 + p.eyeLift
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)
        if p.closedEyes {
            // 闭眼：向下弯的短弧线
            ctx.setLineWidth(1.1)
            for ex in [faceX - 4.5, faceX + 4.5] {
                ctx.move(to: CGPoint(x: ex - 1.8, y: eyeY + 0.6))
                ctx.addQuadCurve(to: CGPoint(x: ex + 1.8, y: eyeY + 0.6), control: CGPoint(x: ex, y: eyeY - 1.4))
            }
            ctx.strokePath()
        } else if p.happyEyes {
            ctx.setLineWidth(1.2)
            for ex in [faceX - 4.5, faceX + 4.5] {
                ctx.move(to: CGPoint(x: ex - 1.8, y: eyeY - 0.8))
                ctx.addLine(to: CGPoint(x: ex, y: eyeY + 1))
                ctx.addLine(to: CGPoint(x: ex + 1.8, y: eyeY - 0.8))
            }
            ctx.strokePath()
        } else {
            let r = p.eyeRadius
            for ex in [faceX - 4.5, faceX + 4.5] {
                ctx.fillEllipse(in: CGRect(x: ex - r, y: eyeY - r, width: 2 * r, height: 2 * r))
            }
        }
        // 脸颊
        ctx.setFillColor(cheek)
        ctx.fillEllipse(in: CGRect(x: faceX - 9, y: eyeY - 5, width: 3.5, height: 2.2))
        ctx.fillEllipse(in: CGRect(x: faceX + 5.5, y: eyeY - 5, width: 3.5, height: 2.2))
        // 嘴
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: faceX - 1.2, y: eyeY - 3.6))
        ctx.addLine(to: CGPoint(x: faceX, y: eyeY - 4.4))
        ctx.addLine(to: CGPoint(x: faceX + 1.2, y: eyeY - 3.6))
        ctx.strokePath()

        // 抱着东西的手臂（身体前面）
        if p.armsForward {
            ctx.setFillColor(pal.fill)
            ctx.setStrokeColor(pal.stroke)
            ctx.setLineWidth(1)
            ctx.addEllipse(in: CGRect(x: cx + p.bodyWidth / 2 - 5, y: body.minY + 6, width: 6, height: 4))
            ctx.drawPath(using: .fillStroke)
        }

        // 坐着时双手搭在腿上（身体前面、靠近底边）
        if p.pawsOnLap {
            ctx.setFillColor(pal.fill)
            ctx.setStrokeColor(pal.stroke)
            ctx.setLineWidth(1)
            for x in [cx - 6.5, cx + 2.5] {
                ctx.addEllipse(in: CGRect(x: x, y: body.minY + 1, width: 5, height: 3.5))
            }
            ctx.drawPath(using: .fillStroke)
        }

        if p.sparkle {
            ctx.setStrokeColor(rgb(1.0, 0.82, 0.2))
            ctx.setLineWidth(1)
            for c in [CGPoint(x: 3, y: 28), CGPoint(x: 29, y: 26)] {
                ctx.move(to: CGPoint(x: c.x - 2, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 2, y: c.y))
                ctx.move(to: CGPoint(x: c.x, y: c.y - 2)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 2))
            }
            ctx.strokePath()
        }
    }

    // MARK: 物件

    private static func drawPot(in ctx: CGContext, center: Double, bottom: Double, width: Double, height: Double) {
        let pot = CGMutablePath()
        pot.move(to: CGPoint(x: center - width * 0.35, y: bottom))
        pot.addLine(to: CGPoint(x: center + width * 0.35, y: bottom))
        pot.addLine(to: CGPoint(x: center + width / 2, y: bottom + height))
        pot.addLine(to: CGPoint(x: center - width / 2, y: bottom + height))
        pot.closeSubpath()
        ctx.setFillColor(rgb(0.72, 0.42, 0.24))
        ctx.setStrokeColor(rgb(0.45, 0.25, 0.12))
        ctx.setLineWidth(1)
        ctx.addPath(pot)
        ctx.drawPath(using: .fillStroke)
        ctx.setFillColor(rgb(0.40, 0.26, 0.16))
        ctx.fill(CGRect(x: center - width / 2 + 1, y: bottom + height - 1.5, width: width - 2, height: 1.5))
    }

    private static func drawFlower(_ stage: FlowerAssetStage, in ctx: CGContext) {
        drawPot(in: ctx, center: 10, bottom: 0.5, width: 16, height: 10)
        let green = rgb(0.30, 0.68, 0.30)
        switch stage {
        case .pot:
            break
        case .sprout:
            ctx.setStrokeColor(green)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: 10, y: 10.5)); ctx.addLine(to: CGPoint(x: 10, y: 16))
            ctx.strokePath()
            ctx.setFillColor(green)
            ctx.fillEllipse(in: CGRect(x: 5, y: 14, width: 5, height: 3))
            ctx.fillEllipse(in: CGRect(x: 10, y: 15, width: 5, height: 3))
        case .bloom:
            ctx.setStrokeColor(green)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: 10, y: 10.5)); ctx.addLine(to: CGPoint(x: 10, y: 18))
            ctx.strokePath()
            ctx.setFillColor(green)
            ctx.fillEllipse(in: CGRect(x: 4.5, y: 12.5, width: 5, height: 3))
            ctx.setFillColor(rgb(0.92, 0.30, 0.38))
            for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 2.5) {
                let px = 10 + cos(angle) * 2.8
                let py = 19.5 + sin(angle) * 2.8
                ctx.fillEllipse(in: CGRect(x: px - 2.2, y: py - 2.2, width: 4.4, height: 4.4))
            }
            ctx.setFillColor(rgb(1.0, 0.85, 0.3))
            ctx.fillEllipse(in: CGRect(x: 8.4, y: 17.9, width: 3.2, height: 3.2))
        }
    }

    private static func drawFruit(in ctx: CGContext) {
        ctx.setFillColor(rgb(0.98, 0.58, 0.16))
        ctx.setStrokeColor(rgb(0.75, 0.38, 0.08))
        ctx.setLineWidth(1)
        ctx.addEllipse(in: CGRect(x: 1.5, y: 1, width: 13, height: 12))
        ctx.drawPath(using: .fillStroke)
        ctx.setFillColor(rgb(0.30, 0.68, 0.30))
        ctx.fillEllipse(in: CGRect(x: 8, y: 12, width: 5, height: 3))
        ctx.setFillColor(rgb(1, 1, 1, 0.6))
        ctx.fillEllipse(in: CGRect(x: 4, y: 8, width: 3, height: 2))
    }

    private static func drawPlankTile(size: CGSize, in ctx: CGContext) {
        ctx.setFillColor(rgb(0.86, 0.68, 0.45))
        ctx.fill(CGRect(x: 0, y: 0.5, width: size.width, height: size.height - 1))
        ctx.setStrokeColor(rgb(0.58, 0.40, 0.22))
        ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: 0, y: 0.9)); ctx.addLine(to: CGPoint(x: size.width, y: 0.9))
        ctx.move(to: CGPoint(x: 0, y: size.height - 0.9)); ctx.addLine(to: CGPoint(x: size.width, y: size.height - 0.9))
        ctx.move(to: CGPoint(x: size.width - 0.5, y: 1)); ctx.addLine(to: CGPoint(x: size.width - 0.5, y: size.height - 1))
        ctx.strokePath()
    }

    private static func drawLadderTile(size: CGSize, in ctx: CGContext) {
        ctx.setStrokeColor(rgb(0.62, 0.42, 0.22))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: 2.5, y: 0)); ctx.addLine(to: CGPoint(x: 2.5, y: size.height))
        ctx.move(to: CGPoint(x: size.width - 2.5, y: 0)); ctx.addLine(to: CGPoint(x: size.width - 2.5, y: size.height))
        ctx.strokePath()
        ctx.setLineWidth(1.6)
        ctx.move(to: CGPoint(x: 2.5, y: size.height / 2)); ctx.addLine(to: CGPoint(x: size.width - 2.5, y: size.height / 2))
        ctx.strokePath()
    }

    private static func drawToolbox(size: CGSize, in ctx: CGContext) {
        let box = CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 8)
        ctx.setFillColor(rgb(0.66, 0.44, 0.24))
        ctx.setStrokeColor(rgb(0.40, 0.25, 0.12))
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.drawPath(using: .fillStroke)
        // 中间隔板：左半 Plank 取物区，右半 Ladder 取物区
        ctx.move(to: CGPoint(x: size.width / 2, y: box.minY + 2)); ctx.addLine(to: CGPoint(x: size.width / 2, y: box.maxY))
        ctx.strokePath()

        // 左半：露出箱口的木板
        let plankColor = rgb(0.90, 0.74, 0.50)
        ctx.setFillColor(plankColor)
        ctx.setLineWidth(1)
        for (i, dy) in [0.0, 4.0].enumerated() {
            let r = CGRect(x: 6 + Double(i) * 2, y: box.maxY - 3 + dy, width: size.width / 2 - 14, height: 4)
            ctx.addRect(r)
            ctx.drawPath(using: .fillStroke)
        }
        // 右半：露出箱口的梯子
        let lx = size.width / 2 + 8
        let lw = size.width / 2 - 16
        ctx.setStrokeColor(rgb(0.50, 0.32, 0.16))
        ctx.setLineWidth(1.6)
        ctx.move(to: CGPoint(x: lx, y: box.maxY - 6)); ctx.addLine(to: CGPoint(x: lx, y: size.height - 0.5))
        ctx.move(to: CGPoint(x: lx + lw, y: box.maxY - 6)); ctx.addLine(to: CGPoint(x: lx + lw, y: size.height - 0.5))
        for y in [box.maxY - 2, box.maxY + 3] {
            ctx.move(to: CGPoint(x: lx, y: y)); ctx.addLine(to: CGPoint(x: lx + lw, y: y))
        }
        ctx.strokePath()
        // 箱身木纹
        ctx.setStrokeColor(rgb(0.52, 0.33, 0.17))
        ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: 4, y: box.midY - 4)); ctx.addLine(to: CGPoint(x: size.width - 4, y: box.midY - 4))
        ctx.strokePath()
    }

    // MARK: 气泡

    /// 白色圆形气泡底框，左下角一个小尾巴。返回圆心。
    @discardableResult
    private static func drawBubbleBase(size: CGSize, in ctx: CGContext) -> CGPoint {
        ctx.setFillColor(rgb(1, 1, 1, 0.96))
        ctx.setStrokeColor(rgb(0.55, 0.55, 0.58))
        ctx.setLineWidth(1)
        let circle = CGRect(x: 2, y: 3, width: size.width - 4, height: size.height - 4)
        ctx.addEllipse(in: circle)
        ctx.drawPath(using: .fillStroke)
        ctx.fillEllipse(in: CGRect(x: 3, y: 0.5, width: 3.5, height: 3.5))
        return CGPoint(x: circle.midX, y: circle.midY)
    }

    private static func drawBubble(_ icon: BubbleIcon, size: CGSize, in ctx: CGContext) {
        let c = drawBubbleBase(size: size, in: ctx)
        switch icon {
        case .wish:
            // 花盆画在左侧，右侧留给渲染层叠加 Receiver 头像
            drawPot(in: ctx, center: c.x - 3, bottom: c.y - 4.5, width: 8, height: 6)
            ctx.setStrokeColor(rgb(0.30, 0.68, 0.30))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: c.x - 3, y: c.y + 1.5)); ctx.addLine(to: CGPoint(x: c.x - 3, y: c.y + 4.5))
            ctx.strokePath()
        case .dots:
            ctx.setFillColor(ink)
            for dx in [-5.0, 0, 5] {
                ctx.fillEllipse(in: CGRect(x: c.x + dx - 1.5, y: c.y - 1.5, width: 3, height: 3))
            }
        case .question:
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(2)
            ctx.addArc(center: CGPoint(x: c.x, y: c.y + 2.5), radius: 3.2,
                       startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
            ctx.addLine(to: CGPoint(x: c.x, y: c.y - 1.8))
            ctx.strokePath()
            ctx.setFillColor(ink)
            ctx.fillEllipse(in: CGRect(x: c.x - 1.3, y: c.y - 5.8, width: 2.6, height: 2.6))
        case .heart:
            ctx.setFillColor(rgb(0.93, 0.30, 0.42))
            let r = 3.2
            ctx.fillEllipse(in: CGRect(x: c.x - 2.6 - r, y: c.y + 1 - r, width: 2 * r, height: 2 * r))
            ctx.fillEllipse(in: CGRect(x: c.x + 2.6 - r, y: c.y + 1 - r, width: 2 * r, height: 2 * r))
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: c.x - 5.6, y: c.y - 0.2))
            tri.addLine(to: CGPoint(x: c.x + 5.6, y: c.y - 0.2))
            tri.addLine(to: CGPoint(x: c.x, y: c.y - 6))
            tri.closeSubpath()
            ctx.addPath(tri)
            ctx.fillPath()
        case .chair:
            drawChairIcon(center: c, in: ctx)
        case .lamp:
            drawLampIcon(center: c, in: ctx)
        case .flag:
            drawFlagIcon(center: c, in: ctx)
        case .flower:
            drawFlowerIcon(center: c, in: ctx)
        case .zzz:
            drawZzzIcon(center: c, in: ctx)
        case .footprints:
            drawFootprintsIcon(center: c, in: ctx)
        }
    }

    // MARK: v2 气泡图标（坐标相对气泡圆心，可用半径约 7pt）

    private static let wood = rgb(0.86, 0.68, 0.45)
    private static let woodDark = rgb(0.58, 0.40, 0.22)
    private static let warmYellow = rgb(1.0, 0.84, 0.32)

    /// 侧面的小椅子：左侧椅背、椅面、两条腿。
    private static func drawChairIcon(center c: CGPoint, in ctx: CGContext) {
        ctx.setStrokeColor(woodDark)
        ctx.setLineWidth(1.6)
        ctx.move(to: CGPoint(x: c.x - 3.5, y: c.y + 6)); ctx.addLine(to: CGPoint(x: c.x - 3.5, y: c.y - 5.5))
        ctx.move(to: CGPoint(x: c.x + 4, y: c.y - 0.5)); ctx.addLine(to: CGPoint(x: c.x + 4, y: c.y - 5.5))
        ctx.strokePath()
        ctx.setFillColor(wood)
        ctx.setLineWidth(1)
        ctx.addRect(CGRect(x: c.x - 4, y: c.y - 1.5, width: 9, height: 2))
        ctx.drawPath(using: .fillStroke)
    }

    /// 小台灯：暖黄灯罩、细杆、底座。
    private static func drawLampIcon(center c: CGPoint, in ctx: CGContext) {
        ctx.setStrokeColor(woodDark)
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: c.x, y: c.y + 1)); ctx.addLine(to: CGPoint(x: c.x, y: c.y - 4.5))
        ctx.strokePath()
        ctx.setFillColor(woodDark)
        ctx.fill(CGRect(x: c.x - 3.5, y: c.y - 6, width: 7, height: 1.6))
        let shade = CGMutablePath()
        shade.move(to: CGPoint(x: c.x - 5, y: c.y + 1))
        shade.addLine(to: CGPoint(x: c.x + 5, y: c.y + 1))
        shade.addLine(to: CGPoint(x: c.x + 2.5, y: c.y + 6))
        shade.addLine(to: CGPoint(x: c.x - 2.5, y: c.y + 6))
        shade.closeSubpath()
        ctx.setFillColor(warmYellow)
        ctx.setStrokeColor(rgb(0.75, 0.55, 0.12))
        ctx.setLineWidth(1)
        ctx.addPath(shade)
        ctx.drawPath(using: .fillStroke)
    }

    /// 小旗加一个指向右方的箭头；Visit_Flag 在左边时由渲染层水平镜像整个气泡。
    private static func drawFlagIcon(center c: CGPoint, in ctx: CGContext) {
        let poleX = c.x - 4.5
        ctx.setStrokeColor(woodDark)
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: poleX, y: c.y - 6)); ctx.addLine(to: CGPoint(x: poleX, y: c.y + 6.5))
        ctx.strokePath()
        let flag = CGMutablePath()
        flag.move(to: CGPoint(x: poleX + 0.5, y: c.y + 6.5))
        flag.addLine(to: CGPoint(x: poleX + 0.5, y: c.y + 1.5))
        flag.addLine(to: CGPoint(x: poleX + 6.5, y: c.y + 4))
        flag.closeSubpath()
        ctx.setFillColor(rgb(0.90, 0.25, 0.25))
        ctx.addPath(flag)
        ctx.fillPath()
        // 箭头 →
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(1.4)
        let ay = c.y - 3
        ctx.move(to: CGPoint(x: c.x - 2, y: ay)); ctx.addLine(to: CGPoint(x: c.x + 6, y: ay))
        ctx.move(to: CGPoint(x: c.x + 3.5, y: ay + 2.5)); ctx.addLine(to: CGPoint(x: c.x + 6, y: ay))
        ctx.addLine(to: CGPoint(x: c.x + 3.5, y: ay - 2.5))
        ctx.strokePath()
    }

    /// 一朵花：五瓣花冠、花心、茎和一片叶子。
    private static func drawFlowerIcon(center c: CGPoint, in ctx: CGContext) {
        let green = rgb(0.30, 0.68, 0.30)
        ctx.setStrokeColor(green)
        ctx.setLineWidth(1.3)
        ctx.move(to: CGPoint(x: c.x, y: c.y + 1)); ctx.addLine(to: CGPoint(x: c.x, y: c.y - 6.5))
        ctx.strokePath()
        ctx.setFillColor(green)
        ctx.fillEllipse(in: CGRect(x: c.x, y: c.y - 4.5, width: 4.5, height: 2.4))
        let head = CGPoint(x: c.x, y: c.y + 2.5)
        ctx.setFillColor(rgb(0.95, 0.45, 0.62))
        for i in 0..<5 {
            let angle = Double.pi / 2 + Double(i) * 2 * Double.pi / 5
            let px = head.x + cos(angle) * 2.6
            let py = head.y + sin(angle) * 2.6
            ctx.fillEllipse(in: CGRect(x: px - 2, y: py - 2, width: 4, height: 4))
        }
        ctx.setFillColor(rgb(1.0, 0.85, 0.3))
        ctx.fillEllipse(in: CGRect(x: head.x - 1.5, y: head.y - 1.5, width: 3, height: 3))
    }

    /// 三个由大到小的 Z 字形，用线条画出（v2 Requirement 5.6）。
    private static func drawZzzIcon(center c: CGPoint, in ctx: CGContext) {
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(1.2)
        let zs: [(x: Double, y: Double, size: Double)] = [
            (c.x - 7, c.y - 6, 5), (c.x - 1, c.y, 4), (c.x + 3.5, c.y + 4, 2.6),
        ]
        for z in zs {
            ctx.move(to: CGPoint(x: z.x, y: z.y + z.size))
            ctx.addLine(to: CGPoint(x: z.x + z.size, y: z.y + z.size))
            ctx.addLine(to: CGPoint(x: z.x, y: z.y))
            ctx.addLine(to: CGPoint(x: z.x + z.size, y: z.y))
        }
        ctx.strokePath()
    }

    /// 两枚小脚印，一前一后斜着排列。
    private static func drawFootprintsIcon(center c: CGPoint, in ctx: CGContext) {
        ctx.setFillColor(rgb(0.50, 0.36, 0.26))
        for origin in [CGPoint(x: c.x - 4, y: c.y - 5), CGPoint(x: c.x + 2.5, y: c.y - 0.5)] {
            ctx.fillEllipse(in: CGRect(x: origin.x - 1.8, y: origin.y, width: 3.6, height: 4.6))
            for (dx, dy) in [(-1.6, 5.4), (0.0, 6.1), (1.6, 5.4)] {
                ctx.fillEllipse(in: CGRect(x: origin.x + dx - 0.8, y: origin.y + dy - 0.8, width: 1.6, height: 1.6))
            }
        }
    }

    // MARK: v2 装饰物与串门小旗

    /// Chair：椅背、椅面加四条腿，木色与木板、梯子一致，四条腿贴住底边。
    /// 椅面顶边约在 13pt，居民坐下时被渲染层上移 10pt 画在椅面上。
    private static func drawChair(size: CGSize, in ctx: CGContext) {
        let w = size.width
        // 后腿（细、颜色稍深，表示在后方）
        ctx.setStrokeColor(woodDark)
        ctx.setLineWidth(1.4)
        for x in [7.0, w - 7] {
            ctx.move(to: CGPoint(x: x, y: 0.7)); ctx.addLine(to: CGPoint(x: x, y: 10))
        }
        ctx.strokePath()
        // 椅背：两根立柱加两道横档
        ctx.setLineWidth(2)
        for x in [4.0, w - 4] {
            ctx.move(to: CGPoint(x: x, y: 11)); ctx.addLine(to: CGPoint(x: x, y: size.height - 1))
        }
        ctx.strokePath()
        ctx.setFillColor(wood)
        ctx.setLineWidth(0.8)
        for y in [16.5, 20.5] {
            ctx.addRect(CGRect(x: 4, y: y, width: w - 8, height: 2.2))
        }
        ctx.drawPath(using: .fillStroke)
        // 椅面
        ctx.setLineWidth(1)
        ctx.addRect(CGRect(x: 2.5, y: 10, width: w - 5, height: 3))
        ctx.drawPath(using: .fillStroke)
        // 前腿（粗）
        ctx.setStrokeColor(woodDark)
        ctx.setLineWidth(2)
        for x in [4.0, w - 4] {
            ctx.move(to: CGPoint(x: x, y: 1)); ctx.addLine(to: CGPoint(x: x, y: 10))
        }
        ctx.strokePath()
    }

    /// Lamp：灯罩、细杆、底座。两种外观的几何完全一致，只有颜色和光晕不同。
    private static func drawLamp(lit: Bool, size: CGSize, in ctx: CGContext) {
        let cx = size.width / 2
        let shadeBottom = 19.0
        let shadeTop = 27.0
        if lit {
            // 半透明暖色光晕，半径不超过半个帧宽，保证不超出帧边界。
            let glowCenter = CGPoint(x: cx, y: 22)
            let colors = [rgb(1.0, 0.86, 0.40, 0.85), rgb(1.0, 0.86, 0.40, 0)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(gradient, startCenter: glowCenter, startRadius: 0,
                                       endCenter: glowCenter, endRadius: size.width / 2, options: [])
            }
        }
        // 底座与细杆
        ctx.setFillColor(rgb(0.40, 0.36, 0.34))
        ctx.fillEllipse(in: CGRect(x: cx - 5, y: 0, width: 10, height: 3))
        ctx.setStrokeColor(rgb(0.40, 0.36, 0.34))
        ctx.setLineWidth(1.4)
        ctx.move(to: CGPoint(x: cx, y: 2)); ctx.addLine(to: CGPoint(x: cx, y: shadeBottom))
        ctx.strokePath()
        // 灯泡（只在发光时可见）
        if lit {
            ctx.setFillColor(rgb(1.0, 0.97, 0.80))
            ctx.fillEllipse(in: CGRect(x: cx - 2, y: shadeBottom - 2.5, width: 4, height: 4))
        }
        // 灯罩
        let shade = CGMutablePath()
        shade.move(to: CGPoint(x: cx - 6.5, y: shadeBottom))
        shade.addLine(to: CGPoint(x: cx + 6.5, y: shadeBottom))
        shade.addLine(to: CGPoint(x: cx + 3.5, y: shadeTop))
        shade.addLine(to: CGPoint(x: cx - 3.5, y: shadeTop))
        shade.closeSubpath()
        ctx.setFillColor(lit ? warmYellow : rgb(0.55, 0.55, 0.58))
        ctx.setStrokeColor(lit ? rgb(0.80, 0.58, 0.12) : rgb(0.35, 0.35, 0.38))
        ctx.setLineWidth(1)
        ctx.addPath(shade)
        ctx.drawPath(using: .fillStroke)
    }

    /// Visit_Flag：竖杆加一面红色三角旗，杆底贴住底边。
    private static func drawVisitFlag(size: CGSize, in ctx: CGContext) {
        let poleX = 4.0
        ctx.setStrokeColor(rgb(0.45, 0.30, 0.16))
        ctx.setLineWidth(1.6)
        ctx.move(to: CGPoint(x: poleX, y: 0)); ctx.addLine(to: CGPoint(x: poleX, y: size.height - 2))
        ctx.strokePath()
        ctx.setFillColor(rgb(0.95, 0.80, 0.30))
        ctx.fillEllipse(in: CGRect(x: poleX - 1.5, y: size.height - 3, width: 3, height: 3))
        let flag = CGMutablePath()
        flag.move(to: CGPoint(x: poleX + 0.8, y: size.height - 3))
        flag.addLine(to: CGPoint(x: poleX + 0.8, y: size.height - 12))
        flag.addLine(to: CGPoint(x: size.width - 1.5, y: size.height - 7.5))
        flag.closeSubpath()
        ctx.setFillColor(rgb(0.90, 0.25, 0.25))
        ctx.setStrokeColor(rgb(0.65, 0.15, 0.15))
        ctx.setLineWidth(0.8)
        ctx.addPath(flag)
        ctx.drawPath(using: .fillStroke)
    }
}

// MARK: - 占位图形自检（仅 Debug 构建）

#if DEBUG
extension PlaceholderArt {
    /// v2 新增的 16 项素材键（v2 Requirement 16.1）。
    static var v2Keys: [String] {
        var keys: [String] = []
        for id in ResidentID.allCases {
            for state in [ResidentState.sitting, .sleeping, .running] {
                keys.append(AssetCatalog.residentKey(id, state))
            }
        }
        keys += [AssetCatalog.chairKey, AssetCatalog.lampOffKey, AssetCatalog.lampOnKey, AssetCatalog.visitFlagKey]
        keys += [BubbleIcon.chair, .lamp, .flag, .flower, .zzz, .footprints].map(AssetCatalog.bubbleKey)
        return keys
    }

    /// 检查占位图形是否满足 v2 Requirement 16.1、16.2 的可区分要求，返回发现的问题（空数组表示通过）：
    /// - 16 项新图形每一帧都有可见像素，新气泡与空白底框不同；
    /// - 同一居民 `sitting`、`sleeping`、`running` 的任一帧与该居民其他任一状态的任一帧都不同；
    /// - Lamp 发光与不发光外观不同；
    /// - 全部图标气泡两两不同。
    /// Core 测试不能依赖应用层，所以这项检查在 Debug 构建创建 AssetProvider 时运行并写日志。
    static func selfCheckIssues() -> [String] {
        var issues: [String] = []
        var cache: [String: [Data]] = [:]
        func frames(_ key: String) -> [Data] {
            if let cached = cache[key] { return cached }
            guard let spec = AssetCatalog.spec(key), let image = sheet(for: spec) else { return [] }
            let result = frameBytes(image, frames: spec.frames)
            cache[key] = result
            return result
        }

        let emptyBubble = render(AssetSpec(key: "_empty_bubble", size: AssetCatalog.bubbleSize)) { _, size, ctx in
            drawBubbleBase(size: size, in: ctx)
        }.map { frameBytes($0, frames: 1) } ?? []

        for key in v2Keys {
            let all = frames(key)
            if all.count != AssetCatalog.spec(key)?.frames { issues.append("\(key)：帧数不对") }
            for (i, frame) in all.enumerated() {
                if !hasVisiblePixel(frame) { issues.append("\(key) 第 \(i) 帧是空白") }
                if key.hasPrefix("bubble_"), emptyBubble.contains(frame) { issues.append("\(key) 第 \(i) 帧只有空白气泡底框") }
            }
        }

        for id in ResidentID.allCases {
            for newState in [ResidentState.sitting, .sleeping, .running] {
                let newKey = AssetCatalog.residentKey(id, newState)
                let newFrames = frames(newKey)
                for other in ResidentState.allCases where other != newState {
                    let otherKey = AssetCatalog.residentKey(id, other)
                    let otherFrames = Set(frames(otherKey))
                    if newFrames.contains(where: otherFrames.contains) {
                        issues.append("\(newKey) 与 \(otherKey) 有相同的帧")
                    }
                }
            }
        }

        if frames(AssetCatalog.lampOffKey) == frames(AssetCatalog.lampOnKey) {
            issues.append("Lamp 发光与不发光外观相同")
        }

        let bubbleKeys = BubbleIcon.allCases.map(AssetCatalog.bubbleKey)
        for (i, a) in bubbleKeys.enumerated() {
            for b in bubbleKeys[(i + 1)...] where frames(a) == frames(b) {
                issues.append("\(a) 与 \(b) 相同")
            }
        }
        return issues
    }

    /// 把 sheet 重绘到已知内存布局（RGBA、每像素 4 字节）的位图中，再按帧切成像素数据。
    private static func frameBytes(_ image: CGImage, frames: Int) -> [Data] {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, frames > 0 else { return [] }
        let frameRowBytes = bytesPerRow / frames
        return (0..<frames).map { index in
            var data = Data(capacity: frameRowBytes * height)
            for row in 0..<height {
                let start = row * bytesPerRow + index * frameRowBytes
                data.append(contentsOf: buffer[start..<(start + frameRowBytes)])
            }
            return data
        }
    }

    private static func hasVisiblePixel(_ frame: Data) -> Bool {
        stride(from: 3, to: frame.count, by: 4).contains { frame[$0] > 0 }
    }
}

extension AssetProvider {
    /// 占位图形可区分性自检的结果；空数组表示通过。见 `PlaceholderArt.selfCheckIssues()`。
    static func placeholderSelfCheckIssues() -> [String] { PlaceholderArt.selfCheckIssues() }
}
#endif
