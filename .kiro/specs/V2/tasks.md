# Implementation Plan: Windowfolk V2

## Overview

按 `design.md` 以 Swift 6 增量实现 V2。顺序为：基础类型 → Decor → 居民扩展与自主活动 → 心愿 → 追逐 → 存档 v2 → 日记数据、Prompt、LLM 与设置 → 日记生成与小心思 → 素材 → 应用层接线 → 集成测试。核心规则全部放在 `Sources/WindowfolkCore`（不导入 AppKit、SpriteKit），`WorldEngine` 只做编排，V2 编排写在 `WorldEngine+V2.swift`。每个任务完成后都应能 `swift test` 通过；受 V2 行为影响的 v1 测试在对应任务内一并更新（见 design.md「v1 属性的调整」）。

## Tasks

- [x] 1. 基础类型、昼夜与水平路线度量
  - [x] 1.1 扩充 Tunables、ResidentState 和 EventType
    - 在 `Tunables.swift` 加入 design.md「Tunables 新增」中的全部常量及默认值（含 `toolboxShakeDuration`、`recentEventCount`）
    - `ResidentState` 新增 `sitting`、`sleeping`、`running`（共 12 个）；`EventType` 新增 11 个取值（共 25 个）
    - 更新 v1 中断言 ResidentState 数量（9 → 12）和 EventType 数量（14 → 25）的测试
    - _Requirements: 18.1, 16.1, 19.1_

  - [x] 1.2 编写事件编码往返属性测试（`EventLogV2Tests.swift`）
    - **Property 51: 事件编码往返覆盖新类型**
    - **Validates: Requirements 18.1**

  - [x] 1.3 实现 `DayNight.swift`
    - `LocalClock` 协议、`SystemLocalClock`、测试替身 `ManualLocalClock`（`set`、`advance`）、`DayNightOverride`、`DayNight.isNight`（按时区换算到秒后比较 Night_Start、Night_End）
    - _Requirements: 5.1, 17.4, 19.2_

  - [x] 1.4 编写 Night 判定属性测试（`DayNightTests.swift`）
    - **Property 15: Night 判定**
    - **Validates: Requirements 5.1, 17.4**

  - [x] 1.5 编写 DayNight 单元测试（`DayNightTests.swift`）
    - 18:59:59、19:00:00、05:59:59、06:00:00 边界；`ManualLocalClock` 设置与推进
    - _Requirements: 5.1, 19.2_

  - [x] 1.6 实现 `NavGraph+Horizontal.swift`
    - `RouteMetric`（`.standard`、`.horizontal`）、`route(from:at:to:targetX:metric:)`、`horizontalField(from:at:)` 与 `HorizontalField`（`length(to:x:)`、`isReachable`）；同一 Surface 视为可达；v1 默认 `.standard` 行为不变
    - _Requirements: 7.2, 7.5, 9.4, 20.1, 21.2, 21.4_

  - [x] 1.7 编写水平距离场属性测试（`NavGraphHorizontalTests.swift`）
    - **Property 26: 水平距离场**
    - **Validates: Requirements 9.4, 21.2, 21.4**

- [x] 2. Decor 模型、松手规则与工具箱布局
  - [x] 2.1 实现 `Decor.swift`
    - `DecorType`（声明顺序 chair、lamp）、`DecorID`、`DecorPlacement`（attached / falling(byPlayer) / dragged(grabOffset, fresh)）、`Decor`（含 `placedSeq`）、`DecorStore`（`unlock` 只增不减并返回是否新增、`makeDecor` 满额返回 nil、`markPlaced`、`count` 含拖动中的 Decor）
    - _Requirements: 1.5, 2.6, 3.11_

  - [x] 2.2 实现 `DecorRules.swift`
    - `distance(_:to:)`、`release(...)`（先判 Toolbox 收回 discard/remove，再在 Drop_Snap_Distance 内吸附 Window_Ledge 或已架设 Plank，竖直距离最小、并列取较高，x 夹紧；否则下落）、`isFreeChair`
    - _Requirements: 3.2, 3.3, 3.4, 3.5_

  - [x] 2.3 编写 Decor 松手判定属性测试（`DecorRulesTests.swift`）
    - **Property 6: Decor 松手判定**
    - **Validates: Requirements 3.2, 3.3, 3.4, 3.5**

  - [x] 2.4 改造 `ToolboxLayout` 支持 Decor_Slot
    - `ToolboxZone` 改为 `plank`、`ladder`、`decor(DecorType)`；`zones/frame/zoneFrame/zone(at:)` 增加 `unlocked` 参数，外框宽 `36 × 区数`，新区追加在右侧、外框向左扩展，边上的点归右侧区
    - 更新调用方：`HitTesting.regions`、`InteractionController`、`WorldEngine` 中的 `WorldView.toolbox`、`SceneRenderer.renderToolbox`；`unlocked` 为空时与 v1 结果相同
    - _Requirements: 1.7, 2.1, 2.2, 2.8_

  - [x] 2.5 编写 Toolbox 布局属性测试（`ToolboxLayoutTests.swift`）
    - **Property 3: Toolbox 布局**（取代 v1 Property 15，把 v1 Toolbox 布局测试迁入此文件）
    - **Validates: Requirements 1.7, 2.1, 2.2, 2.8**

