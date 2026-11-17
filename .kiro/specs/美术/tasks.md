# Implementation Plan: 美术

## Overview

按设计新增三个 target：纯逻辑库 `WindowfolkArtKit`（只导入 Foundation 和 `WindowfolkCore`）、IO 库 `WindowfolkArtIO`（ImageIO、CoreGraphics、CoreText、网络）和可执行 `windowfolk-art`。实现语言为 Swift 6（SwiftPM，macOS 14+）。`WindowfolkCore`、`AssetProvider` 和 `build-app.sh` 不改动。

顺序：先搭 target 骨架，再自底向上实现纯逻辑（清单、提示词、生成计划、后处理、校验、布局），然后是 IO 层和命令行子命令，最后是仓库级测试和文档。每一步完成后 `swift build` 和 `swift test` 都应通过，已有的 605 个测试保持通过，整套测试不联网、不需要 API Key。

测试全部放在 `Tests/WindowfolkCoreTests/Art/`，共享的测试生成器放在 `Tests/WindowfolkCoreTests/Art/Support/`。属性测试使用已有依赖 `PropertyBased`，每个属性至少 100 次迭代，测试前加注释 `// Feature: 美术, Property N: <标题>`。

最后一组任务（第 14 组）需要项目所有者本机的 `OPENAI_API_KEY` 和人工挑图，代理无法完成，必须在第 1 至 13 组全部完成后由项目所有者手动执行。

## Tasks

- [x] 1. 搭建 target 骨架
  - [x] 1.1 在 `Package.swift` 增加 `WindowfolkArtKit`、`WindowfolkArtIO`、`windowfolk-art` 三个 target，并更新 `.gitignore`
    - `.target(name: "WindowfolkArtKit", dependencies: ["WindowfolkCore"])`、`.target(name: "WindowfolkArtIO", dependencies: ["WindowfolkArtKit"])`、`.executableTarget(name: "windowfolk-art", dependencies: ["WindowfolkArtKit", "WindowfolkArtIO"])`
    - `WindowfolkCoreTests` 的 dependencies 追加 `"WindowfolkArtKit"`、`"WindowfolkArtIO"`；不新增第三方包
    - 建立占位源文件：`Sources/WindowfolkArtKit/ArtKit.swift`、`Sources/WindowfolkArtIO/ArtIO.swift`、`Sources/windowfolk-art/main.swift`（暂时只打印用法并以退出码 64 结束）
    - `.gitignore` 增加 `art/work/`
    - 建立 `art/character_sheets/` 目录（放一个 `.gitkeep`）
    - _Requirements: 5.7, 9.6, 9.8_

  - [x] 1.2 编写架构与快照测试 `Tests/WindowfolkCoreTests/Art/ArtArchitectureTests.swift`
    - 扫描 `Sources/WindowfolkArtKit/`，要求只导入 Foundation 和 WindowfolkCore；扫描 `WindowfolkArtKit`、`WindowfolkArtIO`、`windowfolk-art`，要求不导入 AppKit 和 SpriteKit
    - 快照：`AssetCatalog.all` 的 45 个键、每帧 pt 尺寸、帧数、平铺方式与本 spec 开始前一致
    - 检查 `Package.swift` 中三个流水线 target 只依赖仓库内 target
    - 检查 `.gitignore` 含 `art/work/`
    - _Requirements: 5.7, 9.5, 9.6, 9.8_

