# Implementation Plan: 窗间 · Windowfolk v1「送花过桥」

## Overview

按 `docs/plan-v1.md` 的顺序逐步实现，模块划分与接口以 `design.md` 为准：先搭工程骨架和透明覆盖层，再依次做窗口读取与路面、居民跟随与掉落、鼠标与木板、通路图、梯子、物件搬运、剧情、事件记录、存档，最后处理边界情况、素材规格、打包和演示脚本。

实现语言为 Swift 6（语言模式 6，严格并发），用 SwiftPM 构建，最低 macOS 14。测试使用 Swift Testing，属性测试使用 swift-property-based（`import PropertyBased`，`propertyCheck(count: 100, ...)`）。每个属性测试函数上方加注释 `// Feature: v1, Property {编号}: {属性标题}`。

约定：

- Core 源文件放在 `Sources/WindowfolkCore/`，应用层放在 `Sources/Windowfolk/`，测试放在 `Tests/WindowfolkCoreTests/`。各任务列出的文件名是建议，便于并行执行时避免冲突。
- `WindowfolkCore` 只导入 Foundation。文件读写类（`FileEventSink`、`FileSaveStore`）只用 Foundation，放在 Core 中以便用临时目录测试（Requirement 27.6）；应用层只负责默认目录、后台队列和调用时机。
- 每个任务结束时 `swift build` 必须通过；带测试的任务结束时 `swift test` 必须通过。

## Tasks

- [x] 1. 搭建工程骨架与透明覆盖层
  - [x] 1.1 创建 SwiftPM 工程
    - 按 design.md 编写 `Package.swift`：`WindowfolkCore`（库）、`Windowfolk`（可执行）、`WindowfolkCoreTests`（测试，依赖 swift-property-based `from: "2.0.0"` 的 `PropertyBased` 产品），`platforms: [.macOS(.v14)]`，Swift 语言模式 6
    - 创建 `Sources/WindowfolkCore/WindowfolkCore.swift` 占位文件、`Sources/Windowfolk/main.swift` 最小入口、`Tests/WindowfolkCoreTests/SmokeTests.swift` 一个 Swift Testing 占位测试
    - 确认 `swift build` 与 `swift test` 以退出码 0 完成
    - _Requirements: 1.11, 27.1, 27.8, 27.9_

  - [x] 1.2 实现应用外壳与菜单栏菜单
    - `Sources/Windowfolk/AppDelegate.swift`：`NSApp.setActivationPolicy(.accessory)`，无 Dock 图标、不进 Command-Tab
    - `Sources/Windowfolk/StatusMenu.swift`：`NSStatusItem` 菜单依次为「显示路面」开关（默认关闭，打开时显示勾选）、「调试」子菜单（先为空）、「退出」
    - `main.swift` 启动 `NSApplication` 并挂上 AppDelegate
    - _Requirements: 1.1, 1.7, 1.8_

  - [x] 1.3 实现 OverlayPanel 与唯一坐标转换函数
    - `Sources/Windowfolk/OverlayPanel.swift`：`NSPanel` 子类，`[.borderless, .nonactivatingPanel]`，`canBecomeKey`/`canBecomeMain` 返回 false，透明背景、无阴影、`.floating`、`[.canJoinAllSpaces, .stationary, .ignoresCycle]`，frame 等于 `NSScreen.screens.first` 的 `frame`，`ignoresMouseEvents = true`；内含 `SKView`（`allowsTransparency = true`，场景透明，`anchorPoint = (0, 0)`）
    - `Sources/Windowfolk/ScreenGeometry.swift`：`flipY` 与 `flipRect`，是应用中唯一做 y 翻转的地方；提供 `CGPoint`/`CGRect` 与 Core `Point`/`Rect` 互转
    - 在 AppDelegate 中创建恰好 1 个 Overlay，屏幕中央画一个占位圆点，验证点击穿透
    - _Requirements: 1.2, 1.3, 1.4, 1.5, 2.5_

  - [x] 1.4 编写架构约束测试
    - `Tests/WindowfolkCoreTests/ArchitectureTests.swift`：扫描 `Sources/WindowfolkCore/` 下所有 `.swift` 文件，断言不含 `import AppKit` 和 `import SpriteKit`
    - _Requirements: 27.2_

- [x] 2. 读取系统窗口
  - [x] 2.1 实现 Core 几何基础与可调常量
    - `Sources/WindowfolkCore/Geometry.swift`：`Point`、`Rect`、`Interval`、`IntervalMath.subtract`（结果按 lo 升序、互不重叠、长度 > 0）、`ScreenInfo`（`groundY = visibleFrame.maxY`）
    - `Sources/WindowfolkCore/Tunables.swift`：按 design.md「Tunable_Constant」定义全部常量，包括设计新增的 `fallGravity`、速度和戳居民参数
    - _Requirements: 2.4, 14.2_

  - [x] 2.2 定义 Window_Source 接口并实现 WindowFilter
    - `Sources/WindowfolkCore/WindowSource.swift`：`WindowID`、`WindowSnapshot`（不含标题字段）、`RawWindowInfo`、`WindowPollResult`、`WindowSource` 协议
    - `Sources/WindowfolkCore/WindowFilter.swift`：`makeResult(onScreen:all:ownPID:screen:minSize:)`，只保留 `layer == 0`、`alpha > 0`、宽高 ≥ Min_Window_Size、非本进程、中心点在主显示器内的窗口，保持顺序并重新编号 `zIndex`；丢弃宽高为负或 NaN 的条目；`existingIDs` 取 `all` 的全部 ID
    - _Requirements: 1.6, 2.1, 2.2, 2.6, 2.7_

  - [x] 2.3 编写窗口过滤的属性测试
    - 文件：`Tests/WindowfolkCoreTests/WindowFilterTests.swift`；先建立 `Tests/WindowfolkCoreTests/Generators/` 下的 `Gen.screen` 和 `Gen.rawWindowList`
    - **Property 1: 窗口过滤**
    - **Validates: Requirements 1.6, 2.1, 2.6, 2.7**

  - [x] 2.4 实现 FakeWindowSource
    - `Sources/WindowfolkCore/FakeWindowSource.swift`：支持 add、move、resize、bringToFront、sendBehind、close、hide、show 和 `failNextPoll`；`poll()` 按前后顺序输出可见窗口并重新编号 `zIndex`，`existingIDs` 包含隐藏窗口；支持 0 到 50 个窗口
    - _Requirements: 27.3, 27.4_

  - [x] 2.5 实现 WindowTable（区分可见、隐藏、关闭）
    - `Sources/WindowfolkCore/WindowTable.swift`：`WindowRecord`（保存最后一次可见快照）、`apply(_:) -> WindowChanges`，报告新出现、几何或层级变化、变为隐藏、重新显示、关闭（附最后可见快照）；`.failure` 时不改动任何记录
    - _Requirements: 2.8, 5.1, 5.2, 5.8_

  - [x] 2.6 编写 WindowTable 与 FakeWindowSource 单元测试
    - 文件：`Tests/WindowfolkCoreTests/WindowTableTests.swift`
    - 覆盖：最小化和其他桌面空间判为隐藏；ID 消失判为关闭并附最后可见快照；隐藏后关闭；失败轮询不判关闭；FakeWindowSource 各操作在下一次 poll 中体现
    - _Requirements: 2.8, 5.1, 5.2, 5.8, 27.4_

  - [x] 2.7 实现应用层 CGWindowSource
    - `Sources/Windowfolk/CGWindowSource.swift`：每次轮询调用 `CGWindowListCopyWindowInfo` 两次（`[.optionOnScreenOnly, .excludeDesktopElements]` 和 `[.optionAll]`），只读 `kCGWindowNumber`、`kCGWindowOwnerName`、`kCGWindowOwnerPID`、`kCGWindowBounds`、`kCGWindowLayer`、`kCGWindowAlpha`、`kCGWindowIsOnscreen`，不读 `kCGWindowName`；转为 `RawWindowInfo` 后交给 `WindowFilter`；任一调用返回 nil 时返回 `.failure`
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.7, 2.8_