- [x] 3. Decor 接入世界
  - [x] 3.1 在 WorldState 与世界更新中加入 Decor 的附着、跟随、隐藏和下落
    - `WorldState` 新增 `decors`、`toolboxShake`；在 v1 处理 Item 的 `dropOnClosed`、`failPlank`、附着解析、`advanceFallingItems`、`enforceSupport` 中各加 Decor 循环，被动下落 `byPlayer = false`
    - `WorldView` 新增 `decors`、`unlockedDecor`、`toolboxShake`；Decor 不进入 `SurfaceBuilder` 和 `NavGraph.build`
    - _Requirements: 3.9, 3.11, 3.12_

  - [x] 3.2 实现 Decor 的拖出、拖动、放置与收回交互
    - `HitTarget.decor`（优先级 Resident > Item > Decor > Plank/Ladder > Toolbox）、`DragSubject.decor`；Decor_Slot 拖动超过 Click_Drag_Threshold 时 `makeDecor`，满额时设 `toolboxShake`（0.4 秒）并吞掉手势；拖动位置 `pointer - grabOffset`；松手按 `DecorRules.release` 处理
    - `EventRef.decor`；写 `decor_placed`（附着或玩家松手下落落地时，含 `decor_type`、`surface`）和 `decor_removed`；`discard` 不写事件；`SpriteMetrics` 新增 chair、lamp 尺寸与 `decorRect`
    - 按 v1 Property 12 的调整更新命中检测相关 v1 测试
    - _Requirements: 2.3, 2.4, 2.5, 2.6, 2.7, 3.1, 3.4, 3.5, 3.6, 3.7, 3.10, 18.4_

  - [x] 3.3 编写 Decor_Slot 拖出与上限属性测试（`DecorInteractionTests.swift`）
    - **Property 4: Decor_Slot 拖出与上限**
    - **Validates: Requirements 2.3, 2.4, 2.5, 2.6**

  - [x] 3.4 编写 Decor 拖动跟随与点击不变属性测试（`DecorInteractionTests.swift`）
    - **Property 5: Decor 拖动跟随与点击不变**
    - **Validates: Requirements 3.1, 3.6**

  - [x] 3.5 编写 Decor 跟随、隐藏、掉落与无悬空属性测试（`DecorWorldTests.swift`）
    - **Property 7: Decor 遵守 v1 的跟随、隐藏、掉落与无悬空规则**
    - **Validates: Requirements 3.9, 3.12**

  - [x] 3.6 编写 Decor 不影响通路属性测试（`DecorWorldTests.swift`）
    - **Property 8: Decor 不影响通路**
    - **Validates: Requirements 3.11**

- [x] 4. Checkpoint - 确保全部测试通过
  - Ensure all tests pass, ask the user if questions arise.

- [x] 5. 居民扩展与自主活动
  - [x] 5.1 扩展 Resident、Goal 与 ResidentController
    - `Resident` 新增 `speedFactor`、`routeMetric`、`walkDistance`、`seat`；`Goal` 新增 `hold(face:)`、`reachPoint(_:x:arriveWithin:)`、`reachWindow(_:)` 与 `FaceTarget`
    - `movingState`：`speedFactor > 1` 为 `running`；水平速度乘 `speedFactor`；`reachWindow` 对各段窗沿取最短路线；`updateResidents` 在 `walking`/`running` 帧累加 `walkDistance`；`sitting`/`sleeping` 跳过移动
    - 坐着的居民命中矩形上移 `chairSeatHeight = 10`（`SpriteMetrics`、`HitTesting`）
    - _Requirements: 3.8, 4.7, 4.14, 21.1_

  - [x] 5.2 编写 Walk_Distance 累加属性测试（`ResidentV2Tests.swift`）
    - **Property 13: Walk_Distance 累加**
    - **Validates: Requirements 4.14**

  - [x] 5.3 实现 `Activity.swift` 与 ActivityPlanner 的可执行判定和选择
    - `ActivityKind`、`ActivityTarget`、`ActivityPhase`、`Activity`、`ActivityContext`（含 `preferHome`）、`ActivityEvent`、`WakeReason`
    - `executable`（按 design 表格；`sleep` 目标为路线最短的 Lamp）、`choose`（Night 且可睡直接选 `sleep`；否则按固定顺序加权随机；`wander` 时长在 [min, max] 内）
    - _Requirements: 4.3, 4.4, 4.5, 4.6, 4.15, 5.3, 9.8, 19.3_

  - [x] 5.4 编写 Activity 可执行判定属性测试（`ActivityPlannerTests.swift`）
    - **Property 10: Activity 可执行判定**
    - **Validates: Requirements 4.3, 5.3**

  - [x] 5.5 编写 Activity 选择属性测试（`ActivityPlannerTests.swift`）
    - **Property 11: Activity 选择**
    - **Validates: Requirements 4.4, 4.5, 4.6, 4.15**

  - [x] 5.6 实现 ActivityPlanner 推进并接入 WorldEngine
    - `plan`（目标校验、放弃、Activity_Reach_Timeout、写 Goal）与 `resolve`（到达判定、坐下与坐满、入睡与醒来、拜访停留与被拜访者暂停、赏花停留）
    - 新建 `WorldEngine+V2.swift`：`FrameInput.timeZone`；每帧 DayNight 判定写 `WorldState.isNight`、`dayNightOverride`；`Command.setDayNight`；按 design「每帧更新顺序」调用 `ActivityPlanner.plan`（移动前）和 `resolve`（移动后）；`WorldState.activities`
    - 拖动有人坐的 Chair 时同帧让居民 `idle`、清 `seat`；Lamp 被拖、收回或下落时唤醒；Surface 消失补写 `woke(surfaceGone)`；写 `sat`、`slept`、`woke`、`visited` 事件
    - `InteractionController.poke` 增加 `jumpAllowed`，`sleeping` 只显示「?」；气泡新增 `.zzz`、`.flower`；`activeResidentStates` 加入 `running`
    - _Requirements: 3.8, 4.1, 4.2, 4.7, 4.8, 4.9, 4.10, 4.11, 4.13, 5.2, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10, 17.4, 18.3, 18.5, 18.6, 19.8_

  - [x] 5.7 编写「每位空闲居民恰好一个 Activity」属性测试（`ActivityEngineTests.swift`）
    - **Property 9: 每位空闲居民恰好一个 Activity**
    - **Validates: Requirements 4.1, 4.2**

  - [x] 5.8 编写 Chair 占用不变量属性测试（`ActivityEngineTests.swift`）
    - **Property 12: Chair 占用不变量**
    - **Validates: Requirements 4.13, 3.8**

  - [x] 5.9 编写自主活动单元测试（`ActivityExampleTests.swift`）
    - 拜访停留 Visit_Stay_Duration 后写 `visited`；坐满 Sit_Duration 后 Walk_Distance 归零；赏花停留；入睡写 `slept`、Night 结束醒来写 `woke`；Lamp 被拖动时醒来；Activity_Reach_Timeout 放弃且无气泡
    - _Requirements: 4.8, 4.9, 4.10, 4.11, 5.4, 5.5, 5.7, 5.8_