- [x] 2. 素材分类、清单模型、解析与格式化、提示词组合
  - [x] 2.1 实现 `Sources/WindowfolkArtKit/AssetRules.swift`
    - `ResidentOwner`、`AlignmentMode`（`groundedPerFrame`、`anchoredBase`、`nonGroundedUniform`、`centeredBottom`、`tile`）、`AssetRules.rules(for:)`
    - 按设计表格推导 owner、isGrounded、isFramed、alignment、palettes：`fruit`、全部 `bubble_*`、`decor_chair`、`visit_flag`、`toolbox` 为 `centeredBottom`；`flower_*`、`decor_lamp_*` 为 `anchoredBase`；`plank`、`ladder` 为 `tile`
    - `PaletteGroup` 也在此文件或 2.2 中定义，保持只有一处定义
    - _Requirements: 4.5, 4.8, 4.9, 4.14, 4.15, 6.3, 6.4_

  - [x] 2.2 实现清单数据模型 `Sources/WindowfolkArtKit/ManifestModel.swift`
    - `PaletteGroup`、`PaletteColorName`、`RGB`（`#RRGGBB` 解析，大小写不敏感；输出大写）、`PixelSize`、`FrameLayout`、`PromptEntry`、`PromptManifest`、`ManifestIssue`（含 `Location`）
    - 每组 Palette 的必需颜色：两组居民 5 色，`wood`、`plant` 4 色
    - _Requirements: 1.2, 2.2_

  - [x] 2.3 实现 `Sources/WindowfolkArtKit/ManifestPrinter.swift`
    - `JSONEncoder` 选项 `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`，结尾补换行；`prefix` 按 `\n` 切成数组；`canvas` 写成 `WxH`；条目按 `AssetCatalog.all` 顺序；`version: 1`
    - _Requirements: 2.10_

  - [x] 2.4 实现 `Sources/WindowfolkArtKit/ManifestParser.swift`
    - `parse(_:fileExists:) -> Result<PromptManifest, [ManifestIssue]>`
    - JSON 语法错误由 `NSJSONSerializationErrorIndex` 换算行号
    - 收集全部问题后再返回：prefix 为空；Palette 缺组、缺色、色值格式错（定位到组名和颜色名）；条目缺失、重复、未知键；描述长度不在 1 到 1000；帧数与 Asset_Catalog 不等；layout 不是 `horizontal_no_gap`；画布不是两个正整数；参考图不存在；居民条目未列出本人设定图或列出另一位的设定图；非居民条目列出任一设定图（定位到 Asset_Key 和字段名）
    - 路径比较前做 `standardizingPath`；条目按 Asset_Catalog 顺序重排
    - _Requirements: 1.6, 2.1, 2.2, 2.4, 2.6, 2.8, 2.9, 2.13_

  - [x] 2.5 编写清单生成器 `Art/Support/ManifestGen.swift` 和属性测试 `Art/ManifestRoundTripTests.swift`
    - `Gen.manifest`：45 条，描述随机含引号、方括号、换行和中文，随机画布与色值，居民条目引用本人设定图
    - **Property 1: 清单往返与稳定格式化**
    - **Validates: Requirements 1.2, 2.8, 2.10, 2.11**

  - [x] 2.6 编写属性测试 `Art/ManifestRejectionTests.swift`
    - **Property 2: 非法清单被拒绝并定位**
    - **Validates: Requirements 1.6, 2.1, 2.2, 2.4, 2.6, 2.9, 2.13**

  - [x] 2.7 实现 `Sources/WindowfolkArtKit/PromptComposer.swift`
    - 输出 `prefix` + 空行 + 每个适用 Palette 一行（组顺序按 `PaletteGroup.allCases`，色名顺序按 `PaletteColorName.allCases`）+ 空行 + `description`；无适用 Palette 时省略中间段
    - _Requirements: 2.12_

  - [x] 2.8 编写属性测试 `Art/PromptComposerTests.swift`
    - **Property 3: 提示词组合确定且有序**
    - **Validates: Requirements 2.12**

  - [x] 2.9 编写 `AssetRules` 单元测试 `Art/AssetRulesTests.swift`
    - 45 个键都有规则；Grounded_State 恰为 5 个状态 × 2 位居民；Framed_Asset 不含 `plank`、`ladder`、`toolbox`；`fruit` 与 10 个气泡为 `centeredBottom`
    - _Requirements: 4.5, 6.3, 6.4_

- [x] 3. 编写提示词清单
  - [x] 3.1 编写 `art/prompt-manifest.json`
    - 公共前缀逐项写明 R1.3 的 10 点（柔和手绘 Q 版、约 2px 深色描边、平涂加一层阴影、柔和粉彩、透明背景、居民朝右、脚底贴住底边、水平居中、无文字、无地面阴影和背景）
    - 四组 Palette 使用设计「Palette 初始色值」表中的值
    - 45 条条目：描述覆盖 `docs/art-spec.md` 第 4 节（居民）或第 5 节（其他素材）对应行，写明帧数与水平无间隔排列；居民描述写入眼睛颜色；两位居民的 `carrying` 写明不画被抱物件、`climbing` 写明不画梯子、`sitting` 写明不画椅子；画布按设计「生成画布尺寸」表
    - 居民条目只引用本人的 `art/character_sheets/resident_<a|b>.png`，其他条目参考图为空
    - 用 `ManifestPrinter` 输出的格式写（排序键、大写色值），使文件与 `print(parse(file))` 逐字节相同
    - _Requirements: 1.2, 1.3, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.13_

  - [x] 3.2 编写仓库清单测试 `Art/RepositoryManifestTests.swift`
    - 解析通过：两张设定图都存在时用真实 `fileExists`；尚不存在时把两张设定图路径视为存在，并在测试输出中注明
    - 45 条；前缀包含 R1.3 的 10 点关键词；6 条居民描述含「不画物件、梯子、椅子」的说明
    - 每个画布满足 R2.5（每帧不小于目标像素）和 API 约束（16 的倍数、宽高比 1:3 到 3:1、总像素 655,360 到 8,294,400）
    - 文件内容与 `ManifestPrinter.print(parse(file))` 逐字节相同
    - _Requirements: 1.3, 2.1, 2.5, 2.7, 2.8_