- [x] 3. 计算可行走路面并用调试线显示
  - [x] 3.1 实现 SurfaceBuilder
    - `Sources/WindowfolkCore/SurfaceBuilder.swift`：`SurfaceID`、`Surface`（含 `y(atX:)`、`xRange`）、`ledges(for:)`、`ground(screen:)`、`build(windows:planks:screen:)`（本任务先不处理 Plank，参数留给任务 6.1）
    - 按 design.md 算法：上沿减去前方且满足 `f.minY ≤ y ≤ f.maxY` 的窗口 x 区间，剩余段按 minX 编号；追加一条 Ground；输出按 `SurfaceID` 排序
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10_

  - [x] 3.2 编写窗沿逐点刻画的属性测试
    - 文件：`Tests/WindowfolkCoreTests/SurfaceBuilderTests.swift`；新增 `Gen.windowLayout`（坐标对齐 8pt 网格）
    - **Property 3: 窗沿逐点刻画**
    - **Validates: Requirements 3.1, 3.2, 3.4, 3.5, 3.8**

  - [x] 3.3 编写路面结构不变量的属性测试
    - 文件：`Tests/WindowfolkCoreTests/SurfaceBuilderTests.swift`
    - **Property 4: 路面结构不变量**
    - **Validates: Requirements 3.6, 3.7, 3.9**

  - [x] 3.4 编写路面计算确定性的属性测试
    - 文件：`Tests/WindowfolkCoreTests/SurfaceBuilderTests.swift`
    - **Property 5: 路面计算确定性**
    - **Validates: Requirements 3.10**

  - [x] 3.5 实现 WorldEngine 骨架
    - `Sources/WindowfolkCore/WorldState.swift`：`WorldState` 先包含 `screen`、`windows`、`surfaces`、`showSurfaces`，其余字段随后续任务加入
    - `Sources/WindowfolkCore/WorldEngine.swift`：`FrameInput`、`Command`（先只有 `toggleSurfaces`）、`StepOutput`、`WorldView`、`PollRate`；`step` 先执行「WindowTable.apply → SurfaceBuilder」；物理和动画 `dt` 由相邻 `now` 相减并限制在 [0, 0.25] 秒
    - _Requirements: 3.12, 12.1, 27.1_

  - [x] 3.6 接入 GameLoop 与路面调试绘制
    - `Sources/Windowfolk/GameLoop.swift`：主线程 `Timer`（加入 `.common` 模式），30Hz 调用 `CGWindowSource.poll` 与 `WorldEngine.step`
    - `Sources/Windowfolk/SceneRenderer.swift`：「显示路面」打开时用 `SKShapeNode` 画全部 Surface（窗沿蓝、Ground 棕、Plank 橙），关闭时不画；路面变化后下一帧更新
    - `StatusMenu.swift` 的「显示路面」开关发送 `toggleSurfaces` 命令；`AppDelegate.swift` 组装 GameLoop
    - _Requirements: 3.11, 3.12, 3.13, 24.1_

- [x] 4. Checkpoint - 确保构建与测试通过
  - 运行 `swift build` 和 `swift test`，确保全部通过，有问题时询问用户。

- [x] 5. 一个会走、会跟随窗口、会掉落的居民
  - [x] 5.1 实现 Attachment 与 AttachmentResolver
    - `Sources/WindowfolkCore/Attachment.swift`：`Attachment`（`window`、`ground`、`plank`、`ladder`、`free`）；`screenPosition`（窗口隐藏时返回 nil）；`clamp(offset:window:ledges:)`（夹紧到同一窗口水平距离最近的剩余窗沿上的最近点，无剩余窗沿返回 nil）
    - Plank 和 Ladder 存储类型在任务 6、9 中加入，本任务先以协议或占位参数留出位置
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6_

  - [x] 5.2 实现 Physics 下落与落地
    - `Sources/WindowfolkCore/Physics.swift`：`FallState`、`advance(_:dt:surfaces:gravity:)`；起点 x 夹紧到屏幕宽度后不变；扫掠落地取 `y0 < surface.y(atX:) <= y1` 中最高的一条；起点所在 Surface 不算落点；到达 Ground y 仍未落地时强制落在 Ground 上（Debug 构建断言）
    - _Requirements: 6.3, 6.4, 6.5, 6.7_

  - [x] 5.3 编写下落与落地的属性测试
    - 文件：`Tests/WindowfolkCoreTests/PhysicsTests.swift`；新增 `Gen.surfaces`
    - 同时断言 `sqrt(2 * 3000 / fallGravity) <= 2`
    - **Property 10: 下落与落地**
    - **Validates: Requirements 4.2, 4.3, 6.3, 6.4, 6.5, 6.6, 6.7**

  - [x] 5.4 实现 Resident 模型与基础 ResidentController
    - `Sources/WindowfolkCore/Resident.swift`：`ResidentState`（9 个状态）、`ResidentID`、`Goal`、`Facing`、`Resident`（路线、traversal、持有物、悬挂、戳、气泡字段先声明，后续任务实现）
    - `Sources/WindowfolkCore/RandomSource.swift`：带种子的 SplitMix64
    - `Sources/WindowfolkCore/ResidentController.swift`：`Goal.none`/`confined` 下在当前 Surface 上走走停停，走到端点掉头，不使用任何通路边；落地且无目标时进入 `idle`
    - _Requirements: 6.8, 12.13_

  - [x] 5.5 在 WorldEngine 中接入居民跟随、隐藏暂停与掉落
    - `WorldEngine.swift`、`WorldState.swift`：加入 `residents`；按 design.md「失效处理顺序」实现第 1、2、3、6 步：关闭窗口时用最后可见快照换算屏幕坐标后转为 `free` 并下落；隐藏窗口上的居民不绘制、不移动、保持状态；可见窗口上的居民执行 clamp，无剩余窗沿时下落；落地后按落点更新 Attachment
    - 实现 `invariantViolations()`（无悬空不变量检查）；Release 中把违规对象设为下落
    - 暂时在首个可见窗沿中点放一位居民用于演示
    - _Requirements: 4.4, 4.5, 4.6, 4.7, 5.1, 5.2, 5.3, 5.4, 5.6, 5.7, 5.8, 6.1, 6.6, 6.8, 29.5, 29.6_

  - [x] 5.6 实现素材清单与占位图形，绘制居民
    - `Sources/WindowfolkCore/AssetCatalog.swift`：按 design.md「素材清单」列出全部素材键、尺寸和帧数（9 个居民状态 × 2、3 个生长阶段、果子、木板、梯子、工具箱、4 种气泡）
    - `Sources/Windowfolk/AssetProvider.swift`：为每个素材键生成占位纹理（都都银灰色圆角方块加三角猫耳，嘟嘟金黄色圆角方块加圆耳；气泡全部是图形，不含文字），尺寸与清单一致
    - `SceneRenderer.swift`：以对象 ID 为键复用 `SKSpriteNode` 绘制居民，隐藏窗口上的居民不绘制
    - _Requirements: 15.9, 25.1, 25.2, 25.3_

  - [x] 5.7 编写居民跟随与掉落的单元测试
    - 文件：`Tests/WindowfolkCoreTests/AttachmentTests.swift`
    - 覆盖：窗口移动后居民跟随；关闭后落到下方窗沿或 Ground；最小化不掉落、恢复后回到原偏移；窗口变窄时被夹紧到路面内；窗沿被完全遮挡时下落
    - _Requirements: 4.4, 4.6, 4.7, 5.1, 5.2, 5.6_