- [x] 6. Checkpoint - 确保全部测试通过
  - Ensure all tests pass, ask the user if questions arise.

- [x] 7. 心愿系统
  - [x] 7.1 实现 `Wish.swift`
    - `WishType`、`WishState`、`WishID`、`VisitTarget`、`ChasePhase`、`ChaseOutcome`、`FleePoint`、`ChaseState`、`Wish`（`participants`）、`WishBook`（`active`、`lastEnded`、`flowerCount`、`lastFlowerDoneAt`、`nextCheckAt`、`busy`、`wish(of:)`）、`WishEvent`
    - _Requirements: 6.7, 6.8, 8.2_

  - [x] 7.2 拆分 StoryDirector 的开局与轮次调度
    - 新增 `assignHomes(placeResidents:)` 和 `beginFlowerWish(round:)`；`update` 只在 `stage != nil` 时推进；`done` 记录 `doneAt`、不再自动开新一轮；`assignGoals` 只在 `stage != nil` 时写 Goal
    - 本任务保留 `WorldEngine` 调用的 v1 路径可用，切换在 7.4 完成；为新 API 补充或调整 `StoryDirectorUnitTests`
    - _Requirements: 6.1, 8.2, 8.3, 8.4, 8.6_

  - [x] 7.3 实现 `WishDirector.swift`（生成、非追逐 Wish 的推进与结束、Debug 触发）
    - `eligibleTypes`（flower、chair、lamp、visit 的条件；chase 条件按 Requirement 20.1 判定）、`plan` 中的检查节奏、A 先 B 后、固定随机数用量、生成时 `unlock` 并写 `decor_unlocked`、`flowerCount += 1` 并调用 `beginFlowerWish`
    - Chair_Wish、Lamp_Wish 的目标选择（水平最短，并列取 `placedSeq` 最小，选定不换）、失效清目标、`waiting` 加 Wish_Bubble；Visit_Wish 的 `reachWindow` 与 Hidden_Window 等待
    - Wish_Timeout 与场景前提放弃（不含 flower、chase）；`resolve` 中完成（Chair 坐下、Lamp 入睡、Visit 到达写 `visited` 后再 `fulfilled`）；`fulfilled`/`dropped` 更新 `lastEnded`；`trigger` 只检查 Requirement 17.2 前提
    - 快进逻辑（Growing 推进阶段；否则结束 Round_Interval 等待；其余不变）
    - _Requirements: 1.2, 1.3, 1.4, 6.2, 6.3, 6.4, 6.5, 6.6, 6.10, 6.11, 6.12, 6.13, 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 7.8, 8.1, 8.5, 8.8, 8.9, 8.10, 9.1, 9.4, 9.5, 9.6, 9.7, 9.9, 17.2, 17.3_

  - [x] 7.4 把 WishDirector 接入 WorldEngine 并切换剧情开局
    - `WorldState.wishes`；按 design 顺序调用 `WishDirector.plan`、`StoryDirector.update`（仅 Flower_Wish 进行中）、`resolve`；Home_Window 分配成功时设 `nextCheckAt`；Flower_Wish `done` 时 `fulfilled` 并清 `stage`
    - 新成为 Busy_Resident 的居民同帧结束 Activity（`sitting` 释放 Chair、`sleeping` 写 `woke(becameBusy)`）；Visit_Wish 完成后放入 `preferHome`
    - `Command`：`restartStory` 改名 `resetWorld`（执行 Requirement 17.6 的清理，同帧重新分配 Home_Window）、`triggerWish`、`unlockAllDecor`；事件按 design 表格写入并保证同帧顺序
    - `WorldView` 新增 `visitFlags`、`isNight`，`Bubble.wishIcon(chair/lamp/flag(arrow:)/footprints)`；不输出任何倒计时、计数或结局字段
    - 按 v1 Property 28、32、34 的调整，把 v1 剧情、演示场景测试改为用 `triggerWish(.flower, nil)` 启动送花
    - _Requirements: 1.6, 4.12, 6.1, 6.8, 6.9, 6.10, 8.4, 9.2, 9.3, 9.8, 10.1, 10.4, 10.5, 10.6, 17.1, 17.5, 17.6, 18.2_

  - [x] 7.5 编写生成条件判定属性测试（`WishDirectorTests.swift`）
    - **Property 19: 生成条件判定**
    - **Validates: Requirements 6.3, 8.1, 20.1**

  - [x] 7.6 编写 Wish 生成合法属性测试（`WishDirectorTests.swift`）
    - **Property 18: Wish 生成合法**
    - **Validates: Requirements 6.1, 6.2, 6.4, 6.5, 6.6, 9.1**

  - [x] 7.7 编写 Wish 结构不变量属性测试（`WishLifecycleTests.swift`）
    - **Property 20: Wish 结构不变量**
    - **Validates: Requirements 6.7, 20.5, 20.7**

  - [x] 7.8 编写 Wish_Timeout 属性测试（`WishLifecycleTests.swift`）
    - **Property 21: Wish_Timeout 只放弃普通 Wish**
    - **Validates: Requirements 6.11, 8.5, 20.6**

  - [x] 7.9 编写 Decor 目标选择属性测试（`WishTargetTests.swift`）
    - **Property 22: Decor 目标选择**
    - **Validates: Requirements 7.2, 7.5**

  - [x] 7.10 编写送花轮换属性测试（`FlowerWishTests.swift`）
    - **Property 23: 送花轮换**（序列中含存档往返，依赖 10.4）
    - **Validates: Requirements 8.2, 8.6**

  - [x] 7.11 编写快进属性测试（`FlowerWishTests.swift`）
    - **Property 24: 快进**
    - **Validates: Requirements 8.8, 8.9, 8.10**

  - [x] 7.12 编写 Visit_Flag 位置与箭头属性测试（`VisitWishTests.swift`）
    - **Property 25: Visit_Flag 位置与箭头方向**
    - **Validates: Requirements 9.2, 9.3, 9.7**

  - [x] 7.13 编写 Unlocked_Decor 单调属性测试（`WishUnlockTests.swift`）
    - **Property 1: Unlocked_Decor 单调且每种只记一次**
    - **Validates: Requirements 1.2, 1.3, 1.4, 1.5, 17.5**

  - [x] 7.14 编写成为 Busy 时结束 Activity 属性测试（`WishBusyTests.swift`）
    - **Property 14: 成为 Busy 时同帧结束 Activity**
    - **Validates: Requirements 4.12**

  - [x] 7.15 编写气泡与状态一致属性测试（`WishBubbleTests.swift`）
    - **Property 17: 气泡与状态一致**
    - **Validates: Requirements 5.6, 6.9, 6.13, 20.3**

  - [x] 7.16 编写玩家操作不受 Wish 影响属性测试（`WishInteractionTests.swift`）
    - **Property 27: 玩家操作不受 Wish 影响**
    - **Validates: Requirements 10.1**

  - [x] 7.17 编写 Wish 独立与点击不变属性测试（`WishInteractionTests.swift`）
    - **Property 28: Wish 互相独立且点击不改变 Wish**
    - **Validates: Requirements 10.2, 10.3, 10.7**

  - [x] 7.18 编写 Debug 触发心愿属性测试（`DebugTriggerTests.swift`）
    - **Property 49: Debug 触发心愿**
    - **Validates: Requirements 17.2, 17.3**

  - [x] 7.19 编写心愿单元测试（`WishExampleTests.swift`）
    - 首次开局 Unlocked_Decor 为空；Chair_Wish 完成时保持 `sitting` 不庆祝且 `sat` 在 `wish_fulfilled` 前；Lamp_Wish 完成与 Night 结束放弃；Visit_Target 隐藏时等待、关闭时放弃；送花完成后两人恢复活动；「?」气泡期间隐藏 Wish_Bubble
    - _Requirements: 1.1, 6.12, 7.3, 7.6, 8.4, 9.6, 9.7, 10.6_