- [x] 4. Checkpoint - 确认清单相关测试全部通过
  - Ensure all tests pass, ask the user if questions arise.

- [x] 5. 生成计划、请求构造与脱敏（纯逻辑）
  - [x] 5.1 实现 `Sources/WindowfolkArtKit/GenerationPlanner.swift`
    - `GenerationJob`、`GenerationPlanner.plan(manifest:requested:count:existingPNGs:)`：请求键非空时每键 `count` 个任务；为空时只为没有 PNG 的键安排；序号从已有最大 `raw_<n>` 加 1 起连续；未知键与 `count` 不在 1 到 8 时返回错误列表
    - `ModelName.fallback = "gpt-image-2.5-flare"`、`ModelName.resolve(_:)`（去空白后为空则用 fallback）
    - _Requirements: 3.1, 3.2, 3.3, 3.5, 3.8_

  - [x] 5.2 编写属性测试 `Art/GenerationPlannerTests.swift`
    - **Property 4: 生成计划只补缺且序号不冲突**
    - **Validates: Requirements 3.1, 3.2, 3.5**

  - [x] 5.3 实现 `Sources/WindowfolkArtKit/RequestBuilder.swift`
    - `ImageRequest`（endpoint、model、prompt、size、references；固定 `background=transparent`、`output_format=png`、`n=1`、`quality=high`）
    - `GenerationFailure`（`http`、`modelUnavailable`、`unauthorized`、`timeout`、`undecodable`、`transport`）定义在本库，供 IO 层复用
    - `request(for:prompt:model:)`：有参考图用 edits，否则 generations；`body(_:referenceData:boundary:)`：generations 为 JSON，edits 为 multipart，每张参考图一个 `image[]` 部分；`decodeResponse(_:)` 取 `data[0].b64_json`，并把 404 / `model_not_found`、401 映射到对应失败
    - _Requirements: 3.1, 3.3, 3.4, 3.7_

  - [x] 5.4 编写属性测试 `Art/RequestBuilderTests.swift`
    - **Property 5: 请求内容完整**
    - **Validates: Requirements 3.1, 3.3, 3.4**

  - [x] 5.5 实现 `Sources/WindowfolkArtKit/Redactor.swift`
    - 替换完整 Key、Key 的任一长度 ≥ 6 的连续片段和形如 `sk-…` 的令牌为 `[REDACTED]`
    - _Requirements: 3.10_

  - [x] 5.6 编写属性测试 `Art/RedactorTests.swift`（纯函数部分）
    - **Property 7: Key 不泄露**
    - **Validates: Requirements 3.10**

- [x] 6. RGBA 缓冲区与后处理（纯逻辑）
  - [x] 6.1 实现 `Sources/WindowfolkArtKit/RGBAImage.swift`
    - `RGBA`、`PixelRect`、`PixelPoint`、`RGBAImage`（非预乘、行优先；下标、`crop`、`opaqueBounds(threshold: 128)`、粘贴与平移）
    - `Resampler` 协议
    - 切帧函数：`q = W / N`，最后一帧到 `W` 为止
    - _Requirements: 4.2, 4.4_

  - [x] 6.2 编写图像测试支撑 `Art/Support/ImageGen.swift`、`Art/Support/NearestResampler.swift` 和属性测试 `Art/FrameSlicingTests.swift`
    - `Gen.rawImage(key)`：纯色或透明背景上每帧一个随机实心圆角矩形，颜色与背景至少一通道相差 > 24，整体尺寸不等于 Expected_Pixel_Size，每帧 ≤ 96×96
    - **Property 8: 切帧覆盖全宽且不重叠**
    - **Validates: Requirements 4.2**

  - [x] 6.3 实现 `Sources/WindowfolkArtKit/BackgroundRemover.swift`
    - 四角 alpha > 0 的像素取平均 RGB；从四边出发 4 邻域洪泛，可通过 alpha = 0 或每通道差 ≤ 24 的像素；被洪泛像素设为 `(0,0,0,0)`；无此类角时原样返回
    - _Requirements: 4.3_

  - [x] 6.4 编写属性测试 `Art/BackgroundRemoverTests.swift`
    - **Property 9: 去背景只移除与边缘相连的背景**
    - **Validates: Requirements 4.3**

  - [x] 6.5 实现 `Sources/WindowfolkArtKit/PostProcessor.swift`
    - `ProcessContext`、`ProcessOutcome`、`PostProcessError`（`unknownKey`、`emptyFrame(index:)`、`tileSeam`）
    - 按设计「后处理算法」第 1 至 10 步：规格尺寸输入跳过去背景与缩放只做平移；共用缩放比例；`nonGroundedUniform` 用帧并集；R4.7 按 idle 高度调整并在超出 10% 时写 warnings；按 alignment 放置（整体边界框、最下 4 行锚点、平铺居中、并集统一平移）；Framed_Asset 四角清理；`plank` / `ladder` 接缝平均并复查阈值；拼接
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9, 4.10, 4.11, 4.12, 4.13, 4.14, 4.15_

  - [x] 6.6 编写属性测试 `Art/PostProcessorSpecTests.swift`
    - **Property 10: 输出符合素材规格**
    - **Validates: Requirements 4.1, 6.12**

  - [x] 6.7 编写属性测试 `Art/PostProcessorScaleTests.swift`
    - **Property 11: 所有帧共用最大适配比例**
    - **Validates: Requirements 4.4, 4.6**

  - [x] 6.8 编写属性测试 `Art/PostProcessorAlignmentTests.swift`
    - **Property 12: 锚点对齐与四角透明**
    - **Validates: Requirements 4.5, 4.8, 4.9, 4.14**

  - [x] 6.9 编写属性测试 `Art/PostProcessorIdleHeightTests.swift`
    - **Property 13: 与 idle 高度一致**
    - **Validates: Requirements 4.7**

  - [x] 6.10 编写属性测试 `Art/PostProcessorNonGroundedTests.swift`
    - **Property 14: 非 Grounded 居民保留帧间位移**
    - **Validates: Requirements 4.15**

  - [x] 6.11 编写属性测试 `Art/PostProcessorTileTests.swift`
    - **Property 15: 平铺边缘无缝**
    - **Validates: Requirements 4.10, 4.11**

  - [x] 6.12 编写属性测试 `Art/PostProcessorIdempotenceTests.swift`
    - **Property 16: 后处理幂等**
    - **Validates: Requirements 4.3, 4.13**