- [x] 6. 鼠标交互、工具箱与木板
  - [x] 6.1 实现木板模型与 PlankRules
    - `Sources/WindowfolkCore/Plank.swift`：`PlankID`、`PlankEnd`、`PlacedPlank`、`PlankState`（placed、loose、falling、dragged）
    - `Sources/WindowfolkCore/PlankRules.swift`：`snap(pointer:ledges:)`（第一端取最近窗沿，第二端取其他窗口中最近的窗沿，距离相等按 `SurfaceID` 顺序）；`validity(...)` 作为预览颜色和失效检测共用的唯一判定
    - `SurfaceBuilder.swift`：`build` 为每块已架设 Plank 追加一条 `.plank` Surface
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.9, 9.12_

  - [x] 6.2 编写木板吸附的属性测试
    - 文件：`Tests/WindowfolkCoreTests/InteractionTests.swift`
    - **Property 16: 木板吸附**
    - **Validates: Requirements 8.7, 9.1, 9.2**

  - [x] 6.3 编写木板统一判定的属性测试
    - 文件：`Tests/WindowfolkCoreTests/InteractionTests.swift`
    - **Property 17: 木板统一判定**
    - **Validates: Requirements 9.3, 9.4, 9.9, 9.12**

  - [x] 6.4 实现命中区域与工具箱布局
    - `Sources/WindowfolkCore/SpriteMetrics.swift`：各类对象的图形尺寸，与 `AssetCatalog` 一致
    - `Sources/WindowfolkCore/ToolboxLayout.swift`：`frame(screen:)` 底边与 Ground 对齐、右边距 8pt，左半 Plank 取物区、右半 Ladder 取物区
    - `Sources/WindowfolkCore/HitTesting.swift`：`hitTest(_:world:)`，命中区域为外接矩形，优先级 Resident > Item > Plank/Ladder > Toolbox
    - _Requirements: 7.1, 8.1, 8.2, 8.3, 8.4_

  - [x] 6.5 编写命中检测的属性测试
    - 文件：`Tests/WindowfolkCoreTests/InteractionTests.swift`
    - **Property 12: 命中检测**
    - **Validates: Requirements 7.1**

  - [x] 6.6 编写工具箱布局的属性测试
    - 文件：`Tests/WindowfolkCoreTests/InteractionTests.swift`
    - **Property 15: Toolbox 布局**
    - **Validates: Requirements 8.1, 8.4**

  - [x] 6.7 实现 InteractionController（手势、木板拖放、戳居民）
    - `Sources/WindowfolkCore/InteractionController.swift`：`PointerEvent`、`DragSubject`、`Gesture`、`Preview`；点击与拖动以 Click_Drag_Threshold 区分；从 Toolbox Plank 区拖出新建 Plank（数量不限），点击不新建；拖动已落下的 Plank；松手时绿色预览架设、红色预览从松开位置下落；在居民上拖动进入 `swallowed`，不改变居民
    - `ResidentController.swift`：实现戳居民的 `poke`：`idle`、`walking`、`carrying`、`waiting` 时原地跳 0.4 秒、最高 12pt，跳跃期间暂停移动；其他状态只显示气泡；未结束时再点只重置「?」气泡 1.5 秒
    - _Requirements: 7.5, 7.6, 7.7, 7.8, 7.9, 7.10, 7.11, 8.5, 8.7, 8.8, 8.9, 9.5, 9.8, 9.11, 11.1, 11.2, 11.7_

  - [x] 6.8 编写手势判定的属性测试
    - 文件：`Tests/WindowfolkCoreTests/InteractionTests.swift`
    - **Property 13: 手势判定**
    - **Validates: Requirements 7.5, 7.10, 7.11, 8.8, 11.1, 11.2**

  - [x] 6.9 编写戳居民的属性测试
    - 文件：`Tests/WindowfolkCoreTests/InteractionTests.swift`
    - **Property 14: 戳居民不改变行动**
    - **Validates: Requirements 7.6, 7.7, 7.8, 7.9**

  - [x] 6.10 在 WorldEngine 中接入玩家输入与木板校验
    - `WorldEngine.swift`：`step` 处理 `FrameInput.pointer`；失效处理第 4 步：每块已架设 Plank 用 `PlankRules.validity` 校验，失效者转为下落并按中心 x 落到正下方第一条 Surface（Ground 上成为 Ground_Object，窗沿上附着该窗口）；落下的 Plank 不进入路面计算；`WorldView` 输出命中矩形、预览和 Toolbox 位置
    - _Requirements: 9.5, 9.7, 9.8, 9.9, 9.10, 9.11_

  - [x] 6.11 实现应用层鼠标穿透与拖拽转发
    - `Sources/Windowfolk/HitTestTimer.swift`：每 50ms 读取 `NSEvent.mouseLocation`，经 `ScreenGeometry` 转换后与 `WorldView` 命中矩形比较，切换 `ignoresMouseEvents`；拖动进行中保持接收
    - `Sources/Windowfolk/PointerBridge.swift`：在 SKView 上接收 `mouseDown`/`mouseDragged`/`mouseUp`，转为 Core 坐标后加入下一帧的 `PointerEvent` 队列
    - `SceneRenderer.swift`：绘制 Toolbox、Plank（已架设、落下、拖动预览的绿色或红色）、「?」气泡和戳居民的跳跃偏移
    - _Requirements: 7.2, 7.3, 7.4, 8.1, 8.2, 8.3, 8.7, 9.3, 9.4_