- [x] 8. 追逐心愿
  - [x] 8.1 实现 `ChaseRules.swift`
    - `candidates`（每条可达 Surface 两端内收 Flee_Edge_Inset，短线段取中点，按 `(SurfaceID, x)` 排序）、`selectFleeTarget`（Chaser 长度降序、不可达视为 +∞，Runner 长度升序，x 升序）、`isCaught`
    - _Requirements: 21.4, 21.5, 22.1_

  - [x] 8.2 编写 Flee_Target 选择属性测试（`ChaseRulesTests.swift`）
    - **Property 58: Flee_Target 选择**
    - **Validates: Requirements 21.4, 21.5**

  - [x] 8.3 编写抓到判定属性测试（`ChaseRulesTests.swift`）
    - **Property 59: 抓到判定**
    - **Validates: Requirements 22.1, 22.2**

  - [x] 8.4 在 WishDirector 与 WorldEngine 中实现追逐流程
    - 生成或触发 Chase_Wish 时设 Chaser=A、Runner=B、两人 Busy、`ready` 并 `hold(face: 对方)`，只有 Wisher 显示脚印气泡；满 Chase_Ready_Duration 进入 `running`
    - `running`：按 Chase_Replan_Interval 或 `navVersion` 变化重新规划；Chaser 可达时 `.reach(Runner)`、速度 1.6，不可达时 `waiting` 无气泡；Runner 选 Flee_Target、速度 1.5，到点 `idle` 面朝 Chaser，不可达时 `idle`；Hidden_Window 上的居民视为不可达并暂停
    - `resolve`：先判 `caught` 再判 `escaped`，同帧 `fulfilled`、写含 `chase_outcome` 的 `wish_fulfilled`，两人恢复速度与度量，可庆祝者同帧 `celebrating` 加心形气泡；`WorldEngine` 增加 `navVersion`；追逐中点击只显示「?」；`resetWorld` 清除追逐且不写结局
    - _Requirements: 20.1, 20.2, 20.3, 20.4, 20.5, 20.6, 20.8, 20.9, 21.1, 21.2, 21.3, 21.4, 21.6, 21.7, 21.8, 21.9, 21.10, 21.11, 22.1, 22.2, 22.3, 22.4, 22.5, 22.6, 22.7, 22.9_

  - [x] 8.5 编写追逐 ready 阶段朝向属性测试（`ChaseTests.swift`）
    - **Property 55: 追逐 ready 阶段的朝向**
    - **Validates: Requirements 20.3, 20.8**

  - [x] 8.6 编写追逐速度属性测试（`ChaseSpeedTests.swift`）
    - **Property 56: 追逐速度**
    - **Validates: Requirements 21.1**

  - [x] 8.7 编写追逐中可达性一致属性测试（`ChaseTests.swift`）
    - **Property 57: 追逐中的可达性一致**
    - **Validates: Requirements 21.2, 21.3, 21.6**

  - [x] 8.8 编写两种结局显示相同属性测试（`ChaseOutcomeTests.swift`）
    - **Property 60: 两种结局看起来相同**
    - **Validates: Requirements 22.4**

  - [x] 8.9 编写戳居民扩展状态属性测试（`PokeV2Tests.swift`）
    - **Property 16: 戳居民的扩展状态**
    - **Validates: Requirements 5.9, 20.9, 21.8**

  - [x] 8.10 编写重置世界属性测试（`WorldResetTests.swift`）
    - **Property 50: 重置世界**
    - **Validates: Requirements 1.6, 17.6, 22.7**

  - [x] 8.11 编写追逐单元测试（`ChaseExampleTests.swift`）
    - ready 到 running 的 2 秒边界；ready 中下落后落地面朝对方；running 中下落与 Hidden_Window 暂停时计时继续；60 秒到时与抓到同时成立取 `caught`；未庆祝的居民恢复后重新选择 Activity 且 Walk_Distance 保留
    - _Requirements: 20.4, 20.8, 21.9, 21.10, 22.2, 22.3, 22.6_

