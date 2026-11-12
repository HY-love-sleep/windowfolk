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
            draw(spec.key, frame: index, frames: spec.frames, size: CGSize(width: frameW, height: frameH), in: ctx)
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
    }

    private static func pose(_ state: ResidentState, frame: Int) -> Pose {
        var p = Pose()
        switch state {
        case .idle:
            // 呼吸：身体轻微起伏。
            p.bodyHeight = (frame % 2 == 0) ? 21 : 20
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

        ctx.setLineWidth(1.2)
        ctx.setStrokeColor(pal.stroke)

        // 脚
        ctx.setFillColor(pal.stroke)
        let footY = max(0, p.bodyY - 2)
        ctx.fillEllipse(in: CGRect(x: cx - 8, y: footY + p.leftFootLift, width: 5, height: 3))
        ctx.fillEllipse(in: CGRect(x: cx + 3, y: footY + p.rightFootLift, width: 5, height: 3))

        // 耳朵（画在身体后面）
        switch id {
        case .a: // 三角猫耳
            for side in [-1.0, 1.0] {
                let baseInner = cx + side * 3
                let baseOuter = cx + side * (p.bodyWidth / 2 - 1)
                let tip = CGPoint(x: cx + side * (p.bodyWidth / 2 - 2.5), y: min(31.5, top + 6))
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
                let center = CGPoint(x: cx + side * (p.bodyWidth / 2 - 4.5), y: min(28.5, top + 1))
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
                ctx.move(to: CGPoint(x: cx + dx, y: top - 1))
                ctx.addLine(to: CGPoint(x: cx + dx, y: top - 4))
            }
            ctx.strokePath()
        } else {
            // 嘟嘟：浅色肚皮
            ctx.setFillColor(rgb(1, 0.95, 0.82))
            ctx.fillEllipse(in: CGRect(x: cx - 6, y: body.minY + 1.5, width: 12, height: min(9, p.bodyHeight * 0.45)))
        }

        // 脸：默认朝右，五官稍偏右
        let faceX = cx + 1.5
        let eyeY = top - 8.5 + p.eyeLift
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)
        if p.happyEyes {
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

    private static func drawBubble(_ icon: BubbleIcon, size: CGSize, in ctx: CGContext) {
        // 白色圆形气泡，左下角一个小尾巴
        ctx.setFillColor(rgb(1, 1, 1, 0.96))
        ctx.setStrokeColor(rgb(0.55, 0.55, 0.58))
        ctx.setLineWidth(1)
        let circle = CGRect(x: 2, y: 3, width: size.width - 4, height: size.height - 4)
        ctx.addEllipse(in: circle)
        ctx.drawPath(using: .fillStroke)
        ctx.fillEllipse(in: CGRect(x: 3, y: 0.5, width: 3.5, height: 3.5))

        let c = CGPoint(x: circle.midX, y: circle.midY)
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
        }
    }
}