- [x] 7. Checkpoint - 确保构建与测试通过
  - 运行 `swift build` 和 `swift test`，确保全部通过，有问题时询问用户。

- [x] 8. 通路图、寻路与过桥
  - [x] 8.1 实现 NavGraph 与寻路
    - `Sources/WindowfolkCore/NavGraph.swift`：`EdgeKind`、`NavEdge`、`NavGraph.build(surfaces:ladders:constants:)` 按 walk、smallJump、drop、plank 规则建边（ladder 边在任务 9.1 加入）；`route(...)` 用 Dijkstra，固定边代价按 design.md，同代价按 `SurfaceID` 顺序；`topologyHash`
    - 隐藏窗口的窗沿和端点附着在隐藏窗口上的 Plank 不传入 `build`
    - _Requirements: 5.5, 9.6, 12.2, 12.3, 12.4, 12.5, 12.12_

  - [x] 8.2 编写路线有效性的属性测试
    - 文件：`Tests/WindowfolkCoreTests/NavGraphTests.swift`
    - **Property 22: 路线有效且完整**
    - **Validates: Requirements 12.7, 12.12**

  - [x] 8.3 实现居民寻路、等待与路线重规划
    - `ResidentController.swift`：`Goal.reach(other)` 每帧更新目标为对方当前 Surface 和 x；沿路线移动，状态为 `walking`，小跳和往下跳用 `traversal` 抛物线动画；到达后停止并清除路线；剩余步骤中有边不在图中时下一帧重新规划；不可达且不在 Ground 上时进入 `waiting`，原地朝向目标并显示「...」气泡；在 Ground 上时走到离目标 x 最近点，在 ±Ground_Wander_Range 内来回走并抬头；可达后下一帧离开 `waiting`
    - _Requirements: 6.9, 6.10, 12.7, 12.8, 12.9, 12.10, 12.11_

  - [x] 8.4 在 WorldEngine 中接入通路图、桥上悬挂与第二位居民
    - `WorldEngine.swift`：拓扑哈希变化时在居民移动之前重建 NavGraph；Plank 失效时站在其上的居民（`attachment == .plank`）同帧进入 `hanging` 并 `free` 在当前屏幕坐标，`hangElapsed` 累计到 Hang_Duration 后进入 `falling`（隐藏期间暂停计时）；窗沿和 Ground 上的居民不受影响；加入 Resident_B；实现 `debugSeek` 命令（都都以嘟嘟为目标）
    - _Requirements: 5.3, 12.1, 12.9, 13.1, 13.2, 13.4, 13.6, 13.7, 26.2, 26.3_

  - [x] 8.5 接入「让都都去找嘟嘟」调试项并绘制等待气泡
    - `StatusMenu.swift`：调试子菜单加入「让都都去找嘟嘟」，发送 `debugSeek`
    - `SceneRenderer.swift`：绘制「...」气泡、`waiting` 抬头张望和 `hanging` 状态图形
    - _Requirements: 12.10, 26.1, 26.2_

  - [x] 8.6 编写地面等待范围的属性测试
    - 文件：`Tests/WindowfolkCoreTests/PhysicsTests.swift`
    - **Property 11: 地面等待范围**
    - **Validates: Requirements 6.9**

  - [x] 8.7 编写居民只走当前有效路线的属性测试
    - 文件：`Tests/WindowfolkCoreTests/ResidentTests.swift`；新增 `Gen.worldOps`（窗口操作、拖放、点击、推进时间）
    - **Property 23: 居民只走当前有效路线**
    - **Validates: Requirements 6.10, 12.1, 12.9, 12.10, 12.11, 14.8, 16.6, 18.4, 18.5, 20.4**

  - [x] 8.8 编写活动限定在当前 Surface 的属性测试
    - 文件：`Tests/WindowfolkCoreTests/ResidentTests.swift`
    - **Property 24: 活动限定在当前 Surface**
    - **Validates: Requirements 12.13, 16.8, 18.3, 18.9**

- [x] 9. 梯子与地面救援
  - [x] 9.1 实现梯子模型、LadderRules 与爬梯边
    - `Sources/WindowfolkCore/Ladder.swift`：`LadderID`、`PlacedLadder`、`LadderState`
    - `Sources/WindowfolkCore/LadderRules.swift`：`snapTop`（离指针最近的 Window_Ledge，x 取指针 x 夹紧到窗沿两端）、`bottom`（上端正下方第一条 Surface）、`validity`（竖直距离在 (0, Ladder_Length]）
    - `NavGraph.swift`：为已架设 Ladder 建双向爬梯边，代价为竖直距离；端点附着在隐藏窗口上的 Ladder 不传入
    - _Requirements: 5.5, 10.1, 10.2, 10.3, 10.4, 10.5, 12.6_

  - [x] 9.2 实现梯子拖放与爬梯状态
    - `InteractionController.swift`：从 Toolbox Ladder 区拖出新建 Ladder；拖动落下的 Ladder；没有窗沿时预览跟随指针并为红色；松手时绿色架设、红色下落
    - `ResidentController.swift`：沿爬梯边移动时为 `climbing`，速度为 `climbSpeed`；`traversal` 完成后回到 `walking`
    - _Requirements: 8.6, 10.4, 10.5, 10.6, 10.10, 11.7, 12.7_

  - [x] 9.3 在 WorldEngine 中接入梯子校验
    - `WorldEngine.swift`：失效处理第 5 步：已架设 Ladder 每次 step 按上端重新计算下端；上端窗口关闭、上端窗沿消失或超长时同一次 step 失效、移除爬梯边并下落；梯子上 `climbing` 的居民同帧进入 `falling`，不经过 `hanging`
    - _Requirements: 10.7, 10.8, 10.9, 13.5, 13.7_

  - [x] 9.4 绘制梯子与梯子预览
    - `SceneRenderer.swift`：绘制已架设、落下和拖动中的 Ladder（绿色或红色预览）、`climbing` 状态图形
    - _Requirements: 8.2, 10.3, 10.4_

  - [x] 9.5 编写梯子吸附与判定的属性测试
    - 文件：`Tests/WindowfolkCoreTests/InteractionTests.swift`
    - **Property 19: 梯子吸附与判定**
    - **Validates: Requirements 10.1, 10.2, 10.3, 10.4, 10.7, 10.8**

  - [x] 9.6 编写放置结果与预览一致的属性测试
    - 文件：`Tests/WindowfolkCoreTests/InteractionTests.swift`
    - **Property 18: 放置结果与预览一致**
    - **Validates: Requirements 9.5, 9.6, 9.8, 9.11, 10.5, 10.6, 10.10, 11.7**

  - [x] 9.7 编写通路图建边的属性测试
    - 文件：`Tests/WindowfolkCoreTests/NavGraphTests.swift`；参考实现按五条规则暴力枚举
    - **Property 21: 通路图建边**
    - **Validates: Requirements 5.5, 12.2, 12.3, 12.4, 12.5, 12.6**

  - [x] 9.8 编写支撑失效时状态转换的属性测试
    - 文件：`Tests/WindowfolkCoreTests/ResidentTests.swift`
    - **Property 25: 支撑失效时的状态转换**
    - **Validates: Requirements 10.9, 13.1, 13.2, 13.4, 13.5, 13.6, 13.7**