- [x] 7. 素材校验（纯逻辑）
  - [x] 7.1 实现 `Sources/WindowfolkArtKit/AssetValidator.swift`
    - `ValidationRule`（9 个中文规则名）、`DecodedPNG`、`AssetVerdict`、`AssetValidator.validate(key:decoded:)`
    - 文件格式 → 像素尺寸（调用 `AssetCatalog.validation(fileName:pixelWidth:pixelHeight:)`）→ alpha 通道；前两项失败时不做帧级检查
    - 帧级：四角透明（Framed_Asset）、贴底 ≤ 2 与水平居中 ≤ 6（Grounded 居民）、空帧（记录序号）、帧内容相同（帧数 > 1）、平铺边缘（`plank` 左右列、`ladder` 上下行）；全部规则独立计算，按 `allCases` 顺序列出
    - _Requirements: 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.10_

  - [x] 7.2 编写属性测试 `Art/AssetValidatorDefectTests.swift`
    - **Property 18: 校验器恰好报告注入的缺陷**
    - **Validates: Requirements 6.2, 6.3, 6.4, 6.5, 6.6, 6.7**

  - [x] 7.3 编写属性测试 `Art/AssetValidatorSizeTests.swift`
    - **Property 19: 尺寸结论与 AssetCatalog 一致**
    - **Validates: Requirements 6.10**

  - [x] 7.4 实现 `Sources/WindowfolkArtKit/ValidationReport.swift`
    - `AssetValidator.report(directoryListing:verdicts:)`：按 Asset_Catalog 顺序 45 行（通过 / 缺失 / 未通过：规则列表，空帧附序号）；未知 `.png` 文件在后面列为「未知文件」；`allPassed` 只看 45 个键
    - _Requirements: 6.1, 6.8, 6.9_

  - [x] 7.5 编写属性测试 `Art/ValidationReportTests.swift`
    - **Property 20: 目录报告**
    - **Validates: Requirements 6.1, 6.8, 6.9**

- [x] 8. 预览与设定图布局（纯逻辑）
  - [x] 8.1 实现 `Sources/WindowfolkArtKit/PreviewLayout.swift`
    - 行按 Asset_Catalog 顺序；左侧标签区（高度 ≥ 10，不与帧相交）；帧间隔 ≥ 4；居民键有比例 2 与比例 1 两条，其余只有比例 2；为缺失或不合规的键给出 Expected_Pixel_Size 大小的标记矩形与标记文字
    - _Requirements: 7.3, 7.4, 7.5_

  - [x] 8.2 编写属性测试 `Art/PreviewLayoutTests.swift`
    - **Property 22: 预览布局**
    - **Validates: Requirements 7.3, 7.4, 7.5**

  - [x] 8.3 实现 `Sources/WindowfolkArtKit/SheetLayout.swift` 和 `Sources/WindowfolkArtKit/CharacterSheetPrompts.swift`
    - `SheetLayout`：1536×720 画布，三个 512×640 视图格，视图缩放到边界框高 560 并贴格底居中；5 个 48×48 色块，`x = 16 + i·64`、`y = 656`，按 main、shadow、highlight、outline、blush 顺序直接填色
    - `CharacterSheetPrompts`：两位居民的设定图提示词，内容取自 `docs/art-spec.md` 第 1 节，组合公共前缀和该居民 Palette
    - _Requirements: 1.1, 1.4, 1.5_

  - [x] 8.4 编写属性测试 `Art/SheetLayoutTests.swift`
    - **Property 23: 设定图色块与视图**
    - **Validates: Requirements 1.1, 1.5**