- [x] 9. Checkpoint - 确保全部测试通过
  - Ensure all tests pass, ask the user if questions arise.

- [x] 10. 存档 v2
  - [x] 10.1 扩充 `SaveFile` 到格式版本 2
    - `SaveCodec.currentVersion = 2`；`SavedResident` 新增 `walkDistance`、`lastWishEndedAt`；`SavedObjectKind` 新增 chair、lamp；新增 `SavedWish`（跳过未知类型和 chase）、`SavedWishBook`（`unlockedDecor` 丢弃未知值并去重排序）
    - 按 v1 Property 37 至 40 的调整更新 v1 存档测试与 `Generators/Gen+Save.swift`
    - _Requirements: 1.9, 15.1, 15.5, 15.6, 15.11_

  - [x] 10.2 编写 Unlocked_Decor 解码容错属性测试（`SaveFileV2Tests.swift`）
    - **Property 2: Unlocked_Decor 解码容错**
    - **Validates: Requirements 1.9**

  - [x] 10.3 编写非 v2 存档回退属性测试（`SaveFileV2Tests.swift`）
    - **Property 48: 非 v2 存档回退**
    - **Validates: Requirements 15.5**

  - [x] 10.4 扩展 `SaveSnapshot` 的保存与恢复
    - 保存：Decor 写成 Ground_Object（隐藏、拖动、下落中的取值规则按 design）、居民新字段、`wishBook`（不写 Chase_Wish，追逐中保持追逐前的 `lastWishEndedAt`）
    - 恢复：Decor 从上方落到夹紧后的 x、不写 `decor_placed`；Unlocked_Decor 恢复不写记录；恢复后重新分配 Home_Window（不移动居民）；Flower_Wish 无条件恢复，其他 Wish 按 Wish_Timeout 恢复或 `dropped`；Visit_Target 按应用名称匹配、排除 Home_Window、取 zIndex 最小；冷却按保存时间起算；居民不处于 `sitting`、`sleeping`、`running`
    - _Requirements: 1.8, 15.1, 15.2, 15.3, 15.4, 15.7, 15.8, 15.9, 15.10, 15.11_

  - [x] 10.5 编写存档 v2 往返属性测试（`PersistenceV2Tests.swift`）
    - **Property 44: 存档 v2 往返**
    - **Validates: Requirements 1.8, 15.1, 15.6, 15.11**

  - [x] 10.6 编写 Wish 恢复规则属性测试（`PersistenceV2Tests.swift`）
    - **Property 45: Wish 恢复规则**
    - **Validates: Requirements 15.3, 15.8, 15.9, 15.11**

  - [x] 10.7 编写 Visit_Target 恢复匹配属性测试（`VisitRestoreTests.swift`）
    - **Property 46: Visit_Target 恢复匹配**
    - **Validates: Requirements 15.4**

  - [x] 10.8 编写启动落位扩展到 Decor 属性测试（`RestoreLandingV2Tests.swift`）
    - **Property 47: 启动落位扩展到 Decor**
    - **Validates: Requirements 15.2, 15.10**