- [x] 10. Checkpoint - 确保构建与测试通过
  - 运行 `swift build` 和 `swift test`，确保全部通过，有问题时询问用户。

- [x] 11. 物件与搬运
  - [x] 11.1 实现 Item 模型与居民持有
    - `Sources/WindowfolkCore/Item.swift`：`ItemID`、`ItemKind`、`ItemPlacement`（attached、held、falling、dragged）、`GrowthStage`、`FlowerGrowth`
    - `ResidentController.swift`：每位居民最多持有 1 个 Item；持有时水平移动为 `carrying`，速度为 `walkSpeed × carrySpeedRatio`；被持有 Item 每帧位于居民位置加固定偏移；`hanging`、`falling`、落地时不脱手；落地后有路线则 1 秒内出发，否则按等待规则等待
    - _Requirements: 14.1, 14.2, 14.3, 14.4, 14.5, 14.6, 14.7, 14.8, 13.3_

  - [x] 11.2 实现物件拖放
    - `InteractionController.swift`：拖动 Ground_Object 中的 Item（保持抓取偏移）；松手时 x 夹紧到屏幕宽度，正下方 (0, Drop_Snap_Distance] 内取竖直距离最小的 Window_Ledge 附着，否则下落；被持有的 Item 不可拖；拖动中的 Item 不可被拿起
    - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.8, 11.9_

  - [x] 11.3 在 WorldEngine 中接入物件，并加入「给都都一个花盆」
    - `WorldEngine.swift`、`WorldState.swift`：加入 `items`；窗沿 Item 随窗口跟随、夹紧、关闭时下落、隐藏时隐藏；Plank 失效时其上未被持有的 Item 下落；持有者所在窗口关闭时 Item 随居民一起下落；实现 `debugGiveFlower` 命令（都都未持有时给一个 `pot` 花盆，已持有时不变）
    - `StatusMenu.swift`：调试子菜单加入「给都都一个花盆」
    - _Requirements: 4.4, 4.6, 4.7, 5.1, 5.2, 6.2, 14.9, 14.10, 26.4, 26.5_

  - [x] 11.4 绘制物件
    - `SceneRenderer.swift`：绘制花盆（按 Growth_Stage）、果子、被持有物件和拖动中的物件；`carrying` 状态图形
    - _Requirements: 14.4, 25.2_

  - [x] 11.5 编写物件松手的属性测试
    - 文件：`Tests/WindowfolkCoreTests/InteractionTests.swift`
    - **Property 20: 物件松手**
    - **Validates: Requirements 11.3, 11.4, 11.5, 11.6**

  - [x] 11.6 编写搬运不变量的属性测试
    - 文件：`Tests/WindowfolkCoreTests/ResidentTests.swift`
    - 同时断言 `0 < carrySpeedRatio <= 0.8`
    - **Property 26: 搬运不变量**
    - **Validates: Requirements 11.8, 11.9, 13.3, 14.1, 14.3, 14.4, 14.5, 14.6, 18.6, 20.1**

  - [x] 11.7 编写读取失败不改变世界的属性测试
    - 文件：`Tests/WindowfolkCoreTests/WindowFilterTests.swift`
    - **Property 2: 读取失败不改变世界**
    - **Validates: Requirements 2.8**

  - [x] 11.8 编写平移跟随的属性测试
    - 文件：`Tests/WindowfolkCoreTests/AttachmentTests.swift`
    - **Property 6: 平移跟随**
    - **Validates: Requirements 4.4, 4.5, 9.7, 23.7**

  - [x] 11.9 编写夹紧或下落的属性测试
    - 文件：`Tests/WindowfolkCoreTests/AttachmentTests.swift`
    - **Property 7: 夹紧或下落**
    - **Validates: Requirements 4.6, 4.7, 5.7**

  - [x] 11.10 编写隐藏再显示往返的属性测试
    - 文件：`Tests/WindowfolkCoreTests/AttachmentTests.swift`
    - **Property 8: 隐藏再显示的往返**
    - **Validates: Requirements 5.2, 5.3, 5.4, 5.6, 28.8, 28.9**

  - [x] 11.11 编写关闭即下落的属性测试
    - 文件：`Tests/WindowfolkCoreTests/AttachmentTests.swift`；Story_Stage 部分在任务 13 完成后由该测试一并覆盖（本任务先断言居民、物件、Plank、Ladder 部分）
    - **Property 9: 关闭即下落**
    - **Validates: Requirements 5.1, 5.8, 14.9, 14.10, 20.3**

  - [x] 11.12 编写无悬空不变量的属性测试
    - 文件：`Tests/WindowfolkCoreTests/InvariantTests.swift`；用 `Gen.worldOps` 驱动，每次 step 后检查 `invariantViolations()` 为空
    - **Property 42: 无悬空不变量**
    - **Validates: Requirements 6.1, 6.2, 9.10, 29.5, 29.6**

- [x] 12. Checkpoint - 确保构建与测试通过
  - 运行 `swift build` 和 `swift test`，确保全部通过，有问题时询问用户。