- [x] 9. Checkpoint - 确认纯逻辑层测试全部通过
  - Ensure all tests pass, ask the user if questions arise.

- [x] 10. IO 层（WindowfolkArtIO）
  - [x] 10.1 实现 `Sources/WindowfolkArtIO/PNGCodec.swift` 和 `Sources/WindowfolkArtIO/CGResampler.swift`
    - `decode`：要求类型为 `public.png`，`hasAlpha` 取自 `alphaInfo`，画进 sRGB `premultipliedLast` 上下文后反预乘
    - `encode`：非预乘 8 位 RGBA PNG（`CGImageDestination`）
    - `CGResampler`：预乘 → `interpolationQuality = .high` 绘制 → 反预乘
    - _Requirements: 4.1, 4.4, 6.2_

  - [x] 10.2 编写单元测试 `Art/PNGCodecTests.swift`
    - 编码后解码像素逐一相同（alpha 为 0 和 255 的像素）；无 alpha 的 PNG `hasAlpha == false`；非 PNG 数据解码为 nil；`CGResampler` 输出尺寸正确
    - _Requirements: 4.1, 6.2_

  - [x] 10.3 实现 `Sources/WindowfolkArtIO/FileStore.swift`
    - 目录列举、`raw_<n>` / `processed_<n>` 序号扫描、新文件写入（`.atomic`、`.withoutOverwriting`）、覆盖写入（`.atomic`）、备份复制到 `art/work/backups/<key>-<yyyyMMdd-HHmmss>-<n>.png`
    - 以协议形式提供，便于测试注入写入失败
    - _Requirements: 3.5, 4.1, 5.2, 5.4, 5.6_

  - [x] 10.4 实现 `Sources/WindowfolkArtIO/ImageTransport.swift` 和 `Sources/WindowfolkArtIO/URLSessionTransport.swift`
    - `ImageTransport` 协议；`URLSessionTransport` 使用 `ephemeral` 配置，请求与资源超时都为 180 秒；Key 只放进 `Authorization: Bearer` 头；服务器错误只取 `error.message` 并经 `Redactor` 处理
    - _Requirements: 3.1, 3.7, 3.10_

  - [x] 10.5 实现 `Sources/WindowfolkArtIO/PreviewRenderer.swift`
    - 深色背景每通道 ≤ 48、浅色背景每通道 ≥ 208 的纯色；2 倍条用 `.none` 插值、1 倍条用 `.high`；CoreText 12pt 系统字体写 Asset_Key 与「缺失」或规则名标记
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5_