- [x] 11. 日记数据、Prompt_Payload、LLM 客户端与设置
  - [x] 11.1 实现 `Diary.swift`、`DiaryStore.swift`、`EventLogReader.swift`
    - `LocalDate`（`of(_:timeZone:)`、`range`，编码为 `yyyy-MM-dd`）、`DiaryMethod`、`DiaryEntry`、`DiaryCodec`（键排序、一行）、`DiaryStorage` 协议与 `FileDiaryStorage(directory:)`、`DiaryStore`（跳过坏行、同键取最后一行、写入失败返回 false）、`DiaryKey`
    - `EventLogReader.parse` 逐行解码并跳过坏行和不完整末行
    - _Requirements: 13.1, 13.9, 13.10, 13.11, 19.4_

  - [x] 11.2 编写 Diary_Store 编解码与读取属性测试（`DiaryStoreTests.swift`）
    - **Property 43: Diary_Store 编解码与读取**
    - **Validates: Requirements 13.9, 13.10**

  - [x] 11.3 实现 `PromptPayload.swift`
    - `PromptEvent`（只含封闭枚举和 `Date`）、`ResidentName`、`PromptPurpose`、`PromptPayload`（`systemText`、`messages()`）、`PromptBuilder.event/diary/thought`（只映射 `resident_a`、`resident_b` 和五个白名单 detail 键）
    - _Requirements: 12.1, 12.2, 13.6, 14.1_

  - [x] 11.4 编写 Prompt_Payload 隐私不变量属性测试（`PromptPayloadTests.swift`）
    - **Property 33: Prompt_Payload 隐私不变量**
    - **Validates: Requirements 12.1, 12.2, 13.6**

  - [x] 11.5 实现 `LLM.swift`
    - `LLMRequestConfig`（自定义 `description` 隐藏 Key、不实现 Codable）、`LLMFailure`、`LLMClient` 协议、`LLMTimeout.run`（与 `Task.sleep` 竞争）与 `validate`（空白文本判失败）、测试替身 `FakeLLMClient`（脚本化文本、失败、超时，记录请求次数和 Payload）
    - _Requirements: 12.3, 12.4, 12.5, 19.2_

  - [x] 11.6 编写 LLM 返回值校验属性测试与超时单元测试（`LLMTests.swift`）
    - **Property 34: LLM 返回值校验**
    - 另含单元测试：`LLMTimeout.run` 在操作超时时返回 `.timeout`（用短超时，不实际等待 15 秒）
    - **Validates: Requirements 12.3**

  - [x] 11.7 实现 `LLMSettings.swift`
    - `LLMSettings`（无 apiKey 字段）、`LLMSettingsIssue`、`LLMSettingsValidation.issues/config/effective`（去首尾空白、`URLComponents` 校验 http/https 与 host、钥匙串失败按 Key 为空）、`LLMSettingsStore` 协议与 `FileLLMSettingsStore(directory:)`（读失败返回默认值）、`SecretStore` 协议与 `InMemorySecretStore`
    - _Requirements: 11.1, 11.3, 11.4, 11.5, 11.6, 11.9, 12.6, 19.4_

  - [x] 11.8 编写 LLM 设置校验属性测试（`LLMSettingsTests.swift`）
    - **Property 29: LLM 设置校验**
    - **Validates: Requirements 11.5, 11.6, 11.9**

  - [x] 11.9 编写 LLM 设置往返属性测试（`LLMSettingsTests.swift`）
    - **Property 30: LLM 设置往返**
    - **Validates: Requirements 11.4**

- [x] 12. 日记生成与小心思
  - [x] 12.1 实现 `DiaryWriter.swift` 与 `DiaryTemplates`
    - `DiaryTemplates.sentence/text`（每种事件一个固定句式；Chase_Wish 按结局和 Chaser/Runner 选 4 句之一，不含「输」「赢」「失败」；`thought_shown` 不出句）
    - `DiaryWriter.relevant`、`pending`、`write`（config 为 nil 用模板；LLM 失败回退模板；按字素截断到 Diary_Max_Length）
    - _Requirements: 13.1, 13.2, 13.3, 13.4, 13.5, 13.6, 13.7, 13.8, 13.13, 22.8_

  - [x] 12.2 编写日记事件归类属性测试（`DiaryWriterTests.swift`）
    - **Property 39: 日记事件归类**
    - **Validates: Requirements 13.1**

  - [x] 12.3 编写需要补写的日记属性测试（`DiaryWriterTests.swift`）
    - **Property 40: 需要补写的日记**
    - **Validates: Requirements 13.2, 13.3, 13.13**

  - [x] 12.4 编写日记模板确定且保序属性测试（`DiaryTemplateTests.swift`）
    - **Property 41: 日记模板确定且保序**
    - **Validates: Requirements 13.5, 22.8**

  - [x] 12.5 编写日记截断属性测试（`DiaryTemplateTests.swift`）
    - **Property 42: 日记截断**
    - **Validates: Requirements 13.8**

  - [x] 12.6 编写日记单元测试（`DiaryExampleTests.swift`）
    - 假 LLM_Client 返回失败时生成方式为 `template`（Requirement 19.5 指定）；LLM 成功时为 `llm`；4 种追逐句式；`diary.jsonl` 写入失败时丢弃该篇且已有行不变；「写今天的日记」只用今天的事件并替换
    - _Requirements: 13.4, 13.7, 13.11, 19.5, 22.8_

  - [x] 12.7 实现 `Thought.swift` 与 `ThoughtEngine.swift`
    - `ThoughtRequest`、`ThoughtResult`、`ThoughtDisplay`；`Resident` 新增 `thought` 字段
    - `ThoughtEngine.normalize`（换行段替换为一个空格、去首尾空白、按字素截断、再去尾部空白、空串为 nil）与 `step`（关闭、收结果只认进行中 id、移除、发请求，最近 20 条事件）
    - _Requirements: 12.4, 14.1, 14.2, 14.3, 14.5, 14.7, 14.8, 14.9, 14.10_

  - [x] 12.8 编写 Thought 文本规整属性测试（`ThoughtNormalizeTests.swift`）
    - **Property 37: Thought 文本规整**
    - **Validates: Requirements 14.2, 14.7**

  - [x] 12.9 把 ThoughtEngine 接入 WorldEngine 并实现 Thought 气泡布局
    - `FrameInput` 新增 `worldHidden`、`thoughtsEnabled`、`thoughtResults`；`StepOutput.thoughtRequests`；`WorldState.thoughts`；在全部事件产生后调用 `step`，`suppressed` 按 design 计算；写 `thought_shown`；`ResidentView.thought`、`seatLift`
    - 在 `Thought.swift` 中新增纯函数布局：宽度 `max(w + 2 × 内边距, 图标气泡宽度)`，有 Wish_Bubble 时画在其上方留 2pt
    - _Requirements: 12.5, 14.1, 14.3, 14.4, 14.6, 14.8, 16.6, 16.7_

  - [x] 12.10 编写 Thought 状态机属性测试（`ThoughtEngineTests.swift`）
    - **Property 35: Thought 状态机**
    - **Validates: Requirements 12.4, 14.1, 14.3, 14.5, 14.6, 14.8, 14.9, 14.10**

  - [x] 12.11 编写 LLM 请求不影响世界推进属性测试（`ThoughtIsolationTests.swift`）
    - **Property 36: LLM 请求不影响世界推进**
    - **Validates: Requirements 12.5**

  - [x] 12.12 编写 Thought 气泡布局属性测试（`ThoughtLayoutTests.swift`）
    - **Property 38: Thought 气泡布局**
    - **Validates: Requirements 14.4, 16.7**