- [x] 13. 送花剧情
  - [x] 13.1 实现花的生长计算
    - `Sources/WindowfolkCore/Growth.swift`：`stage(elapsed:bloomDuration:)`、`advance`（`reached` 取最大值，时钟回拨不倒退）、`fastForward`（把 `plantedAt` 挪到下一阶段起点）；生长与花所在位置无关
    - _Requirements: 17.1, 17.3, 17.4, 17.5_

  - [x] 13.2 编写生长单调性的属性测试
    - 文件：`Tests/WindowfolkCoreTests/GrowthTests.swift`
    - **Property 30: 生长单调且只依赖时间**
    - **Validates: Requirements 17.1, 17.3, 17.4, 22.10**

  - [x] 13.3 实现 StoryDirector 剧情状态机
    - `Sources/WindowfolkCore/StoryDirector.swift`：`StoryStage`、`StoryState`；`giver(round:)`/`receiver(round:)`；`selectHomes`（面积与窗沿条件、中心距离最大、并列取 zIndex 之和最小、再按窗口 ID）；开局时居民放到家窗口最长窗沿中点并为 `idle`；窗口不足时两人在 Ground 上闲逛，满足后同一次更新开局
    - `update`：按 design.md 状态图推进 Wish → Waiting/Travel → Planting → Growing → Bloomed → ReturnGift → Done → 下一轮；分配 Goal；送达判定（同一 SurfaceID 且 x 差 ≤ Gift_Reach_Distance）；种花动画计时（任一方窗口隐藏时暂停，任一方 `hanging`/`falling` 时中止回到 `Travel`）；种下后记录 `plantedAt`、显示心形气泡、超过 Max_Story_Flowers 时移除最早的一朵；`Bloomed` 同一次更新给 Receiver 一个 Fruit 并进入 `ReturnGift`；送达后 Fruit 附着在 Giver 处，进入 `Done`、两人 `celebrating` 一次后转 `idle`；`Done` 满 Round_Interval 后 1 秒内开始下一轮并互换角色；掉落和关闭窗口时 Story_Stage 保持不变
    - _Requirements: 15.1, 15.2, 15.3, 15.4, 15.5, 15.6, 15.7, 15.8, 15.9, 16.1, 16.2, 16.3, 16.4, 16.5, 16.6, 16.7, 16.8, 16.9, 16.10, 16.11, 16.12, 16.13, 16.14, 17.2, 18.1, 18.2, 18.3, 18.4, 18.5, 18.6, 18.7, 18.8, 18.9, 19.1, 19.2, 19.3, 19.4, 19.5, 20.1, 20.2, 20.3, 20.4, 20.5_

  - [x] 13.4 实现快进与重新开始剧情
    - `StoryDirector.swift`：`fastForward`：`Growing` 时调用 `Growth.fastForward` 进入恰好下一阶段；`Done` 时把 `doneAt` 前移 Round_Interval；其他阶段不变；`restart`：删除全部 Flower 和 Fruit（含持有的），保留 Plank 和 Ladder，`round = 1`，`stage = nil`，清空 homes，同帧尝试开局
    - _Requirements: 17.5, 17.6, 17.7, 20.6_

  - [x] 13.5 在 WorldEngine 中接入剧情并补全调试菜单
    - `WorldEngine.swift`：在居民移动之前调用 `StoryDirector.update`，每帧推进 Growth 并在阶段变化时更新 `WorldView`；处理 `fastForward`、`restartStory` 命令；首次启动（无存档）时开局
    - `StatusMenu.swift`：调试子菜单按顺序为「让都都去找嘟嘟」「给都都一个花盆」「快进」「重新开始剧情」，任意阶段可选
    - _Requirements: 15.1, 17.2, 17.8, 26.1, 26.6, 26.7_

  - [x] 13.6 绘制剧情气泡与动画
    - `SceneRenderer.swift`：「花盆 + Receiver 头像」许愿气泡、心形气泡；`planting`（一起蹲下再跳一下）和 `celebrating` 动画；Story_Flower 阶段变化后 1 秒内换图
    - _Requirements: 15.9, 16.2, 16.10, 16.12, 17.8, 18.8_

  - [x] 13.7 编写家的选择的属性测试
    - 文件：`Tests/WindowfolkCoreTests/StoryDirectorTests.swift`
    - **Property 27: 家的选择**
    - **Validates: Requirements 15.1, 15.2, 15.3, 15.4**

  - [x] 13.8 编写剧情阶段与可达性一致的属性测试
    - 文件：`Tests/WindowfolkCoreTests/StoryDirectorTests.swift`
    - **Property 28: 剧情阶段与可达性一致**
    - **Validates: Requirements 16.3, 16.4, 16.5, 16.7, 20.2**

  - [x] 13.9 编写种花中断的属性测试
    - 文件：`Tests/WindowfolkCoreTests/StoryDirectorTests.swift`
    - **Property 29: 种花中断**
    - **Validates: Requirements 16.13, 20.5**

  - [x] 13.10 编写快进的属性测试
    - 文件：`Tests/WindowfolkCoreTests/StoryDirectorTests.swift`
    - **Property 31: 快进**
    - **Validates: Requirements 17.5, 17.7**

  - [x] 13.11 编写花数上限的属性测试
    - 文件：`Tests/WindowfolkCoreTests/StoryDirectorTests.swift`
    - **Property 33: 花数上限**
    - **Validates: Requirements 19.3, 19.4**

  - [x] 13.12 编写重新开始剧情的属性测试
    - 文件：`Tests/WindowfolkCoreTests/StoryDirectorTests.swift`
    - **Property 34: 重新开始剧情**
    - **Validates: Requirements 20.6**

  - [x] 13.13 编写剧情单元测试
    - 文件：`Tests/WindowfolkCoreTests/StoryExampleTests.swift`
    - 覆盖：窗口不足时在 Ground 活动、窗口够了之后开局；种花落点为 Window_Ledge、Plank、Ground 三种；种花时窗口隐藏暂停计时；`Done` 中快进立即开始下一轮；`ReturnGift` 中 Receiver 掉落后继续送果子
    - _Requirements: 15.6, 15.7, 16.11, 16.14, 17.6, 18.6, 18.7, 18.8_

  - [x] 13.14 编写演示流程场景测试
    - 文件：`Tests/WindowfolkCoreTests/DemoScenarioTests.swift`；用 FakeWindowSource 和手动时钟复现：许愿张望、拉近窗口架桥、桥上拖开窗口后悬挂再掉落（仍持有花盆）、Ground 上张望、放梯子爬上去送达、种花、快进开花、回赠果子并庆祝
    - _Requirements: 28.6_

- [x] 14. 事件记录
  - [x] 14.1 实现 EventRecord 与 EventCodec
    - `Sources/WindowfolkCore/EventLog.swift`：`EventType`（14 种）、`EventRecord`、`EventCodec.encodeLine`（五个字段，`.sortedKeys`，nil 显式写 `null`，`time` 用 `ISO8601DateFormatter` `[.withInternetDateTime]` 截断到秒，行尾一个 `\n`）、`decodeLine`、`EventSink` 协议
    - _Requirements: 21.1, 21.3, 21.4, 21.5, 21.6, 21.7, 21.8, 21.9_

  - [x] 14.2 实现文件追加并接入应用
    - `Sources/WindowfolkCore/FileEventSink.swift`：构造时传入目录（默认 `~/Library/Application Support/Windowfolk/` 由应用层传入）；目录或文件不存在时先创建；`FileHandle` `seekToEnd` 后追加；失败时丢弃该条，不重试、不抛出
    - `GameLoop.swift`：把 `StepOutput.events` 编码后在后台串行队列上追加；v1 不读取该文件
    - _Requirements: 21.2, 21.10, 21.11, 21.12, 27.6_

  - [x] 14.3 在 WorldEngine 中产生事件
    - `WorldEngine.swift`：按 design.md 的触发点产生 `crossed_bridge`、`climbed_ladder`、`fell`、`landed`、`waiting_started`、`round_started`、`planted`、`sprouted`、`bloomed`、`gift_delivered`、`plank_placed`、`plank_dropped`、`ladder_placed`、`ladder_dropped`；涉及窗口时 `target` 或 `detail` 写 `app:<ownerName>`
    - _Requirements: 21.1, 21.5, 21.6, 21.7, 21.8_

  - [x] 14.4 编写事件编码往返的属性测试
    - 文件：`Tests/WindowfolkCoreTests/EventLogTests.swift`；新增 `Gen.eventRecord`（含中文、emoji、引号、反斜杠、换行）
    - **Property 35: 事件编码往返**
    - **Validates: Requirements 21.1, 21.3, 21.4, 21.5, 21.6, 21.7, 21.9**

  - [x] 14.5 编写事件追加保序的属性测试
    - 文件：`Tests/WindowfolkCoreTests/EventLogTests.swift`；使用临时目录
    - **Property 36: 事件追加保序**
    - **Validates: Requirements 21.2**

  - [x] 14.6 编写事件文件单元测试
    - 文件：`Tests/WindowfolkCoreTests/EventLogTests.swift`
    - 覆盖：目录和文件自动创建；目录不可写时丢弃且不抛出，之后的事件照常尝试；测试不触碰 `~/Library/Application Support/Windowfolk/`
    - _Requirements: 21.10, 21.11, 27.6_