- [x] 11. 命令行子命令
  - [x] 11.1 实现命令行基础 `Sources/WindowfolkArtIO/Commands/CommandSupport.swift`、`Sources/WindowfolkArtIO/Commands/CommandRouter.swift` 和 `Sources/windowfolk-art/main.swift`
    - 子命令实现放在 `WindowfolkArtIO/Commands/`，使测试可以直接调用；`main.swift` 只把 `CommandRouter.run(arguments:environment:)` 返回的 `ExitStatus` 转成进程退出码
    - `ExitStatus`（0、1、64）；手工参数解析；仓库根目录检查（当前目录含 `Package.swift` 和 `art/`，否则 64）；输出通道统一经过 `Redactor`
    - 未知子命令与缺参数返回 64 并打印用法
    - _Requirements: 3.10, 9.6, 9.7_

  - [x] 11.2 实现 `generate` 子命令 `Commands/GenerateCommand.swift` 并接入 `CommandRouter`
    - 预检顺序：清单解析、`--count`（非法为 64）、未知键、参考图存在、`OPENAI_API_KEY` 非空白；任一失败都不发请求
    - `--dry-run`：逐个打印 Asset_Key、模型名、完整提示词、参考图路径、画布尺寸，不写文件，退出码 0
    - 无待生成素材时打印说明，退出码 0
    - 顺序发送 `n=1` 请求；进度行 `[i/总数] 发送 <key> #<n>` 与 `[i/总数] 完成 <key> #<n>`；成功写 `art/work/<key>/raw_<n>.png`；失败不写文件、记录原因并继续；模型不可用或 401 时剩余请求记为同一原因的失败
    - 全部成功时每键一行列出新路径，退出码 0；有失败时按 `<key>  成功 <n> 张  失败原因：<reason>` 报告，退出码 1
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13_

  - [x] 11.3 编写 `Art/Support/FakeTransport.swift` 和属性测试 `Art/GenerateFailureIsolationTests.swift`
    - 在临时目录中运行，`FakeTransport` 按脚本返回成功、HTTP 错误、不可解码或超时
    - **Property 6: 请求失败互不影响**
    - **Validates: Requirements 3.7, 3.11, 3.13**

  - [x] 11.4 编写单元测试 `Art/GenerateCommandTests.swift`
    - 无 Key 或 Key 为空白时 FakeTransport 调用次数为 0 且退出码非零（R3.6）；未知键、参考图缺失、`--count` 为 0 或 9 时不发请求（R3.8）；试运行打印每个请求且不写文件（R3.9）；进度行格式（R3.12）；模型不可用时的提示
    - 端到端：FakeTransport 的错误信息回显 Key 时，标准输出、标准错误和写出的文件不含 Key 的任何长度 ≥ 6 的片段（Property 7 的端到端部分）
    - _Requirements: 3.2, 3.6, 3.8, 3.9, 3.10, 3.12_

  - [x] 11.5 实现 `process` 子命令 `Commands/ProcessCommand.swift` 并接入 `CommandRouter`
    - 读原始图（无法解码时报错）；读 `Assets/resident_<a|b>_idle.png` 第 1 帧边界框高度构造 `ProcessContext`；调用 `PostProcessor.process`（`CGResampler`）
    - 成功写 `art/work/<key>/processed_<n>.png`（不覆盖），打印路径和警告，退出码 0；失败打印 Asset_Key、文件路径、原因（空帧带序号），不写文件，退出码 1
    - _Requirements: 4.1, 4.7, 4.12_

  - [x] 11.6 编写属性测试 `Art/ProcessCommandEmptyFrameTests.swift`
    - **Property 17: 空帧报错且不写文件**
    - **Validates: Requirements 4.12**

  - [x] 11.7 实现 `promote` 子命令 `Commands/PromoteCommand.swift` 并接入 `CommandRouter`
    - 键未知、候选不存在或不可读时在校验前退出码 1
    - 以指定键校验；不合规时逐条列出规则，`Assets/` 不变，退出码 1
    - 合规时：必要时创建 `Assets/`；已有同名文件先备份（备份失败则不写入）；原子写入与候选逐字节相同的文件；打印键和路径，退出码 0；写入失败时打印步骤与原因，原文件保持完整
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_

  - [x] 11.8 编写属性测试 `Art/PromoteCommandTests.swift`
    - **Property 21: Promotion 只写通过校验的图**
    - **Validates: Requirements 5.1, 5.2, 5.3, 5.4**
    - 另加单元测试：未知键与缺失候选（R5.5）；注入备份失败和写入失败的 `FileStore` 时原文件完整、不留部分文件（R5.6）

  - [x] 11.9 实现 `validate` 子命令 `Commands/ValidateCommand.swift` 并接入 `CommandRouter`
    - 默认目录 `Assets`；目录不存在或不可读时只打印路径，退出码 1；否则用 `PNGCodec` 与 `AssetValidator` 生成报告，打印 45 行与未知文件，按 `allPassed` 决定退出码
    - _Requirements: 6.1, 6.8, 6.9, 6.13_

  - [x] 11.10 编写单元测试 `Art/ValidateCommandTests.swift`
    - 目录不存在时无逐项输出且退出码非零（R6.13）；临时目录放入合规、不合规和未知文件时输出与退出码正确
    - _Requirements: 6.1, 6.8, 6.9, 6.13_

  - [x] 11.11 实现 `preview` 子命令 `Commands/PreviewCommand.swift` 并接入 `CommandRouter`
    - 默认目录 `Assets`；目录不存在或不可读时不写图，退出码 1；否则校验每个键、按 `PreviewLayout` 用 `PreviewRenderer` 写 `art/work/preview/preview_dark.png` 与 `preview_light.png`（覆盖旧图），打印两条路径和正常、缺失、不合规的数量与名单，退出码 0；不改动被检查目录
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7_

  - [x] 11.12 编写单元测试 `Art/PreviewCommandTests.swift`
    - 两张图背景采样点颜色在阈值内且一致（R7.2）；缺失项有标记；汇总输出（R7.6）；目录不存在时不写图（R7.7）；被检查目录内容不变（R7.1）
    - _Requirements: 7.1, 7.2, 7.6, 7.7_

  - [x] 11.13 实现 `sheet generate` 与 `sheet compose` 子命令 `Commands/SheetCommand.swift` 并接入 `CommandRouter`
    - 解析清单时把两张设定图路径视为存在，只取前缀与 Palette
    - `sheet generate <resident> [--count N] [--dry-run]`：用 `CharacterSheetPrompts` 调用 generations，画布 1536×1024，输出 `art/work/sheets/<resident>/raw_<n>.png`；Key 检查、进度、脱敏与 `generate` 相同
    - `sheet compose <resident> <raw.png>`：三等分、去背景、按 `SheetLayout` 排版，写 `art/character_sheets/<resident>.png`
    - _Requirements: 1.1, 1.4, 1.5_

  - [x] 11.14 编写单元测试 `Art/SheetCommandTests.swift`
    - `sheet generate --dry-run` 不写文件且不发请求；`sheet compose` 对合成三视图输出的色块中心像素等于 Palette、视图高度 ≥ 256（临时目录中运行）
    - _Requirements: 1.1, 1.5_