- [x] 13. Checkpoint - 确保全部测试通过
  - Ensure all tests pass, ask the user if questions arise.

- [x] 14. 素材扩充
  - [x] 14.1 扩充 AssetCatalog、SpriteMetrics 与素材规格
    - `frameCount` 增加 sitting 2、sleeping 4、running 6；`BubbleIcon` 增加 chair、lamp、flag、flower、zzz、footprints；新增 `decor_chair`、`decor_lamp_off`、`decor_lamp_on`、`visit_flag`；`AssetCatalog.all` 追加 16 项；`SpriteMetrics` 新增 `visitFlag`
    - `docs/art-spec.md` 追加 16 行（尺寸、帧数、文件名，不与 v1 重名）；更新 `AssetCatalogTests`、`ArchitectureTests` 中的清单计数与文件名唯一性断言
    - _Requirements: 16.1, 16.3, 16.4_

  - [x] 14.2 在 `AssetProvider.swift` 中实现 16 项占位图形
    - 居民三个新状态沿用 `palette(for:)` 的颜色和耳形且互不相同；Lamp 发光与不发光两种外观不同；「Zzz」用线条绘制；单项 PNG 缺失时只该项回退
    - _Requirements: 5.6, 16.1, 16.2, 16.4_

- [x] 15. 应用层接线
  - [x] 15.1 实现 `KeychainSecretStore.swift` 与 `URLSessionLLMClient.swift`
    - 钥匙串 service `com.windowfolk.llm`、account `api-key`，先 Update 后 Add，空 Key 删除，失败返回 `.failure`
    - Chat Completions 请求：`POST` 到配置地址、只在请求头放 `Authorization: Bearer`、解析 `choices[0].message.content`，外层 `LLMTimeout.run(.seconds(15))` 后 `validate`，不重试
    - _Requirements: 11.3, 11.9, 12.3, 12.7_

  - [x] 15.2 实现 Settings_Window（`SettingsWindowController.swift`、`SettingsView.swift`）
    - 单例窗口，已打开时移到最前并 `NSApp.activate()`；服务地址、模型名、API Key（`SecureField`）输入长度截断；0.3 秒防抖保存到 `FileLLMSettingsStore` 和 `KeychainSecretStore`；开关可用性与提示由 `LLMSettingsValidation.issues` 驱动；首次打开开关显示说明，确认后记住
    - _Requirements: 11.1, 11.2, 11.4, 11.5, 11.6, 11.7, 11.8, 11.9, 11.11_

  - [x] 15.3 实现 `DiaryCoordinator.swift` 与 Diary_Window（`DiaryWindowController.swift`、`DiaryView.swift`）
    - `DiaryCoordinator` 为 actor：启动补写早于今天的日记、日期变化时补写日期 D、「写今天的日记」；同时只运行一个批次；读取经 `EventLogWriter` 的串行队列；完成后通知窗口刷新
    - Diary_Window 单例，按日期从新到旧列出，空状态提示，顶部「写今天的日记」按钮
    - _Requirements: 13.2, 13.3, 13.4, 13.7, 13.11, 13.12, 11.11_

  - [x] 15.4 实现 `ThoughtCoordinator.swift` 并改造 `GameLoop`
    - `ThoughtCoordinator` 为 `@MainActor`：开关打开且配置合法时才调用 `LLMClient`，否则丢弃请求；关闭时取消进行中的 Task；结果排队到下一帧
    - `GameLoop` 持有 `LocalClock`，每帧填 `timeZone`、`worldHidden`、`thoughtsEnabled`（经 `effective`）、`thoughtResults`，分发 `thoughtRequests`，比较本地日期并在变化时通知 `DiaryCoordinator`
    - _Requirements: 11.10, 12.5, 12.6, 13.2, 14.1, 14.10_

  - [x] 15.5 扩展 `SceneRenderer` 的 V2 绘制
    - Decor 节点（Night 用 `decor_lamp_on`）、Visit_Flag、新气泡图标与「小旗」箭头翻转、Zzz、Thought 单行文字气泡（使用 12.9 的布局函数）、坐着的居民按 `seatLift` 上移、Toolbox 右侧 Decor_Slot 与晃动偏移
    - _Requirements: 2.1, 2.4, 5.6, 5.10, 9.2, 9.3, 14.4, 16.5, 16.6, 16.7_

  - [x] 15.6 扩展 `StatusMenu` 并在 `AppDelegate` 中组装 V2 组件
    - 菜单「显示路面」「日记」「设置…」「调试」「退出」；调试子菜单含「重置世界」「触发心愿 ▸」（送花；椅子、台灯、去看看、追逐各含都都和嘟嘟）、「昼夜 ▸」（勾选当前项，启动为自动）、「解锁全部物件」，分别发出对应 `Command`
    - `AppDelegate` 创建 `FileLLMSettingsStore`、`KeychainSecretStore`、`URLSessionLLMClient`、`FileDiaryStorage`、两个 Coordinator 和两个窗口控制器，并交给 `GameLoop` 与 `StatusMenu`；确认 `./build-app.sh` 能构建
    - _Requirements: 11.2, 13.12, 17.1, 17.4, 17.5, 17.6_