- [x] 15. Checkpoint - 确保构建与测试通过
  - 运行 `swift build` 和 `swift test`，确保全部通过，有问题时询问用户。

- [x] 16. 保存与恢复
  - [x] 16.1 实现 SaveFile 与编解码
    - `Sources/WindowfolkCore/SaveFile.swift`：`SaveFile`、`SavedStory`、`SavedResident`、`SavedHeldItem`、`SavedObject`、`SavedObjectKind`
    - `Sources/WindowfolkCore/SaveCodec.swift`：`currentVersion = 1`，`encode`/`decode`（日期 `.secondsSince1970`，版本不符抛 `.versionMismatch`，未知物件类型跳过）
    - _Requirements: 22.3, 22.12, 22.13_

  - [x] 16.2 实现世界快照与恢复
    - `Sources/WindowfolkCore/SaveSnapshot.swift`：`snapshot`：窗沿和 Plank 上的 Item、全部 Plank 和 Ladder 归一为 Ground_Object（Plank 取两端中点 x，Ladder 取下端 x，隐藏窗口上的取最后可见快照）；被持有的 Item 记在居民名下；`planting` 存为 `travel`，`bloomed` 存为 `returnGift` 并带 Fruit；`restore`：Ground_Object 从屏幕上方落到夹紧后的 x，居民落到离保存 x 最近的窗沿，没有窗沿时落到 Ground；恢复轮次、阶段、`doneAt`，按当前时间重算生长阶段
    - `WorldEngine.swift`：`init(restored:)` 和 `makeSave()`
    - _Requirements: 19.6, 19.7, 22.4, 22.6, 22.7, 22.8, 22.9, 22.10_

  - [x] 16.3 实现存档文件读写并接入应用
    - `Sources/WindowfolkCore/FileSaveStore.swift`：`SaveStore` 协议与实现；`write` 用 `.atomic`；`backupCorrupt` 重命名为 `world.corrupt-yyyyMMdd-HHmmss.json`，重命名失败时忽略
    - `AppDelegate.swift`：启动时读取，不存在则首次开局，解析失败或版本不符则备份后首次开局；`applicationShouldTerminate` 同步保存后退出，保存失败时原文件不变并直接退出
    - `GameLoop.swift`：每满 Autosave_Interval 在后台队列原子保存，失败时下个周期重试
    - _Requirements: 1.9, 1.10, 22.1, 22.2, 22.5, 22.11, 22.12, 15.8_

  - [x] 16.4 编写存档往返的属性测试
    - 文件：`Tests/WindowfolkCoreTests/PersistenceTests.swift`；新增 `Gen.saveFile`
    - **Property 37: 存档往返**
    - **Validates: Requirements 22.3, 22.9, 22.13**

  - [x] 16.5 编写保存时归一为地面物件的属性测试
    - 文件：`Tests/WindowfolkCoreTests/PersistenceTests.swift`
    - **Property 38: 保存时归一为地面物件**
    - **Validates: Requirements 22.4, 22.8**

  - [x] 16.6 编写损坏存档回退的属性测试
    - 文件：`Tests/WindowfolkCoreTests/PersistenceTests.swift`；使用临时目录
    - **Property 40: 损坏存档回退**
    - **Validates: Requirements 22.12**

  - [x] 16.7 编写送花方轮换的属性测试
    - 文件：`Tests/WindowfolkCoreTests/StoryDirectorTests.swift`；包括轮次编号写入存档再恢复
    - **Property 32: 送花方轮换**
    - **Validates: Requirements 15.5, 19.2, 19.5, 19.6**

  - [x] 16.8 编写存档单元测试
    - 文件：`Tests/WindowfolkCoreTests/PersistenceTests.swift`
    - 覆盖：`Done` 恢复时倒计时已过和未过；`planting` 保存后恢复为 `travel` 且花在 Giver 手上；不存在 `world.json` 时首次开局；写入失败后原文件内容不变
    - _Requirements: 19.7, 22.5, 22.10, 22.11_