- [x] 12. 仓库级测试与文档
  - [x] 12.1 实现仓库素材测试 `Tests/WindowfolkCoreTests/Art/RepositoryAssetsTests.swift`
    - 从 `#filePath` 向上找到仓库根目录读 `Assets/`
    - 没有任何对应 Asset_Key 的 PNG 时用 `.enabled(if:)` 标记跳过，原因「Assets/ 中尚无 Final_Asset」
    - 对每个存在的键调用 `PNGCodec.decode` 与 `AssetValidator.validate`，不合规时 `Issue.record("<key>: <规则名称…>")`
    - 有 1 到 44 个时打印缺失数量与名单，不记录 Issue
    - 45 个都存在时另外检查 R8.6、R8.8、R8.9、R8.10 中可计算的几何条件
    - _Requirements: 6.11, 6.14, 6.15, 8.6, 8.8, 8.9, 8.10_

  - [x] 12.2 更新 `docs/art-spec.md`，增加「出图流水线」一节
    - 按顺序列出：设置 `OPENAI_API_KEY`（可选 `WINDOWFOLK_IMAGE_MODEL`）、`generate`、`process`、`preview`、`promote`、`validate`，每步给出完整命令
    - 写出制作设定图的 `sheet generate` / `sheet compose` 用法
    - 写出 `art/character_sheets/resident_a.png`、`art/character_sheets/resident_b.png`、`art/prompt-manifest.json` 的路径，并列出四组 Palette 色值（与清单一致）
    - _Requirements: 1.7_

  - [x] 12.3 编写文档测试 `Art/ArtSpecDocTests.swift`
    - 新增一节中的步骤顺序正确；列出的色值与 `art/prompt-manifest.json` 相等；`art/prompt-manifest.json` 必须存在，两张设定图路径在文件存在前记录为跳过的检查，存在后必须存在
    - _Requirements: 1.7_

  - [x] 12.4 编写设定图测试 `Art/CharacterSheetTests.swift`
    - 两张设定图都不存在时跳过；存在时检查带 alpha 的 PNG、色块中心像素与 Palette 完全相等、三个视图不透明边界框高度 ≥ 256
    - _Requirements: 1.1, 1.5_

- [x] 13. Final checkpoint - 确认代码部分全部完成
  - 运行 `swift build` 和 `swift test`，确认已有 605 个测试和新测试全部通过（`Assets/` 为空时仓库素材测试显示为跳过），整个过程不联网、不需要 Key。
  - 运行 `swift run windowfolk-art generate --dry-run` 和 `swift run windowfolk-art validate`，确认输出格式正确（此时 `validate` 报 45 项缺失、退出码非零属正常）。
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 14. 【手动 · 需要 OPENAI_API_KEY】项目所有者本机出图与验收
  - 本组任务需要项目所有者的 API Key 和人工判断，代理不执行。必须在第 1 至 13 组完成后进行。
  - [ ] 14.1 【手动】制作两张角色设定图
    - `export OPENAI_API_KEY=…`，运行 `swift run windowfolk-art sheet generate resident_a --count 3`，挑一张后运行 `sheet compose resident_a art/work/sheets/resident_a/raw_<n>.png`；对 `resident_b` 重复
    - 按 R1.4 清单逐项确认，不符合则重新生成
    - 运行 `swift test`，确认设定图测试、仓库清单测试（此时用真实文件检查参考图）和文档测试通过
    - _Requirements: 1.1, 1.4, 1.5_

  - [ ] 14.2 【手动】核对提示词清单
    - 对 45 个 Asset_Key 逐条核对描述是否覆盖 `docs/art-spec.md` 第 4、5 节，记录结果；需要修改时编辑 `art/prompt-manifest.json` 后重新运行 `swift test`
    - _Requirements: 2.3_

  - [ ] 14.3 【手动】批量生成原始图
    - 先运行 `swift run windowfolk-art generate --dry-run` 检查请求，再运行 `swift run windowfolk-art generate --count 2`；对失败的 Asset_Key 单独重跑
    - _Requirements: 3.1, 3.2, 3.7_

  - [ ] 14.4 【手动】后处理与挑图
    - 先处理并 Promotion 两位居民的 `idle`，使其余 Grounded_State 能按 idle 高度缩放；再对其余 Raw_Candidate 运行 `process`
    - 用 `swift run windowfolk-art preview art/work/<key>` 或对 `Assets` 运行 `preview` 查看深色与浅色总览图
    - _Requirements: 4.1, 4.7, 7.1_

  - [ ] 14.5 【手动】Promotion 全部 45 张
    - 对每个 Asset_Key 运行 `swift run windowfolk-art promote <key> art/work/<key>/processed_<n>.png`；未通过时重新生成或处理
    - _Requirements: 5.1, 5.2, 5.3_

  - [ ] 14.6 【手动】校验与目视验收
    - 运行 `swift run windowfolk-art validate`，要求 45 行全部「通过」、无未知文件、退出码 0；运行 `swift test`，仓库素材测试应通过且不再跳过
    - 运行 `preview`，在两张总览图上逐项检查 R8.2 至 R8.5、R8.7、R8.11，不通过的素材回到 14.3
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.7, 8.11_

  - [ ] 14.7 【手动】应用内确认并提交
    - 在仓库根目录、`WINDOWFOLK_ASSETS` 未设置时运行 `swift run Windowfolk`，日志应有一条「素材目录 <仓库根目录>/Assets：加载 45 / 45 项 PNG」，且无占位图形相关记录
    - 运行 `build-app.sh`，确认输出「已复制 45 个 PNG」；`open Windowfolk.app` 后日志应有对应的「加载 45 / 45 项 PNG」
    - 提交 `Assets/` 下 45 个 PNG 和 `art/character_sheets/` 下两张设定图；确认 `art/work/` 未进入版本控制
    - _Requirements: 8.1, 9.1, 9.2, 9.3, 9.4_