- [x] 16. 集成属性测试与场景测试
  - [x] 16.1 编写 API Key 不出现在文件和 Payload 中属性测试（`PrivacyTests.swift`）
    - **Property 31: API Key 不出现在文件和 Payload 中**
    - **Validates: Requirements 11.3, 12.7, 15.7**

  - [x] 16.2 编写开关关闭时不发请求属性测试（`DisabledLLMTests.swift`）
    - **Property 32: 开关关闭时不发请求**
    - **Validates: Requirements 11.10, 12.6**

  - [x] 16.3 编写事件记录一致属性测试（`EventLogV2ConsistencyTests.swift`）
    - **Property 52: 事件记录一致**
    - **Validates: Requirements 3.10, 6.8, 6.10, 18.2, 18.3, 18.4, 18.5, 18.6, 21.7, 22.9**

  - [x] 16.4 编写确定性属性测试（`DeterminismTests.swift`）
    - **Property 53: 确定性**
    - **Validates: Requirements 19.3**

  - [x] 16.5 编写静止时降到 Idle_Poll_Rate 属性测试（`PollRateV2Tests.swift`）
    - **Property 54: 静止时降到 Idle_Poll_Rate**
    - **Validates: Requirements 19.8**

  - [x] 16.6 编写 V2 完整场景测试（`V2ScenarioTests.swift`）
    - 用 `FakeWindowSource`、`ManualLocalClock` 和固定种子复现：分配家、散步、Chair_Wish 解锁并坐下、夜晚 Lamp_Wish 入睡、白天醒来、Visit_Wish 搭木板到达、Chase_Wish 改变路线后 `caught`、送花一轮，最后检查事件序列与模板日记
    - _Requirements: 1.2, 5.4, 5.7, 7.3, 7.6, 9.6, 8.4, 22.3, 13.5, 19.5_

- [x] 17. Final checkpoint - 确保全部测试通过
  - Ensure all tests pass, ask the user if questions arise.
  - 运行 `swift test`，确认全部测试（含按 V2 更新的 v1 测试）通过且总耗时不超过 90 秒；运行 `./build-app.sh` 确认应用可构建。

## Notes

- 标 `*` 的子任务是测试任务，可选，跳过可以更快得到 MVP；核心实现任务都不可选。
- 每个属性测试任务对应 design.md 中的一条 Correctness Property，测试函数上方注释格式为 `// Feature: V2, Property {编号}: {属性标题}`，每条至少 100 次迭代，使用 swift-property-based。
- 为避免并行任务改同一文件，V2 的生成器默认写在各测试文件内（`fileprivate`），不集中到 `Gen+V2.swift`；这是相对 design.md「测试文件组织」的小调整。
- 测试使用临时目录、`InMemorySecretStore`、`FakeLLMClient` 和 `ManualLocalClock`，不访问 `~/Library/Application Support/Windowfolk/`、钥匙串和网络。
- 模拟类属性每次迭代最多推进 600 帧，长时段用大步长推进时钟，控制 `swift test` 总耗时。
- Settings_Window、Diary_Window 外观、菜单勾选、真实 LLM 联通和 CPU 占用属于手动验收，不在本任务列表中。

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.3", "1.6", "2.1"] },
    { "id": 1, "tasks": ["1.1", "1.4", "1.7"] },
    { "id": 2, "tasks": ["1.2", "1.5", "2.2", "2.4"] },
    { "id": 3, "tasks": ["2.3", "2.5", "3.1"] },
    { "id": 4, "tasks": ["3.2", "5.3", "7.1", "8.1", "11.1"] },
    { "id": 5, "tasks": ["3.3", "3.5", "5.1", "5.4", "8.2", "11.2", "11.3"] },
    { "id": 6, "tasks": ["3.4", "3.6", "5.2", "5.5", "5.6", "8.3", "11.4", "11.5"] },
    { "id": 7, "tasks": ["5.7", "7.2", "11.6", "11.7"] },
    { "id": 8, "tasks": ["5.8", "5.9", "7.3", "11.8", "12.1", "12.7"] },
    { "id": 9, "tasks": ["7.4", "11.9", "12.2", "12.4", "12.8"] },
    { "id": 10, "tasks": ["7.5", "7.7", "7.9", "7.12", "7.13", "7.14", "7.15", "7.16", "7.18", "8.4", "10.1", "12.3", "12.5", "12.6"] },
    { "id": 11, "tasks": ["7.6", "7.8", "7.11", "7.17", "7.19", "8.5", "8.6", "8.8", "8.9", "8.10", "10.2", "10.4"] },
    { "id": 12, "tasks": ["7.10", "8.7", "8.11", "10.3", "10.5", "10.7", "10.8", "12.9"] },
    { "id": 13, "tasks": ["10.6", "12.10", "12.11", "12.12", "14.1", "15.1"] },
    { "id": 14, "tasks": ["14.2", "15.2", "15.3"] },
    { "id": 15, "tasks": ["15.4", "15.5"] },
    { "id": 16, "tasks": ["15.6", "16.1", "16.2", "16.3", "16.4", "16.5"] },
    { "id": 17, "tasks": ["16.6"] }
  ]
}
```