- [x] 17. 边界情况、素材替换、打包与演示准备
  - [x] 17.1 实现轮询频率策略
    - `Sources/WindowfolkCore/PollRatePolicy.swift`：`ActivitySample`、`next(after:)`；启动为 active，任一变化或拖拽立即 active，连续安静 2 秒后 idle
    - `WorldEngine.swift`：比较前后两帧窗口、居民状态与位置、拖拽状态生成样本，输出 `nextRate`
    - _Requirements: 24.1, 24.2, 24.3, 24.4, 24.5, 24.6, 29.2_

  - [x] 17.2 应用层按频率调整循环
    - `GameLoop.swift`：按 `nextRate` 重设定时器间隔；SKView `preferredFramesPerSecond` 跟随；idle 且画面不变时 `isPaused = true`
    - _Requirements: 24.2, 29.1, 29.2_

  - [x] 17.3 编写轮询频率策略的属性测试
    - 文件：`Tests/WindowfolkCoreTests/PollRatePolicyTests.swift`；新增 `Gen.activitySamples`
    - **Property 41: 轮询频率策略**
    - **Validates: Requirements 24.2, 24.3, 24.4, 24.5, 24.6, 29.2**

  - [x] 17.4 处理睡眠唤醒与显示变化
    - `WorldEngine.swift`：检测 `ScreenInfo` 变化，把 Ground 上的居民和 Ground_Object 夹紧到新 Ground 内完整可见的最近位置；窗沿对象按原 offset 重新定位
    - `Sources/Windowfolk/ScreenObserver.swift`：监听 `NSWorkspace.didWakeNotification` 和 `NSApplication.didChangeScreenParametersNotification`，2 秒内重设 Overlay frame 和 `ScreenInfo`；`NSScreen.screens` 为空时暂停 GameLoop；在 `AppDelegate.swift` 中注册
    - _Requirements: 8.4, 23.5, 23.6, 23.7, 23.8_

  - [x] 17.5 编写启动落位与屏幕夹紧的属性测试
    - 文件：`Tests/WindowfolkCoreTests/PersistenceTests.swift`
    - **Property 39: 启动落位与屏幕夹紧**
    - **Validates: Requirements 22.6, 22.7, 23.8**

  - [x] 17.6 实现全屏检测
    - `Sources/Windowfolk/FullscreenDetector.swift`：监听前台应用和桌面空间变化，每次轮询后检查前台应用是否有窗口等于主显示器 frame，或屏上只剩前台应用的 layer 0 窗口；全屏时 1 秒内隐藏 SKView 根节点并保持 `ignoresMouseEvents = true`，世界状态不变；退出全屏后 1 秒内恢复
    - `GameLoop.swift`：把全屏状态传给 HitTestTimer 和渲染
    - _Requirements: 8.3, 23.1, 23.2, 23.3, 23.4_

  - [x] 17.7 实现 PNG 素材加载并编写素材规格
    - `AssetProvider.swift`：首次渲染前按顺序查找素材目录（`WINDOWFOLK_ASSETS` 环境变量、`.app` 的 `Contents/Resources/Assets/`、当前目录 `Assets/`），只用第一个存在的；逐项校验文件名、解码、@2x 像素尺寸和水平 sprite sheet 帧数，不合格只回退该项，不弹提示
    - 新建 `docs/art-spec.md`：角色设定（都都：圆脸银渐层小猫；嘟嘟：金丝熊）、每项尺寸、各状态帧数、素材目录、文件命名（每个 `AssetCatalog` 键一个文件名）、透明背景、sprite sheet 格式、用 gpt-image-2.5 生成时保持角色一致的注意事项
    - _Requirements: 25.3, 25.4, 25.5, 25.6, 25.7, 25.8_

  - [x] 17.8 编写素材清单测试
    - 文件：`Tests/WindowfolkCoreTests/AssetCatalogTests.swift`
    - 覆盖：`AssetCatalog` 包含两位居民的 9 个状态、3 个生长阶段、果子、木板、梯子、工具箱和 4 种气泡；`docs/art-spec.md` 中出现每个素材键对应的文件名
    - _Requirements: 25.2, 25.8_

  - [x] 17.9 编写打包脚本
    - `build-app.sh`：`swift build -c release`，组装 `Windowfolk.app`（`Contents/MacOS/Windowfolk`、`Contents/Info.plist` 含 `LSUIElement = YES` 与最低系统 14.0、`Contents/Resources/Assets/`）；`set -euo pipefail`，任一步失败时输出失败步骤并以非零码退出
    - 新建 `Resources/Info.plist` 模板
    - _Requirements: 1.1, 28.1, 28.2, 28.3_

  - [x] 17.10 编写演示脚本并更新 README
    - 新建 `docs/demo-script.md`：窗口数量、所属应用、位置与尺寸，哪两个窗口会成为都都和嘟嘟的家，Requirement 28.6 每一步的玩家操作；附手动验收清单（Overlay 外观与层级、鼠标穿透、无权限弹窗、全屏、睡眠唤醒、分辨率变化、桌面空间切换、最小化恢复、CPU 占用、2 小时连续运行）
    - 更新 `README.md`：`build-app.sh` 运行命令、`Windowfolk.app` 启动方法、`swift run` 开发运行方式、`docs/demo-script.md` 位置
    - _Requirements: 28.4, 28.5, 28.6, 28.7, 28.8, 28.9, 29.1, 29.3, 29.4_

- [x] 18. Final checkpoint - 确保构建与测试通过
  - 运行 `swift build`、`swift test` 和 `./build-app.sh`，确保全部通过且 `swift test` 在 60 秒内完成，有问题时询问用户。

## Notes

- 带 `*` 的子任务是测试任务，可以为了更快完成 MVP 而跳过；核心实现任务都不带 `*`。
- 每个任务都标注了对应的需求条款，便于追溯。
- 属性测试验证 design.md 中 42 条正确性属性，每条属性一个子任务；单元测试覆盖具体例子和边界情况。
- 同一测试文件的多个属性测试被安排在不同执行批次，避免并行写同一文件。
- Requirement 1.3 至 1.5、2.3、23.1 至 23.6、28.3、28.6 至 28.9、29.1、29.3、29.4 等依赖真实系统窗口和屏幕的验收，按 `docs/demo-script.md` 中的手动验收清单检查，不写自动化任务。
- 数值常量都在 `Tunables` 中，试玩后再调整。

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2", "1.4", "2.1"] },
    { "id": 2, "tasks": ["1.3", "2.2"] },
    { "id": 3, "tasks": ["2.3", "2.4", "2.5", "2.7", "3.1"] },
    { "id": 4, "tasks": ["2.6", "3.2", "3.5"] },
    { "id": 5, "tasks": ["3.3", "3.6", "5.1", "5.2"] },
    { "id": 6, "tasks": ["3.4", "5.3", "5.4"] },
    { "id": 7, "tasks": ["5.5", "6.1"] },
    { "id": 8, "tasks": ["5.6", "5.7", "6.2", "6.4"] },
    { "id": 9, "tasks": ["6.3", "6.7"] },
    { "id": 10, "tasks": ["6.5", "6.10"] },
    { "id": 11, "tasks": ["6.6", "6.11", "8.1"] },
    { "id": 12, "tasks": ["6.8", "8.2", "8.3"] },
    { "id": 13, "tasks": ["6.9", "8.4"] },
    { "id": 14, "tasks": ["8.5", "8.6", "8.7", "9.1"] },
    { "id": 15, "tasks": ["8.8", "9.2"] },
    { "id": 16, "tasks": ["9.3", "9.4"] },
    { "id": 17, "tasks": ["9.5", "9.7", "9.8", "11.1"] },
    { "id": 18, "tasks": ["9.6", "11.2"] },
    { "id": 19, "tasks": ["11.3", "11.5"] },
    { "id": 20, "tasks": ["11.4", "11.6", "11.7", "11.8", "11.12", "13.1", "14.1"] },
    { "id": 21, "tasks": ["11.9", "13.2", "13.3"] },
    { "id": 22, "tasks": ["11.10", "13.4"] },
    { "id": 23, "tasks": ["11.11", "13.5"] },
    { "id": 24, "tasks": ["13.6", "13.7", "14.2", "14.3", "14.4"] },
    { "id": 25, "tasks": ["13.8", "13.13", "13.14", "14.5"] },
    { "id": 26, "tasks": ["13.9", "14.6"] },
    { "id": 27, "tasks": ["13.10", "16.1"] },
    { "id": 28, "tasks": ["13.11", "16.2"] },
    { "id": 29, "tasks": ["13.12", "16.3", "16.4"] },
    { "id": 30, "tasks": ["16.5", "16.7", "17.1"] },
    { "id": 31, "tasks": ["16.6", "17.2", "17.3"] },
    { "id": 32, "tasks": ["16.8", "17.4"] },
    { "id": 33, "tasks": ["17.5", "17.6", "17.7"] },
    { "id": 34, "tasks": ["17.8", "17.9"] },
    { "id": 35, "tasks": ["17.10"] }
  ]
}
```