## Notes

- 标 `*` 的子任务是测试任务，可跳过以加快进度；未标 `*` 的任务（包括 12.1 仓库素材测试）必须完成。
- 第 14 组是项目所有者的手动任务，需要 `OPENAI_API_KEY`、网络和人工判断。代理执行任务时遇到第 14 组应停止并提醒项目所有者。
- 子命令实现放在 `Sources/WindowfolkArtIO/Commands/`，`windowfolk-art/main.swift` 只做转发。这是对设计「CLI 负责参数解析和子命令」的细化，目的是让测试直接调用子命令；依赖方向和「WindowfolkArtKit 只导入 Foundation」的约束不变。
- `GenerationFailure` 定义在 `WindowfolkArtKit`，因为 `RequestBuilder.decodeResponse` 需要返回它；IO 层复用同一类型。
- 两张设定图在第 14.1 步之前不存在，因此仓库清单测试和文档测试在设定图缺失时把这两条路径视为存在并注明，设定图测试则跳过。设定图生成后这些测试自动转为严格检查。
- 属性测试的合成图每帧不超过 96×96 像素；需要高质量缩放时用 `CGResampler`，其余用测试内的 `NearestResampler`。

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2", "2.1", "2.2", "5.5", "6.1"] },
    { "id": 2, "tasks": ["2.3", "2.4", "2.9", "5.6", "6.3", "7.1", "8.1"] },
    { "id": 3, "tasks": ["2.5", "2.6", "2.7", "3.1", "6.2", "6.5", "7.4", "8.3"] },
    { "id": 4, "tasks": ["2.8", "3.2", "5.1", "5.3", "6.4", "7.2", "7.3", "7.5", "8.2", "8.4", "10.1", "10.3"] },
    { "id": 5, "tasks": ["5.2", "5.4", "6.6", "6.7", "6.8", "6.9", "6.10", "6.11", "6.12", "10.2", "10.4", "10.5"] },
    { "id": 6, "tasks": ["11.1"] },
    { "id": 7, "tasks": ["11.2"] },
    { "id": 8, "tasks": ["11.3", "11.5"] },
    { "id": 9, "tasks": ["11.4", "11.6", "11.7"] },
    { "id": 10, "tasks": ["11.8", "11.9"] },
    { "id": 11, "tasks": ["11.10", "11.11"] },
    { "id": 12, "tasks": ["11.12", "11.13"] },
    { "id": 13, "tasks": ["11.14", "12.1", "12.2"] },
    { "id": 14, "tasks": ["12.3", "12.4"] },
    { "id": 15, "tasks": ["14.1"] },
    { "id": 16, "tasks": ["14.2"] },
    { "id": 17, "tasks": ["14.3"] },
    { "id": 18, "tasks": ["14.4"] },
    { "id": 19, "tasks": ["14.5"] },
    { "id": 20, "tasks": ["14.6"] },
    { "id": 21, "tasks": ["14.7"] }
  ]
}
```
