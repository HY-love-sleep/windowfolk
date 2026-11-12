# Requirements Document

## Introduction

窗间 · Windowfolk v1「送花过桥」是一款 macOS 菜单栏应用，参加 Kiroween 2026（Resurrection 主题）。应用把真实系统窗口的上沿当作道路，把主屏底部（Dock 上方）当作地面。玩家从工具箱拖出木板和梯子连接通路，帮助居民都都（Resident_A）把花盆送到居民嘟嘟（Resident_B）的窗沿。花种下后生长、开花，嘟嘟再带一颗果子回赠给都都。一轮结束后两人轮流担任送花方，花和果子在桌面上逐渐积累。

v1 只做完整的「送花过桥」流程，目标是在比赛演示视频中从启动到回赠果子（含桥塌掉落和梯子救援）完整、稳定地跑完。v1 不接入 LLM，但事件记录格式为以后的日记功能预留。美术使用占位图形，并预留按素材规格替换 PNG 的接口。

创意来源见 `docs/concept.md`，实现计划草案见 `docs/plan-v1.md`。

## Glossary

- **Windowfolk_App**：窗间 v1 应用整体，以 `.accessory` 激活策略运行的 macOS 菜单栏应用（无 Dock 图标）。
- **Overlay**：铺满主显示器的透明、无边框覆盖窗口，所有居民、物件、工具箱都画在其中。
- **Window_Source**：读取系统窗口列表并输出 Window_Snapshot 的组件。
- **Window_Snapshot**：某一时刻一个系统窗口的数据：窗口 ID、所属应用名称、边界矩形（左上角原点坐标）、前后层级。
- **Eligible_Window**：参与地形计算的窗口：位于主显示器、`layer == 0`、不透明、宽高均不小于 Min_Window_Size、且不属于 Windowfolk_App 自身。
- **Surface_Builder**：根据 Window_Snapshot 计算全部 Surface 的组件。
- **Surface**：居民可以站立和行走的水平线段，类型为窗沿（Window_Ledge）、地面（Ground）、木板（Plank）三种之一；梯子另作为竖直通路处理。
- **Window_Ledge**：某个 Eligible_Window 上沿中，未被前方窗口遮挡的一段线段。一个窗口可以有零段或多段 Window_Ledge。
- **Ground**：主显示器 `visibleFrame` 底边对应的水平线段，横跨整个屏幕宽度。
- **Attachment**：居民或物件的位置锚点，取值为「窗口 ID 加相对窗口左边缘的偏移量」或「地面加屏幕 x 坐标」。
- **Closed_Window**：在包含所有窗口（含最小化及其他桌面空间）的系统窗口列表中，其窗口 ID 已不存在的窗口。
- **Hidden_Window**：窗口 ID 仍存在，但当前不在屏幕上显示的窗口（最小化或位于其他桌面空间）。
- **Resident**：居民。v1 共两位：Resident_A 和 Resident_B。
- **Resident_A**：名字「都都」，圆脸银渐层小猫。第一轮剧情中担任 Giver。
- **Resident_B**：名字「嘟嘟」，金丝熊。第一轮剧情中担任 Receiver。
- **Giver**：当前剧情轮次中抱着花盆去送花的居民。
- **Receiver**：当前剧情轮次中收花、开花后回赠果子的居民。
- **Story_Round**：一次从 `Wish` 到 `Done` 的完整剧情。第 1 轮 Giver 为 Resident_A，此后每轮 Giver 与 Receiver 互换。
- **Story_Flower**：由剧情种下的 Flower。
- **Resident_State**：居民状态，取值为 `idle`、`walking`、`carrying`、`waiting`、`falling`、`hanging`、`climbing`、`planting`、`celebrating`。
- **Item**：可被居民持有、可挂在窗沿或放在地面的物件，v1 包括花盆（Flower）和果子（Fruit）。
- **Ground_Object**：位于 Ground 上的 Item、Plank 或 Ladder。
- **Toolbox**：画在 Overlay 中、位于地面右下角的木箱，玩家从中拖出 Plank 和 Ladder。
- **Plank**：木板，两端各有一个 Attachment，架在两个 Window_Ledge 之间，形成一段可行走的 Surface。
- **Ladder**：梯子，下端位于 Ground 或较低的 Window_Ledge，上端搭在某个窗口上沿，形成竖直通路。
- **Nav_Graph**：通路图。节点为 Surface，边为行走、小跳、往下跳、走木板、爬梯子五类连接。
- **Story_Director**：驱动送花剧情状态机的组件。
- **Story_Stage**：剧情阶段，取值为 `Wish`、`Waiting`、`Travel`、`Planting`、`Growing`、`Bloomed`、`ReturnGift`、`Done`。
- **Home_Window**：剧情开始时分配给某位居民作为「家」的 Eligible_Window。
- **Growth_Stage**：花的生长阶段，取值为 `pot`（花盆）、`sprout`（发芽）、`bloom`（开花）。
- **Story_Clock**：可注入的时钟，用于计算花的生长时间，可在测试与调试时替换或快进。
- **Event_Log**：以 JSONL 格式写入 `~/Library/Application Support/Windowfolk/events.jsonl` 的事件记录组件。
- **Persistence**：将世界状态保存到 `~/Library/Application Support/Windowfolk/world.json` 并在启动时读取的组件。
- **Asset_Provider**：为渲染提供图形的组件；存在对应 PNG 时使用 PNG，否则生成占位图形。
- **Game_Loop**：驱动窗口轮询、世界更新和渲染的定时循环。
- **Status_Menu**：菜单栏图标弹出的菜单。
- **Debug_Menu**：Status_Menu 中的调试子菜单。
- **Tunable_Constant**：集中定义、可在代码中修改的数值常量。下列默认值均为 Tunable_Constant，需试玩后调整：
  - Min_Window_Size：120pt
  - Small_Jump_Max_Rise：24pt；Small_Jump_Max_Gap：16pt
  - Drop_Max_Height：120pt
  - Plank_Max_Span：160pt；Plank_Max_Rise：40pt
  - Ladder_Length：200pt
  - Hang_Duration：1.5 秒
  - Bloom_Duration：3 分钟（从种下到开花，sprout 阶段位于中点）
  - Active_Poll_Rate：30Hz；Idle_Poll_Rate：10Hz
  - Autosave_Interval：30 秒
  - Gift_Reach_Distance：32pt（送达判定的水平距离）
  - Round_Interval：2 分钟（`Done` 到下一轮 `Wish` 的间隔）
  - Max_Story_Flowers：5（场上同时保留的 Story_Flower 上限）
  - Idle_CPU_Budget：3%（桌面静止时 1 分钟平均 CPU 占用，按单核百分比计）
  - Click_Drag_Threshold：4pt（按下后移动不超过此距离算点击，超过算拖动）
  - Drop_Snap_Distance：24pt（松开 Item 时，正下方此距离内的 Window_Ledge 可以接住它）
  - Ground_Wander_Range：40pt（居民在 Ground 上等待时左右来回走动的半径）
  - Plant_Animation_Duration：2 秒（种花动画时长）

## Requirements

### Requirement 1: 应用外壳与透明覆盖层

**User Story:** 作为玩家，我希望应用安静地运行在菜单栏，桌面上叠一层不妨碍操作的透明世界，这样我可以照常使用电脑。

#### Acceptance Criteria

1. WHEN Windowfolk_App 启动，THE Windowfolk_App SHALL 以 `.accessory` 激活策略运行，在菜单栏显示 1 个图标，且在 Dock 和 Command-Tab 应用切换器中都不显示图标。
2. WHEN Windowfolk_App 启动，THE Windowfolk_App SHALL 创建恰好 1 个 Overlay，Overlay 的边界矩形与主显示器 `frame` 完全相同（包括菜单栏和 Dock 所在区域）。
3. THE Overlay SHALL 无边框、无标题栏、无阴影，背景 alpha 为 0。在没有任何 Resident、Item、Plank、Ladder、Toolbox 或路面线段的位置，Overlay 下方桌面的像素颜色 SHALL 与没有 Overlay 时一致。
4. THE Overlay SHALL 使用 `.floating` 窗口层级，并加入所有桌面空间。玩家切换到任意桌面空间后，Overlay SHALL 仍然显示在该空间的普通应用窗口上方。
5. THE Overlay SHALL 不成为 key window 或 main window。玩家点击 Overlay 上的可交互物件后，原来的前台应用 SHALL 继续是前台应用，键盘输入 SHALL 继续送到该应用。
6. THE Overlay SHALL 不出现在 Window_Source 输出的 Eligible_Window 中，因此不生成 Window_Ledge。
7. WHEN 玩家点击菜单栏图标，THE Status_Menu SHALL 从上到下依次显示「显示路面」开关、Debug_Menu 子菜单和「退出」3 项。
8. WHEN 玩家点击「显示路面」开关，THE Status_Menu SHALL 切换开关状态，开关打开时在该项前显示勾选标记，关闭时不显示。Windowfolk_App 启动时，「显示路面」开关 SHALL 默认为关闭。
9. WHEN 玩家在 Status_Menu 中选择「退出」，THE Windowfolk_App SHALL 先完成 Persistence 保存，再结束进程；从选择「退出」到进程结束的时间 SHALL 不超过 2 秒。
10. IF 玩家选择「退出」时 Persistence 保存失败，THEN THE Windowfolk_App SHALL 保留磁盘上原有的 `world.json` 不被损坏或截断，然后结束进程。
11. THE Windowfolk_App SHALL 支持 macOS 14 及以上版本，并使用 Swift 6 与 SwiftPM 构建。

### Requirement 2: 读取系统窗口

**User Story:** 作为玩家，我希望居民看到的地形就是我真实的窗口布局，这样移动窗口就是在改变它们的世界。

#### Acceptance Criteria

1. WHILE Windowfolk_App 运行，THE Window_Source SHALL 按 Game_Loop 当前使用的轮询频率（Active_Poll_Rate 或 Idle_Poll_Rate）每轮询一次就输出一份 Window_Snapshot 列表。列表包含该次轮询时刻的全部 Eligible_Window，按从前到后的层级排序；没有 Eligible_Window 时输出空列表。
2. THE Window_Source SHALL 只读取窗口 ID、所属应用名称、边界矩形和前后层级四类信息，不读取窗口标题，也不读取窗口画面内容。
3. THE Windowfolk_App SHALL 在不申请屏幕录制权限和辅助功能权限的情况下完成窗口读取：从首次启动到输出第一份 Window_Snapshot 列表的整个过程中，系统不弹出这两类权限的授权对话框。
4. THE Window_Source SHALL 输出以主显示器左上角为原点、以 pt 为单位的边界矩形坐标。
5. THE Windowfolk_App SHALL 只在应用层的一个转换函数中，把 Window_Source 输出的左上角原点坐标转换为 AppKit 左下角原点坐标，其他组件都不自行做这项转换。
6. IF 某个窗口边界矩形的中心点落在主显示器区域之外，THEN THE Window_Source SHALL 将该窗口排除在 Eligible_Window 之外，并从当次输出的 Window_Snapshot 列表中去掉它。
7. WHEN Window_Source 完成一次轮询，THE Window_Source SHALL 同时输出一份窗口 ID 集合，内容是包含最小化窗口和其他桌面空间窗口的完整系统窗口列表中现存的全部窗口 ID，供下游区分 Closed_Window 和 Hidden_Window。
8. IF 某次轮询中系统窗口列表读取失败，THEN THE Window_Source SHALL 保留并继续输出上一次成功读取的 Window_Snapshot 列表和窗口 ID 集合，不把任何窗口判定为 Closed_Window，并在下一次轮询时重新读取。

### Requirement 3: 计算可行走路面

**User Story:** 作为玩家，我希望被其他窗口盖住的窗沿会断开，这样地形符合我眼睛看到的样子。

#### Acceptance Criteria

1. WHEN Surface_Builder 收到一组 Window_Snapshot，THE Surface_Builder SHALL 对每个 Eligible_Window 的上沿 x 区间 [minX, maxX]，减去所有层级位于其前方、且覆盖该上沿 y 坐标的窗口的 x 区间 [minX, maxX]，并把剩下的每一段长度大于 0pt 的连续区间各输出为一条带所属窗口 ID 的 Window_Ledge。
2. THE Surface_Builder SHALL 按以下规则判定前方窗口是否覆盖某上沿的 y 坐标：在左上角原点坐标系中，满足「前方窗口矩形上边 y ≤ 该上沿 y ≤ 前方窗口矩形下边 y」即算覆盖。
3. THE Surface_Builder SHALL 只把输入 Window_Snapshot 列表中的窗口当作遮挡窗口；Windowfolk_App 自身的窗口（包括 Overlay）、Hidden_Window 和 Closed_Window 不参与遮挡。
4. IF 某前方窗口的矩形不覆盖某窗口上沿的 y 坐标（按第 2 条判定），THEN THE Surface_Builder SHALL 不因该前方窗口截断该上沿的任何区间。
5. IF 某窗口上沿的整个 x 区间都被前方窗口的 x 区间并集覆盖，THEN THE Surface_Builder SHALL 为该窗口输出零段 Window_Ledge。
6. THE Surface_Builder SHALL 让每条 Window_Ledge 的 y 坐标等于所属窗口矩形上边的 y 坐标。
7. THE Surface_Builder SHALL 在每次输出中包含恰好一条 Ground，Ground 的 y 坐标等于主显示器 `visibleFrame` 底边，x 范围等于 `visibleFrame` 的左右边界。
8. IF 输入的 Window_Snapshot 列表为空，THEN THE Surface_Builder SHALL 只输出一条 Ground，不输出任何 Window_Ledge。
9. FOR ALL 输入的 Window_Snapshot 列表，THE Surface_Builder 为同一窗口输出的各段 Window_Ledge SHALL 两两之间的 x 区间交集长度为 0pt，且每段的 x 区间都落在该窗口上沿 [minX, maxX] 之内（不变量）。
10. FOR ALL 输入的 Window_Snapshot 列表，THE Surface_Builder 对同一输入重复计算 SHALL 得到完全相同的 Surface 集合，包括每条 Surface 的类型、所属窗口 ID、坐标和数量（确定性）。
11. WHILE 「显示路面」开关打开，THE Overlay SHALL 用彩色线段绘制当前全部 Surface，Window_Ledge、Ground、Plank 三种类型各用一种互不相同的颜色。
12. WHILE 「显示路面」开关打开，WHEN 任一 Eligible_Window 移动、改变大小或前后层级发生变化，THE Overlay SHALL 在 Game_Loop 检测到该变化之后的下一帧，按新的 Surface 计算结果更新绘制。
13. WHILE 「显示路面」开关关闭，THE Overlay SHALL 不绘制任何 Surface 线段。

### Requirement 4: 跟随窗口

**User Story:** 作为玩家，我希望拖动窗口时上面的居民和物件跟着走，这样它们像真的住在窗沿上。

#### Acceptance Criteria

1. THE Windowfolk_App SHALL 为每个 Resident、每个 Item、每个 Plank 的两个端点和每个 Ladder 的上下两个端点各维护恰好一个 Attachment。
2. WHEN 一个 Resident 或 Item 落在某条 Window_Ledge 上并停止下落，THE Windowfolk_App SHALL 把它的 Attachment 设为「该 Window_Ledge 所属窗口的 ID 加上落点相对该窗口左边缘的水平偏移量」。
3. WHEN 一个 Resident 或 Item 落在 Ground 上并停止下落，THE Windowfolk_App SHALL 把它的 Attachment 设为「地面加落点的屏幕 x 坐标」。
4. WHEN Window_Snapshot 显示某个 Eligible_Window 的边界矩形原点发生变化，THE Windowfolk_App SHALL 在该快照之后的第一个渲染帧内（不晚于 1 个 Active_Poll_Rate 周期），把所有 Attachment 指向该窗口的 Resident、Item、Plank 端点和 Ladder 上端重新定位到「屏幕 x = 窗口新左边缘 x + Attachment 偏移量，屏幕 y = 窗口新上沿 y」；Attachment 为地面的对象屏幕坐标保持不变。
5. WHEN 一个窗口只发生平移（宽度和高度都不变），THE Windowfolk_App SHALL 让所有附着在该窗口上的 Resident、Item、Plank 端点和 Ladder 上端的 Attachment 偏移量保持不变，居民在平移期间自己行走造成的偏移量变化除外（不变量）。
6. IF Window_Snapshot 显示某窗口宽度变小，或该窗口的 Window_Ledge 被前方窗口遮挡而截短，导致某个附着的 Resident 或 Item 的偏移量落在该窗口所有剩余 Window_Ledge 之外，THEN THE Windowfolk_App SHALL 在下一个渲染帧内把它水平移动到同一窗口中水平距离最近的那段剩余 Window_Ledge 上的最近点，并把 Attachment 偏移量更新为该点的偏移量。
7. IF Window_Snapshot 显示某个可见窗口已没有任何剩余 Window_Ledge，THEN THE Windowfolk_App SHALL 在下一个渲染帧内让附着在该窗沿上的每个 Resident 进入 `falling` 状态、每个 Item 开始下落，并解除它们对该窗口的 Attachment。

### Requirement 5: 区分关闭与暂时看不见

**User Story:** 作为玩家，我希望最小化窗口或切换桌面时东西不会掉，只有真正关闭窗口时才掉落，这样日常切换窗口不会打乱世界。

#### Acceptance Criteria

1. WHEN Window_Source 的某次轮询结果显示某窗口成为 Closed_Window，THE Windowfolk_App SHALL 在该次轮询之后的下一帧内，让附着在该窗口上的所有 Resident 和 Item 进入下落，并让至少有一个端点附着在该窗口上的每个 Plank 和 Ladder 整体失效并下落。
2. WHEN 某个可见窗口成为 Hidden_Window，THE Windowfolk_App SHALL 在下一帧内停止绘制附着在该窗口上的所有 Resident 和 Item，以及至少有一个端点附着在该窗口上的每个 Plank 和 Ladder，且这些居民和物件都不进入下落，这些 Plank 和 Ladder 也不失效。
3. WHILE 某窗口是 Hidden_Window，THE Windowfolk_App SHALL 暂停附着在该窗口上的居民的行动：这些居民不移动，保持进入隐藏前的 Resident_State 和所持 Item，`hanging` 状态的 Hang_Duration 计时也一并暂停。
4. WHILE 某窗口是 Hidden_Window，THE Windowfolk_App SHALL 保持附着在该窗口上的居民和物件的 Attachment（窗口 ID 和相对窗口左边缘的偏移量）不变，与该窗口隐藏多久无关。
5. WHILE 某窗口是 Hidden_Window，THE Nav_Graph SHALL 排除该窗口的 Window_Ledge，以及至少有一个端点附着在该窗口上的 Plank 和 Ladder，使其他居民不会规划经过这些通路的路线。
6. WHEN Hidden_Window 重新显示在主显示器上，THE Windowfolk_App SHALL 在下一帧内按该窗口的当前位置和原 Attachment 偏移量重新绘制附着在该窗口上的居民和物件，并让居民从进入隐藏前的 Resident_State 继续行动。
7. IF Hidden_Window 重新显示时，某个居民或物件的原 Attachment 偏移量已落在该窗口当前剩余的 Window_Ledge 之外，THEN THE Windowfolk_App SHALL 按 Requirement 4 第 6、7 条处理。
8. IF Hidden_Window 在没有重新显示的情况下成为 Closed_Window，THEN THE Windowfolk_App SHALL 让附着在该窗口上的居民和物件，从该窗口最后一次可见时的边界矩形和各自的 Attachment 偏移量算出的屏幕位置重新出现，并按第 1 条进入下落。

### Requirement 6: 重力与掉落

**User Story:** 作为玩家，我希望失去支撑的东西会掉下来，这样世界的因果关系一目了然。

#### Acceptance Criteria

1. WHEN 居民所在的 Surface 消失（包括所在窗口成为 Closed_Window、所在窗口已无剩余 Window_Ledge、所在 Plank 失效），且该居民不属于 Requirement 13 规定的 `hanging` 情形，THE Resident SHALL 在下一帧进入 `falling` 状态并开始下落。
2. WHEN Item、Plank 或 Ladder 所依附的 Surface 或窗口消失，THE Windowfolk_App SHALL 在下一帧让该 Item、Plank 或 Ladder 开始下落。
3. WHILE 居民或物件处于下落中，THE Windowfolk_App SHALL 保持其屏幕 x 坐标不变，并让 y 坐标每帧单调向下变化。
4. WHILE 居民或物件处于下落中，THE Windowfolk_App SHALL 让从屏幕顶边落到 Ground 的整段下落在 2 秒内完成。
5. WHEN 下落中的居民或物件底边到达或越过某条 Surface，且这条 Surface 是当前帧中水平范围包含其 x 坐标、位于其下落起点下方的最高一条 Surface，THE Windowfolk_App SHALL 让它停止下落，并把它放在这条 Surface 上（底边与 Surface 重合）。
6. WHEN 居民或物件落到一条 Surface 上，THE Windowfolk_App SHALL 按 Requirement 4 第 2、3 条更新它的 Attachment。
7. FOR ALL 下落起点，下落中的居民或物件 SHALL 在下落开始后 2 秒内落到某条 Surface 上；Ground 横跨全屏，是最终兜底；IF 下落起点的 x 坐标超出主显示器宽度，THEN THE Windowfolk_App SHALL 先把 x 坐标限制在主显示器宽度范围内再下落（落地不变量）。
8. WHEN 居民落到 Surface 上且没有未完成的目标，THE Resident SHALL 进入 `idle` 状态。
9. WHEN 居民落到 Ground 上，有未完成的目标，且 Nav_Graph 中不存在到达目标的路线，THE Resident SHALL 进入 `waiting` 状态：先走到 Ground 上与目标水平距离最近的点，再以该点为中心在左右各 Ground_Wander_Range 的范围内来回走动，同时朝目标方向抬头张望。
10. WHEN 处于第 9 条 `waiting` 状态的居民的目标重新可达，THE Resident SHALL 在下一帧离开 `waiting` 状态，并沿新路线移动。

### Requirement 7: 鼠标穿透与戳居民

**User Story:** 作为玩家，我希望点击空白处时操作照常落到下方应用，只有点在居民、物件或工具箱上时才和世界互动。

#### Acceptance Criteria

1. THE Overlay SHALL 把每个 Resident、Item、Plank、Ladder 和 Toolbox 的命中区域定义为该对象当前帧显示图形的外接矩形，外接矩形之外的点都不算命中。
2. WHILE 鼠标指针不在任何 Resident、Item、Plank、Ladder 或 Toolbox 的命中区域内，THE Overlay SHALL 让鼠标事件（点击、拖动、滚轮、右键）全部穿透到下方应用，下方应用收到的事件与没有 Overlay 时一致。
3. WHILE 鼠标指针位于 Resident、Item、Plank、Ladder 或 Toolbox 的命中区域内，THE Overlay SHALL 接收鼠标事件，且不把这些事件传给下方应用。
4. WHEN 鼠标指针移入或移出命中区域，THE Overlay SHALL 在 100 毫秒内切换到对应的接收或穿透状态；对象移动导致命中区域经过静止的指针时同样适用。
5. WHEN 玩家在某个 Resident 的命中区域内按下鼠标左键，并在指针移动不超过 Click_Drag_Threshold 的情况下松开，THE Windowfolk_App SHALL 把这次操作判定为点击该 Resident。
6. WHEN 玩家点击某个处于 `idle`、`walking`、`carrying` 或 `waiting` 状态的 Resident，THE Resident SHALL 原地跳一下（水平位置不变，最大高度不超过 16pt，在 0.5 秒内落回起跳时的 Attachment），同时在头顶显示「?」气泡 1.5 秒。
7. WHEN 第 6 条中的跳跃结束，THE Resident SHALL 继续点击前的行动：Resident_State、行走目标、所持 Item 和当前 Story_Stage 都与点击前一致。
8. IF 玩家点击的 Resident 处于 `falling`、`hanging`、`climbing`、`planting` 或 `celebrating` 状态，THEN THE Resident SHALL 只显示「?」气泡 1.5 秒而不跳跃，Resident_State、位置以及 Hang_Duration 计时都不受影响。
9. IF 玩家在 Resident 的跳跃或「?」气泡尚未结束时再次点击它，THEN THE Resident SHALL 不开始新的跳跃，只把「?」气泡的剩余显示时间重置为 1.5 秒。
10. THE Windowfolk_App SHALL 只允许玩家通过点击与 Resident 互动。
11. WHEN 玩家在某个 Resident 的命中区域内按下鼠标左键并拖动超过 Click_Drag_Threshold，THE Resident SHALL 保持位置、Attachment 和 Resident_State 不变，不跳跃，也不显示「?」气泡，且这次拖动产生的鼠标事件不传给下方应用。

### Requirement 8: 工具箱

**User Story:** 作为玩家，我希望有一个固定的地方拿木板和梯子，这样我知道用什么去帮助居民。

#### Acceptance Criteria

1. THE Overlay SHALL 显示 Toolbox，Toolbox 底边与 Ground 对齐，右边缘与主显示器 `visibleFrame` 右边缘的水平距离不超过 16pt。
2. THE Toolbox SHALL 同时显示两个互不重叠的取物区域：Plank 取物区和 Ladder 取物区，每个区域显示对应物件的图形。
3. WHILE Windowfolk_App 运行且世界未因 Requirement 23 隐藏，THE Overlay SHALL 让 Toolbox 始终可见，不论已拖出多少 Plank 和 Ladder，也不论下方有没有系统窗口。
4. WHEN 主显示器 `visibleFrame` 发生变化（例如 Dock 大小或位置改变），THE Overlay SHALL 在下一帧内把 Toolbox 移到按第 1 条规则算出的新位置。
5. WHEN 玩家在 Plank 取物区内按下鼠标并拖动超过 Click_Drag_Threshold，THE Toolbox SHALL 新建一块 Plank，并在鼠标位置显示它的拖动预览，之后的吸附和放置按 Requirement 9 处理。
6. WHEN 玩家在 Ladder 取物区内按下鼠标并拖动超过 Click_Drag_Threshold，THE Toolbox SHALL 新建一架 Ladder，并在鼠标位置显示它的拖动预览，之后的吸附和放置按 Requirement 10 处理。
7. WHILE 玩家正在拖动从 Toolbox 取出的物件，THE Overlay SHALL 每帧更新拖动预览，使它跟随鼠标位置。
8. IF 玩家在 Toolbox 上按下鼠标后松开，且拖动距离不超过 Click_Drag_Threshold，THEN THE Toolbox SHALL 不新建任何 Plank 或 Ladder。
9. THE Toolbox SHALL 允许玩家拖出的 Plank 和 Ladder 数量不受限制，场上已有的 Plank 和 Ladder 数量不影响第 5、6 条的行为。

### Requirement 9: 木板

**User Story:** 作为玩家，我希望在两个窗沿之间架木板，这样相隔太远的居民也能互相拜访。

#### Acceptance Criteria

1. WHILE 玩家拖动 Plank，THE Windowfolk_App SHALL 把 Plank 两端分别吸附到距离鼠标指针最近的两条 Window_Ledge 上，这两条 Window_Ledge 必须属于两个不同的 Eligible_Window；每个端点取该 Window_Ledge 上离鼠标指针直线距离最近的点。
2. IF 玩家拖动 Plank 时，属于不同 Eligible_Window 的 Window_Ledge 少于两条，THEN THE Windowfolk_App SHALL 让 Plank 不吸附，以鼠标指针为中心跟随移动，并以红色显示预览。
3. WHILE 玩家拖动 Plank，且两个吸附端点的水平距离 ≤ Plank_Max_Span、竖直高差 ≤ Plank_Max_Rise，THE Windowfolk_App SHALL 以绿色显示 Plank 预览。
4. WHILE 玩家拖动 Plank，且两个吸附端点的水平距离 > Plank_Max_Span 或竖直高差 > Plank_Max_Rise，THE Windowfolk_App SHALL 以红色显示 Plank 预览。
5. WHEN 玩家在绿色预览状态下松开鼠标，THE Windowfolk_App SHALL 把 Plank 架设为一条连接这两条 Window_Ledge 的 Surface，并把两个端点分别记录为对应窗口的 Attachment。
6. WHEN 一块 Plank 架设成功，THE Nav_Graph SHALL 在下一次 Game_Loop 更新之前加入该 Plank 对应的走木板边。
7. WHILE 一块 Plank 处于已架设状态，THE Windowfolk_App SHALL 按两端的 Attachment 更新 Plank 的端点位置，让两端始终留在各自窗口的上沿上。
8. WHEN 玩家在红色预览状态下松开鼠标，THE Windowfolk_App SHALL 让 Plank 从松开位置竖直下落，落在 Plank 中心点 x 坐标正下方的第一条 Surface 上；落点是 Ground 时 Plank 成为 Ground_Object，落点是 Window_Ledge 时 Plank 成为附着在该窗口上的窗沿物件；落下的 Plank 不加入 Nav_Graph。
9. IF 某块已架设 Plank 出现以下任一情况：任一端所在窗口成为 Closed_Window、任一端所在窗口可见但端点所在的 Window_Ledge 已消失（例如被前方窗口完全遮挡）、两端水平距离 > Plank_Max_Span、两端高差 > Plank_Max_Rise，THEN THE Windowfolk_App SHALL 在检测到该情况的那次世界更新中让该 Plank 失效，并从 Nav_Graph 移除对应的 Surface 和走木板边。
10. WHEN 某块已架设 Plank 失效，THE Windowfolk_App SHALL 按第 8 条的落点规则让该 Plank 下落。
11. WHEN 玩家把一块已落下的 Plank 拖到满足第 3 条条件的位置后松开，THE Windowfolk_App SHALL 按第 5、6 条重新架设该 Plank；松开时为红色预览则按第 8 条再次下落。
12. FOR ALL 两端位置组合，THE Windowfolk_App SHALL 给出一致的 Plank 有效性判定：当且仅当两端位于两个不同 Eligible_Window 的现存 Window_Ledge 上、水平距离 ≤ Plank_Max_Span、高差 ≤ Plank_Max_Rise 时判定为有效；拖动预览颜色（第 3、4 条）和架设后的失效检测（第 9 条）都使用同一个判定。

### Requirement 10: 梯子

**User Story:** 作为玩家，我希望用梯子把掉到地面的居民接回窗沿，这样掉落不是终点。

#### Acceptance Criteria

1. WHILE 玩家拖动 Ladder 且屏幕上存在至少一条 Window_Ledge，THE Windowfolk_App SHALL 把 Ladder 上端吸附到与鼠标指针直线距离最近的 Window_Ledge 上，上端 x 坐标取鼠标 x 坐标，并限制在该 Window_Ledge 的左右端点之间。
2. WHILE 玩家拖动 Ladder 且上端已吸附到某条 Window_Ledge，THE Windowfolk_App SHALL 让 Ladder 下端从上端竖直向下，落到上端正下方第一条水平范围包含上端 x 坐标的 Ground 或 Window_Ledge 上。
3. WHILE 玩家拖动 Ladder，且上端已吸附、上下端竖直距离大于 0 且不超过 Ladder_Length，THE Windowfolk_App SHALL 以绿色显示 Ladder 预览。
4. IF 玩家拖动 Ladder 时屏幕上没有任何 Window_Ledge，或上下端竖直距离超过 Ladder_Length，THEN THE Windowfolk_App SHALL 以红色显示 Ladder 预览；没有 Window_Ledge 时预览跟随鼠标指针。
5. WHEN 玩家在绿色预览状态下松开鼠标，THE Windowfolk_App SHALL 把 Ladder 架设为连接下端 Surface 与上端 Window_Ledge 的竖直通路，并在 Nav_Graph 中加入一条双向爬梯边。
6. WHEN 玩家在红色预览状态下松开鼠标，THE Windowfolk_App SHALL 让 Ladder 从松开位置竖直下落，停在其正下方第一条 Surface 上；此时 Ladder 处于落下状态，不在 Nav_Graph 中加入任何边；停在 Ground 上时成为 Ground_Object。
7. WHILE Ladder 处于架设状态，THE Windowfolk_App SHALL 用「上端窗口 ID 加相对窗口左边缘的偏移量」作为上端 Attachment，让 Ladder 跟随上端窗口移动，并在每次世界更新时按第 2 条重新计算下端位置。
8. IF 已架设 Ladder 的上端窗口成为 Closed_Window、上端窗口可见但上端所在的 Window_Ledge 已消失，或上下端竖直距离超过 Ladder_Length，THEN THE Windowfolk_App SHALL 在检测到该变化的同一次世界更新中让该 Ladder 失效：从 Nav_Graph 中移除对应的爬梯边，并让 Ladder 竖直下落，停在其正下方第一条 Surface 上。
9. IF 某架 Ladder 失效时有 Resident 正处于 `climbing` 状态并位于该 Ladder 上，THEN THE Windowfolk_App SHALL 按 Requirement 13 第 5 条处理该 Resident。
10. WHEN 玩家拖起一架处于落下状态的 Ladder，THE Windowfolk_App SHALL 按第 1 至 4 条显示预览；松开时绿色预览按第 5 条重新架设，红色预览按第 6 条重新落下。

### Requirement 11: 拖动地面物件

**User Story:** 作为玩家，我希望能捡起掉在地上的东西放回窗沿，这样我可以修复被打乱的世界。

#### Acceptance Criteria

1. WHEN 玩家在一个 Ground_Object 的命中区域内按下鼠标左键，并在松开前把鼠标移动超过 Click_Drag_Threshold，THE Windowfolk_App SHALL 进入对该 Ground_Object 的拖动状态。
2. WHILE 某 Ground_Object 处于拖动状态，THE Windowfolk_App SHALL 让该物件每帧跟随鼠标移动，并保持按下鼠标时光标相对物件的偏移不变。
3. WHEN 玩家松开一个正在拖动的 Item，且松开点正下方 Drop_Snap_Distance 以内存在 Window_Ledge，THE Windowfolk_App SHALL 把该 Item 附着到这条 Window_Ledge 所属的窗口上，Attachment 偏移量等于松开点 x 坐标减去该窗口左边缘 x 坐标。
4. IF 松开点正下方 Drop_Snap_Distance 以内存在多条 Window_Ledge，THEN THE Windowfolk_App SHALL 把 Item 附着到其中与松开点竖直距离最小的那条 Window_Ledge 上。
5. IF 玩家松开 Item 时，松开点正下方 Drop_Snap_Distance 以内没有 Window_Ledge（包括松开点位于被前方窗口遮挡的上沿部分），THEN THE Windowfolk_App SHALL 让该 Item 按 Requirement 6 竖直下落。
6. IF 玩家在主显示器范围之外松开 Item，THEN THE Windowfolk_App SHALL 先把松开点的 x 坐标限制在主显示器宽度范围内，再按第 3 至 5 条处理。
7. WHEN 玩家松开一个正在拖动的 Plank 或 Ladder，THE Windowfolk_App SHALL 按 Requirement 9 第 5、8 条或 Requirement 10 第 5、6 条处理，与从 Toolbox 拖出时的放置规则相同。
8. WHILE 某 Item 被 Resident 持有，THE Windowfolk_App SHALL 忽略玩家对该 Item 的按下和拖动操作，该 Item 继续留在 Resident 身上。
9. WHILE 某 Item 处于拖动状态，THE Windowfolk_App SHALL 不让任何 Resident 拿起该 Item。

### Requirement 12: 通路图与寻路

**User Story:** 作为玩家，我希望居民能自己找到路，并在路断时停下来，这样我能清楚看到自己的布局改变了什么。

#### Acceptance Criteria

1. WHEN Game_Loop 的某一帧检测到 Surface 集合变化（Surface 新增、删除、位置或长度改变）、Plank 被架设或移除、或 Ladder 被架设或移除，THE Nav_Graph SHALL 在同一帧、在 Resident 移动更新之前重新计算全部节点和边。
2. IF 两条 Surface 的相邻端点 y 坐标相同，且两端点的水平间隙为 0pt（首尾相接或重叠），THEN THE Nav_Graph SHALL 在两者之间建立一条双向行走边。
3. IF 两条 Surface 的相邻端点高差大于 0pt 且不超过 Small_Jump_Max_Rise，且水平间隙不超过 Small_Jump_Max_Gap，THEN THE Nav_Graph SHALL 在两者之间建立一条双向小跳边；高差为两端点 y 坐标之差的绝对值，水平间隙为两端点 x 坐标之差的绝对值。
4. IF 较高 Surface 某一端点的 x 坐标落在另一条较低 Surface 的水平范围内，该较低 Surface 是此端点正下方最近的一条 Surface，且两者高差大于 0pt 且不超过 Drop_Max_Height，THEN THE Nav_Graph SHALL 建立一条从较高 Surface 指向该较低 Surface 的单向往下跳边。
5. WHEN 一块 Plank 被架设，THE Nav_Graph SHALL 在该 Plank 形成的 Surface 与两端 Attachment 所在的两条 Window_Ledge 之间各建立一条双向走木板边。
6. WHEN 一架 Ladder 被架设，THE Nav_Graph SHALL 在 Ladder 下端所在的 Surface 与上端所在的 Window_Ledge 之间建立一条双向爬梯边。
7. WHEN Resident 被赋予目标位置，且 Nav_Graph 中存在从 Resident 当前所在 Surface 到目标所在 Surface 的路线，THE Resident SHALL 沿该路线移动，移动期间 Resident_State 为 `walking`，持有 Item 时为 `carrying`，在 Ladder 上时为 `climbing`。
8. WHEN 移动中的 Resident 到达目标所在 Surface 上的目标 x 坐标，THE Resident SHALL 停止移动并清除当前路线。
9. WHEN Nav_Graph 重新计算后，移动中的 Resident 当前路线里尚未走完的任一节点或边已不在 Nav_Graph 中，THE Resident SHALL 在下一帧从当前位置重新规划到原目标的路线。
10. IF 规划时 Nav_Graph 中不存在从 Resident 当前所在 Surface 到目标所在 Surface 的路线，且 Resident 不在 Ground 上，THEN THE Resident SHALL 进入 `waiting` 状态，停在当前位置不移动，朝向目标 x 坐标所在的一侧，并在 `waiting` 期间持续在头顶显示「...」气泡；Resident 在 Ground 上时按 Requirement 6 第 9 条处理。例外：Story_Stage 为 `Waiting` 时，Giver 按 Requirement 16 第 2 条显示「花盆 + Receiver 头像」气泡，代替「...」气泡。
11. WHEN Nav_Graph 重新计算后，处于 `waiting` 状态的 Resident 的目标变为可达，THE Resident SHALL 在下一帧隐藏「...」气泡，离开 `waiting` 状态，并沿新路线移动。
12. FOR ALL 由 Nav_Graph 返回的路线，路线 SHALL 从 Resident 当前所在 Surface 开始、到目标所在 Surface 结束，路线中每相邻两个节点之间都存在一条 Nav_Graph 中的边，且单向往下跳边只沿从高到低的方向使用（路线有效性不变量）。
13. WHEN 没有目标位置的 Resident 在 Window_Ledge 上走到该 Window_Ledge 的端点，THE Resident SHALL 在该端点掉头并朝反方向继续行走，不经由小跳边、往下跳边、走木板边或爬梯边离开该 Window_Ledge。

### Requirement 13: 桥上失足

**User Story:** 作为玩家，我希望居民在桥塌时抓住桥边挂一会儿再掉下去，这样掉落有戏剧感又不突兀。

#### Acceptance Criteria

1. WHEN Resident 位于某块已架设的 Plank 上，且该 Plank 按 Requirement 9 第 9 条失效，THE Resident SHALL 在同一帧内进入 `hanging` 状态，并停在失效那一刻自己所在的屏幕坐标；这条规则对 `idle`、`walking`、`carrying` 状态都适用。
2. WHILE Resident 处于 `hanging` 状态，THE Resident SHALL 保持在第 1 条记录的屏幕坐标不动，不跟随已失效 Plank 的下落，不沿 Nav_Graph 移动，也不重新规划路线。
3. WHILE 持有 Item 的 Resident 处于 `hanging` 状态，THE Windowfolk_App SHALL 让该 Resident 继续持有该 Item。
4. WHEN Resident 处于 `hanging` 状态的时间达到 Hang_Duration（误差不超过 100 毫秒），THE Resident SHALL 进入 `falling` 状态，从当前屏幕坐标竖直下落，并按 Requirement 6 第 5 条落到正下方的 Surface 上。
5. WHEN Resident 正处于 `climbing` 状态位于某架 Ladder 上，且该 Ladder 按 Requirement 10 第 8 条失效，THE Resident SHALL 在同一帧内进入 `falling` 状态，不经过 `hanging` 状态，从当前屏幕坐标竖直下落。
6. IF Plank 失效时其上有多位 Resident，THEN THE Windowfolk_App SHALL 对每位 Resident 分别执行第 1 至 4 条，每位 Resident 的 Hang_Duration 都从这块 Plank 失效的那一帧开始计时。
7. IF Plank 或 Ladder 失效时某位 Resident 位于 Window_Ledge 或 Ground 上（包括 Plank 或 Ladder 端点所在的 Window_Ledge），THEN THE Windowfolk_App SHALL 不改变该 Resident 的 Resident_State 和 Attachment。

### Requirement 14: 搬运物件

**User Story:** 作为玩家，我希望居民能抱着花盆走过我搭的桥，这样每次通路连接都有实际意义。

#### Acceptance Criteria

1. WHILE Resident 持有 Item 且正沿 Surface 水平移动，THE Resident SHALL 处于 `carrying` 状态，而不是 `walking` 状态。
2. WHILE Resident 处于 `carrying` 状态，THE Resident SHALL 以大于 0、且不超过同一 Resident 空手 `walking` 速度 80% 的水平速度移动。
3. THE Windowfolk_App SHALL 限制每位 Resident 同时最多持有 1 个 Item。
4. WHILE Resident 持有 Item，THE Windowfolk_App SHALL 在每一帧把该 Item 的屏幕位置设为该 Resident 的屏幕位置加上一个固定偏移量，覆盖 `carrying`、小跳、往下跳、`climbing`、`hanging` 和 `falling` 全部过程。
5. WHILE 持有 Item 的 Resident 处于 `hanging` 或 `falling` 状态，THE Windowfolk_App SHALL 让该 Item 保持被该 Resident 持有，不脱手，也不单独下落。
6. WHEN 持有 Item 的 Resident 落地，THE Resident SHALL 继续持有该 Item，该 Item 不附着到落点 Surface，也不成为 Ground_Object。
7. WHEN 持有 Item 的 Resident 落地，且从落点到原目标存在 Nav_Graph 路线，THE Resident SHALL 在落地后 1 秒内沿该路线朝原目标出发，并进入 `carrying` 状态。
8. IF 持有 Item 的 Resident 落地后，从落点到原目标不存在 Nav_Graph 路线，THEN THE Resident SHALL 继续持有该 Item，并按 Requirement 6 第 9 条或 Requirement 12 第 10 条等待；路线出现后按第 7 条恢复前往原目标。
9. WHEN 放在 Window_Ledge 上、未被持有的 Item 所属窗口成为 Closed_Window，THE Windowfolk_App SHALL 让该 Item 竖直下落到其正下方第一条 Surface 上；落点是 Ground 时该 Item 成为 Ground_Object。
10. IF Resident 持有 Item 时其所在窗口成为 Closed_Window，THEN THE Windowfolk_App SHALL 让该 Item 随 Resident 一起下落，并保持被该 Resident 持有。

### Requirement 15: 剧情开局与家的分配

**User Story:** 作为玩家，我希望第一次打开应用时都都和嘟嘟各自住进一扇窗户，都都抱着花盆想送给嘟嘟，这样我一眼就知道要帮它做什么。

#### Acceptance Criteria

1. WHEN Windowfolk_App 启动且 Persistence 未读取到已保存的 Story_Stage，THE Story_Director SHALL 从同时满足以下条件的 Eligible_Window 中，选出水平中心 x 坐标之差最大的两个作为 Home_Window：面积不小于 Min_Window_Size 的平方；当前至少有一段 Window_Ledge。
2. WHEN 第 1 条选出两个 Home_Window，THE Story_Director SHALL 把水平中心 x 坐标较小的窗口分配给 Resident_A，较大的分配给 Resident_B。
3. IF 第 1 条中有多对窗口的水平中心距离并列最大，THEN THE Story_Director SHALL 选择两个窗口前后层级之和最靠前的那一对。
4. WHEN Home_Window 分配完成，THE Story_Director SHALL 把每位居民的 Attachment 设到其 Home_Window 最长一段 Window_Ledge 的水平中点，并把两位居民的 Resident_State 设为 `idle`。
5. WHEN 两位居民放到各自的 Home_Window 上，THE Story_Director SHALL 把第 1 轮 Story_Round 的 Giver 设为 Resident_A、Receiver 设为 Resident_B，并按 Requirement 16 第 1 条开始该轮。
6. IF 第 1 条触发时符合条件的 Eligible_Window 少于两个，THEN THE Story_Director SHALL 把两位居民放在 Ground 上，让它们在 `idle` 和 `walking` 两种 Resident_State 之间切换，且不进入任何 Story_Stage。
7. WHILE 两位居民因第 6 条在 Ground 上活动，WHEN 符合第 1 条条件的 Eligible_Window 达到两个，THE Story_Director SHALL 在同一次世界更新中按第 1 至 5 条完成 Home_Window 分配并开始第 1 轮 Story_Round。
8. IF Windowfolk_App 启动时 Persistence 读取到已保存的 Story_Stage，THEN THE Story_Director SHALL 不执行第 1 条的 Home_Window 分配。
9. THE Story_Director SHALL 只用图标气泡表达居民的想法，气泡中不出现任何文字字符。

### Requirement 16: 送花与种花

**User Story:** 作为玩家，我希望在我连通道路后送花的一方自己把花送到对方那里并一起种下，这样我的操作有明确的结果。

#### Acceptance Criteria

1. WHEN 一轮 Story_Round 开始，THE Story_Director SHALL 让 Giver 持有一个 Growth_Stage 为 `pot` 的 Story_Flower，并把 Story_Stage 设为 `Wish`。
2. WHILE Story_Stage 为 `Wish` 或 `Waiting`，THE Story_Director SHALL 让 Giver 显示「花盆 + Receiver 头像」图标气泡，在 `Waiting` 期间以该气泡代替 Requirement 12 第 10 条的「...」气泡（Giver 位于 Window_Ledge 或 Ground 上时都如此），并在 Story_Stage 变为 `Wish` 和 `Waiting` 之外的阶段时隐藏该气泡。
3. WHEN Story_Stage 变为 `Wish` 且 Nav_Graph 中存在从 Giver 当前所在 Surface 到 Receiver 当前所在 Surface 的路线，THE Story_Director SHALL 在同一帧内把 Story_Stage 设为 `Travel`，并让 Giver 以 Receiver 当前位置为目标沿该路线移动。
4. IF Story_Stage 为 `Wish`，且 Nav_Graph 中不存在从 Giver 当前所在 Surface 到 Receiver 当前所在 Surface 的路线，THEN THE Story_Director SHALL 在同一帧内把 Story_Stage 设为 `Waiting`，Giver 按 Requirement 12 第 10 条或 Requirement 6 第 9 条进入 `waiting` 状态。
5. WHILE Story_Stage 为 `Waiting`，THE Story_Director SHALL 每帧检查从 Giver 到 Receiver 当前所在 Surface 的路线，并在路线出现的同一帧把 Story_Stage 设为 `Travel`，让 Giver 以 Receiver 当前位置为目标移动。
6. WHILE Story_Stage 为 `Travel`，THE Story_Director SHALL 每帧把 Giver 的目标更新为 Receiver 当前的屏幕 x 坐标和所在 Surface。
7. IF Story_Stage 为 `Travel`，Giver 不处于 `falling` 或 `hanging` 状态，且按 Requirement 12 第 9 条重新规划后 Nav_Graph 中仍没有从 Giver 到 Receiver 当前所在 Surface 的路线，THEN THE Story_Director SHALL 在同一帧内把 Story_Stage 设为 `Waiting`。
8. WHILE Story_Stage 为 `Wish`、`Waiting` 或 `Travel`，THE Receiver SHALL 只在其当前所在的 Surface 范围内以 `idle` 或 `walking` 状态活动，不经过 Nav_Graph 的任何边离开该 Surface。
9. WHEN Story_Stage 为 `Travel`，Giver 与 Receiver 站在同一条 Surface 上，Giver 不处于 `falling`、`hanging` 或 `climbing` 状态，且两者屏幕 x 坐标之差的绝对值不超过 Gift_Reach_Distance，THE Story_Director SHALL 在同一帧内把 Story_Stage 设为 `Planting`，把两位居民的 Resident_State 设为 `planting` 并停止移动。
10. WHEN Story_Stage 变为 `Planting`，THE Story_Director SHALL 让两位居民同时播放时长为 Plant_Animation_Duration 的「一起蹲下再跳一下」种花动画。
11. WHEN 种花动画结束，THE Story_Director SHALL 解除 Giver 对 Story_Flower 的持有，并把 Story_Flower 附着在 Receiver 当前所在的 Surface（Window_Ledge、Plank 或 Ground）上 Receiver 当前的屏幕 x 坐标处，Story_Flower 的 Growth_Stage 保持 `pot`。
12. WHEN Story_Flower 在种花动画结束时完成附着，THE Story_Director SHALL 把 Story_Clock 当前时间记录为该 Story_Flower 的种下时间，把 Story_Stage 设为 `Growing`，并让两位居民显示心形气泡。
13. IF Story_Stage 为 `Planting` 期间 Giver 或 Receiver 进入 `hanging` 或 `falling` 状态，THEN THE Story_Director SHALL 立即中止种花动画，不记录种下时间，让 Giver 继续持有 Growth_Stage 为 `pot` 的 Story_Flower，并把 Story_Stage 设回 `Travel`。
14. WHILE Story_Stage 为 `Planting` 且 Giver 或 Receiver 所在窗口是 Hidden_Window，THE Story_Director SHALL 暂停种花动画计时，并在该窗口重新显示后从暂停处继续。

### Requirement 17: 花的生长

**User Story:** 作为玩家，我希望种下的花过一会儿会长大开花，这样世界会因为我的帮助留下变化。

#### Acceptance Criteria

1. THE Story_Director SHALL 以每朵 Story_Flower 种下时刻的 Story_Clock 读数为起点计算已生长时长：已生长时长小于 Bloom_Duration × 0.5 时 Growth_Stage 为 `pot`；大于或等于 Bloom_Duration × 0.5 且小于 Bloom_Duration 时为 `sprout`；大于或等于 Bloom_Duration 时为 `bloom`。
2. WHEN 当前轮次 Story_Flower 的 Growth_Stage 变为 `bloom`，且此时 Story_Stage 为 `Growing`，THE Story_Director SHALL 把 Story_Stage 设为 `Bloomed`，每个 Story_Round 只设置一次。
3. WHILE Story_Flower 位于 Ground 上、可见窗口的 Window_Ledge 上、Plank 上或 Hidden_Window 的 Window_Ledge 上，THE Story_Director SHALL 按第 1 条继续计算该 Story_Flower 的 Growth_Stage，不暂停也不重置已生长时长。
4. FOR ALL Story_Clock 读数序列，Story_Flower 的 Growth_Stage SHALL 只按 `pot` → `sprout` → `bloom` 的顺序前进而不回退；即使 Story_Clock 读数比上一次更早，THE Story_Director SHALL 保留已达到的 Growth_Stage（单调性）。
5. WHEN 玩家在 Debug_Menu 中选择「快进」且 Story_Stage 为 `Growing`，THE Story_Clock SHALL 让当前轮次 Story_Flower 立即进入下一个 Growth_Stage（`pot` 变为 `sprout`，`sprout` 变为 `bloom`），之后从该阶段的起始时长继续计时，不跳过阶段。
6. WHEN 玩家在 Debug_Menu 中选择「快进」且 Story_Stage 为 `Done`，THE Story_Clock SHALL 让 Round_Interval 的等待立即结束，Story_Director 随即按 Requirement 19 第 1 条开始下一轮 Story_Round。
7. IF 玩家在 Debug_Menu 中选择「快进」时 Story_Stage 既不是 `Growing` 也不是 `Done`，THEN THE Story_Clock SHALL 不改变任何 Story_Flower 的 Growth_Stage 和 Story_Stage。
8. WHEN 任一 Story_Flower 的 Growth_Stage 发生变化，THE Overlay SHALL 在 1 秒内把该 Story_Flower 的图形换成新 Growth_Stage 对应的 Asset_Provider 图形。

### Requirement 18: 回赠果子

**User Story:** 作为玩家，我希望花开之后收花的一方回赠一颗果子，这样每一轮故事都有一个温暖的结尾。

#### Acceptance Criteria

1. WHEN Story_Stage 变为 `Bloomed`，THE Story_Director SHALL 在同一次世界更新中让 Receiver 持有一个新的 Fruit，并把 Story_Stage 设为 `ReturnGift`。
2. WHEN Story_Stage 变为 `ReturnGift`，THE Story_Director SHALL 让 Receiver 以 Giver 当前所在的 Surface 和水平位置为目标开始移动。
3. WHILE Story_Stage 为 `ReturnGift`，THE Giver SHALL 只在其所在的 Surface 上活动，不经过 Nav_Graph 的任何边离开该 Surface。
4. WHILE Story_Stage 为 `ReturnGift`，THE Receiver SHALL 使用与 `Travel` 阶段相同的寻路、等待、搬运和掉落规则，以 Fruit 替代 Story_Flower 作为被搬运的 Item。
5. WHILE Story_Stage 为 `ReturnGift`，THE Story_Director SHALL 每帧把 Receiver 的目标更新为 Giver 当前的屏幕 x 坐标和所在 Surface，Story_Stage 保持 `ReturnGift`。
6. IF Story_Stage 为 `ReturnGift` 且 Receiver 在搬运途中掉落，THEN THE Receiver SHALL 在落地后继续持有同一个 Fruit，并从落点重新寻路前往 Giver。
7. WHEN Story_Stage 为 `ReturnGift` 且 Receiver 与 Giver 位于同一 Surface、两者屏幕 x 坐标之差的绝对值不超过 Gift_Reach_Distance，THE Story_Director SHALL 解除 Receiver 对 Fruit 的持有，并把 Fruit 附着在 Giver 所在 Surface 上 Giver 的屏幕 x 坐标处。
8. WHEN Fruit 被放到 Giver 所在 Surface 上，THE Story_Director SHALL 把 Story_Stage 设为 `Done`，并让两位居民进入 `celebrating` 状态，各自完整播放一次 `celebrating` 动画后转为 `idle`。
9. WHILE Story_Stage 为 `Done`，THE Resident_A 和 Resident_B SHALL 只在各自当前所在的 Surface 上活动，在 `idle` 和 `walking` 两种状态之间切换，不经过 Nav_Graph 的任何边离开该 Surface。

### Requirement 19: 轮流循环

**User Story:** 作为玩家，我希望一轮结束后都都和嘟嘟会轮流再送花，这样桌面上的花和果子会一点点积累。

#### Acceptance Criteria

1. WHEN Story_Stage 进入 `Done` 后经过的时长达到 Round_Interval，THE Story_Director SHALL 在之后 1 秒内开始下一轮 Story_Round：轮次编号加 1，并按 Requirement 16 第 1 条开始该轮。
2. WHEN 新一轮 Story_Round 开始，THE Story_Director SHALL 把上一轮的 Giver 设为本轮 Receiver，把上一轮的 Receiver 设为本轮 Giver。
3. WHEN 新一轮 Story_Round 开始，THE Story_Director SHALL 保留之前各轮的全部 Story_Flower 和 Fruit，它们的数量、Attachment 和 Growth_Stage 都与新一轮开始前一刻相同。
4. IF 新的 Story_Flower 种下后场上 Story_Flower 数量超过 Max_Story_Flowers，THEN THE Story_Director SHALL 移除种下时间最早的一朵 Story_Flower，使场上 Story_Flower 数量等于 Max_Story_Flowers；被移除的花从 Overlay 上消失，也不出现在之后的 Persistence 保存中；其余 Story_Flower 和全部 Fruit 不受影响。
5. FOR ALL 轮次编号 n（n ≥ 1），THE Story_Director SHALL 使第 n 轮的 Giver 在 n 为奇数时为 Resident_A、在 n 为偶数时为 Resident_B（轮换不变量）。
6. WHEN Windowfolk_App 启动并由 Persistence 读取到已保存的轮次编号，THE Story_Director SHALL 恢复该轮次编号，并按第 5 条确定本轮的 Giver 和 Receiver。
7. IF Windowfolk_App 启动时恢复出的 Story_Stage 为 `Done`，THEN THE Story_Director SHALL 按 Requirement 22 第 10 条，根据保存的进入 `Done` 时间计算下一轮开始时刻；该时刻已过时，在恢复完成后 1 秒内按第 1 条开始下一轮。

### Requirement 20: 剧情的中断与继续

**User Story:** 作为玩家，我希望剧情不会因为我挪动或关闭窗口而卡死，这样任何时候都能把故事接着走完。

#### Acceptance Criteria

1. WHEN Story_Stage 为 `Travel` 或 `ReturnGift` 且持有 Story_Flower 或 Fruit 的居民进入 `hanging` 或 `falling` 状态，THE Story_Director SHALL 在 `hanging` 和 `falling` 全过程中保持当前 Story_Stage 不变，并保持该居民持有的 Item 不变。
2. WHEN 第 1 条中的居民落到某条 Surface 上，THE Story_Director SHALL 在落地后的下一帧以对方居民的当前位置为目标重新规划路线；IF 此时不存在路线，THEN Story_Stage 为 `Travel` 时按 Requirement 16 第 7 条处理，Story_Stage 为 `ReturnGift` 时保持 `ReturnGift`，居民按 Requirement 12 第 10 条或 Requirement 6 第 9 条等待。
3. WHEN 某个 Home_Window 成为 Closed_Window，THE Story_Director SHALL 保持当前 Story_Stage 不变，并继续用 Story_Clock 为已种下的 Story_Flower 计时；附着在该窗口上的居民和物件按 Requirement 5 第 1 条下落。
4. WHILE Story_Stage 为 `Travel` 或 `ReturnGift`，THE Story_Director SHALL 每帧用对方居民的当前位置更新送达目标，对方居民位于 Window_Ledge、Plank 或 Ground 上时都照此更新。
5. IF Story_Stage 为 `Planting` 时任一位居民进入 `hanging` 或 `falling` 状态，THEN THE Story_Director SHALL 按 Requirement 16 第 13 条处理。
6. WHEN 玩家在 Debug_Menu 中选择「重新开始剧情」，THE Story_Director SHALL 清除场上全部 Story_Flower 和 Fruit（包括窗沿上、Ground 上和居民持有的），保留所有 Plank 和 Ladder 及其位置，把 Story_Round 编号重置为 1，并按当前 Eligible_Window 执行 Requirement 15 第 1 至 7 条重新开局；在任一 Story_Stage 下选择该项结果都相同。

### Requirement 21: 事件记录

**User Story:** 作为开发者，我希望关键事件写成结构化记录，这样以后可以直接接入日记或小心思功能。

#### Acceptance Criteria

1. WHEN 发生 `crossed_bridge`、`climbed_ladder`、`fell`、`landed`、`waiting_started`、`round_started`、`planted`、`sprouted`、`bloomed`、`gift_delivered`、`plank_placed`、`plank_dropped`、`ladder_placed`、`ladder_dropped` 中任一事件，THE Event_Log SHALL 为该次事件向 `events.jsonl` 末尾追加恰好一行 JSON 记录，行尾为单个换行符；上述列表之外的事件不写入。
2. THE Event_Log SHALL 以追加方式写入 `events.jsonl`，保留文件中已有的全部行，多条记录的行顺序与事件发生顺序一致。
3. THE Event_Log SHALL 在每行记录中包含且仅包含 `time`、`type`、`actor`、`target`、`detail` 五个字段。
4. THE Event_Log SHALL 将 `time` 写为带时区偏移、精确到秒的 ISO 8601 时间字符串。
5. THE Event_Log SHALL 将 `type` 写为第 1 条所列事件名之一，与触发事件一致。
6. THE Event_Log SHALL 将 `actor` 写为发起事件的一方（Resident_A、Resident_B 或玩家）的标识；没有发起方的事件（如 `sprouted`、`bloomed`、`round_started`）中 `actor` 值为 JSON `null`。
7. THE Event_Log SHALL 将 `target` 写为事件作用对象的标识（如 Receiver、窗口所属应用、Plank、Ladder 或 Item），没有作用对象时值为 JSON `null`；`detail` 为 JSON 对象，没有附加信息时为空对象。
8. THE Event_Log SHALL 在涉及窗口的记录中只写入该窗口所属应用的名称，任何字段都不写入窗口标题。
9. FOR ALL 合法的事件记录，THE Event_Log 以 UTF-8 编码为一行 JSON 后再解码 SHALL 得到与原记录相等的值，包括应用名称含非 ASCII 字符、引号或换行符的情况（往返属性）。
10. IF 写入时 `~/Library/Application Support/Windowfolk/` 目录或 `events.jsonl` 文件不存在，THEN THE Event_Log SHALL 先创建缺失的目录和文件，再写入该条记录。
11. IF 写入 `events.jsonl` 失败（包括目录无法创建、文件无写权限或磁盘已满），THEN THE Event_Log SHALL 丢弃该条记录且不重试、不弹出提示，Windowfolk_App 继续运行，世界状态与写入成功时相同；之后的事件照常尝试写入。
12. THE Windowfolk_App SHALL 在 v1 中只写入 `events.jsonl` 而不读取，其内容不影响任何世界状态或剧情行为。

### Requirement 22: 保存与恢复

**User Story:** 作为玩家，我希望退出再打开后花和剧情进度还在，这样我的帮助不会白费。

#### Acceptance Criteria

1. WHEN 玩家通过 Status_Menu 的「退出」项退出 Windowfolk_App，THE Persistence SHALL 在进程结束前完成一次对 `world.json` 的完整写入。
2. WHILE Windowfolk_App 运行，WHEN 距上次成功保存已满 Autosave_Interval，THE Persistence SHALL 把当前世界状态写入 `world.json`。
3. THE Persistence SHALL 在每次写入的 `world.json` 中包含：格式版本号；所有 Ground_Object 的类型、屏幕 x 坐标和状态；当前 Story_Stage（未开局时为空）；当前 Story_Round 编号；每朵 Story_Flower 的 Growth_Stage 与种下时间；最近一次进入 `Done` 的时间；每位 Resident 的屏幕 x 坐标及其当前持有的 Item（无则为空）。
4. WHEN Persistence 保存世界状态，THE Persistence SHALL 把所有附着在窗沿或 Plank 上的 Item、以及所有 Plank 和 Ladder 记录为 Ground_Object，x 坐标取保存时刻的屏幕 x 坐标（Plank 取两端中点，Ladder 取下端；附着在 Hidden_Window 上的物件取该窗口最后一次可见时的屏幕 x 坐标）；被 Resident 持有的 Item 不记录为 Ground_Object。
5. IF 写入 `world.json` 失败，THEN THE Persistence SHALL 保持磁盘上已有的 `world.json` 内容不变（不留下写了一半的文件），并在下一个 Autosave_Interval 到达时重试。
6. WHEN Windowfolk_App 启动且 `world.json` 存在并解析成功，THE Windowfolk_App SHALL 让每个保存的 Ground_Object 从主显示器上沿上方落到 Ground 上保存的 x 坐标处；保存的 x 超出当前主显示器宽度时，落点限制在屏幕宽度范围内。
7. WHEN Windowfolk_App 启动且 `world.json` 存在并解析成功，THE Windowfolk_App SHALL 让每位 Resident 从主显示器上沿上方落到与其保存 x 坐标水平距离最近的 Window_Ledge 上；IF 启动时不存在任何 Window_Ledge，THEN THE Windowfolk_App SHALL 让该 Resident 落到 Ground 上保存的 x 坐标处。
8. IF 保存时某位 Resident 持有 Item，THEN THE Windowfolk_App SHALL 在启动后让该 Resident 落位时仍持有同一个 Item，且该 Item 不作为 Ground_Object 出现。
9. WHEN Windowfolk_App 启动且读取到 Story_Stage，THE Story_Director SHALL 从保存的 Story_Stage 和 Story_Round 编号继续剧情，Giver 与 Receiver 的分配按 Requirement 19 第 5 条与该轮次编号一致。
10. WHEN Windowfolk_App 启动且读取到 Story_Flower，THE Windowfolk_App SHALL 根据保存的种下时间、Story_Clock 当前时间和 Bloom_Duration 按 Requirement 17 第 1 条重新计算每朵 Story_Flower 的 Growth_Stage（应用未运行期间花照常生长）；Story_Stage 为 `Done` 时，根据保存的进入 `Done` 时间和 Round_Interval 计算下一轮的开始时刻。
11. IF Windowfolk_App 启动时 `world.json` 不存在，THEN THE Windowfolk_App SHALL 按 Requirement 15 首次开局，Story_Round 编号为 1，Ground 上没有 Ground_Object。
12. IF `world.json` 无法解析或其格式版本号与当前版本不一致，THEN THE Persistence SHALL 把原文件重命名为文件名带时间戳的备份文件，并按第 11 条开局。
13. FOR ALL 合法的世界状态，THE Persistence 先保存再读取 SHALL 得到与保存前相等的世界状态（往返属性）。

### Requirement 23: 全屏、睡眠与显示变化

**User Story:** 作为玩家，我希望看视频或开会全屏时世界自动隐藏，电脑睡眠或改分辨率后世界自动恢复。

#### Acceptance Criteria

1. WHEN 前台应用在主显示器上进入全屏状态（该应用窗口位于 macOS 全屏桌面空间，或其边界矩形等于主显示器完整 frame），THE Overlay SHALL 在 1 秒内隐藏全部居民、物件和 Toolbox。
2. WHILE 前台应用在主显示器上处于全屏状态，THE Overlay SHALL 不显示任何居民、物件和 Toolbox，且不拦截任何鼠标事件。
3. WHILE 前台应用在主显示器上处于全屏状态，THE Windowfolk_App SHALL 保留世界状态中的全部居民、Item、Plank 和 Ladder，不删除或重置其中任何一个。
4. WHEN 前台应用在主显示器上退出全屏状态，或前台切换为非全屏应用，THE Overlay SHALL 在 1 秒内重新显示全部居民、物件和 Toolbox。
5. WHEN 系统从睡眠中唤醒，THE Windowfolk_App SHALL 在 2 秒内按当时的主显示器尺寸重建 Overlay 和全部 Surface。
6. WHEN 主显示器分辨率或 `visibleFrame` 改变，THE Windowfolk_App SHALL 在 2 秒内重建 Overlay，使其覆盖新的主显示器全部区域，并按新的 `visibleFrame` 重新计算 Ground 和全部 Window_Ledge。
7. WHEN 第 5 或第 6 条的重建完成，THE Windowfolk_App SHALL 让附着在窗口上的居民和物件按原 Attachment 偏移量出现在对应窗口上沿；对应 Window_Ledge 已不存在时按 Requirement 4 第 6、7 条处理。
8. IF 重建后某个附着在 Ground 上的居民或 Ground_Object 的屏幕 x 坐标超出新的 Ground 范围，THEN THE Windowfolk_App SHALL 把它移到 Ground 上离原 x 坐标最近、且完整位于屏幕内的位置。

### Requirement 24: 轮询频率

**User Story:** 作为玩家，我希望应用在桌面静止时少占资源，这样它可以一直开着。

#### Acceptance Criteria

1. WHEN Windowfolk_App 启动，THE Game_Loop SHALL 以 Active_Poll_Rate 开始轮询窗口。
2. WHILE 连续 2 秒内同时满足以下三项，THE Game_Loop SHALL 以 Idle_Poll_Rate 轮询窗口（任意连续 1 秒内的轮询次数在 Idle_Poll_Rate ±1 次以内）：每次 Window_Snapshot 与上一次相比，Eligible_Window 集合、各窗口的边界矩形和前后层级都没有变化；每位 Resident 的 Resident_State 和屏幕位置都没有变化；没有进行中的玩家拖拽。
3. WHEN 某次轮询得到的 Window_Snapshot 与上一次相比，Eligible_Window 集合、任一窗口的边界矩形或前后层级发生变化，THE Game_Loop SHALL 从紧接着的下一次轮询起切换到 Active_Poll_Rate。
4. WHEN 任一 Resident 的 Resident_State 变为 `walking`、`carrying`、`falling`、`hanging` 或 `climbing`，THE Game_Loop SHALL 从紧接着的下一次轮询起切换到 Active_Poll_Rate。
5. WHEN 玩家在 Overlay 中按下鼠标开始拖拽 Plank、Ladder 或 Item（包括从 Toolbox 中拖出），THE Game_Loop SHALL 从紧接着的下一次轮询起切换到 Active_Poll_Rate。
6. WHILE 玩家拖拽进行中（从按下鼠标到松开鼠标），THE Game_Loop SHALL 保持 Active_Poll_Rate，即使鼠标静止超过 2 秒也不切换到 Idle_Poll_Rate。

### Requirement 25: 素材替换接口

**User Story:** 作为美术制作者，我希望有明确的素材规格，放入 PNG 就能替换占位图形，这样美术可以独立于代码推进。

#### Acceptance Criteria

1. THE Asset_Provider SHALL 为 Resident_A 生成银灰色、带猫耳的圆角方块占位图形，为 Resident_B 生成金黄色、带圆耳的圆角方块占位图形。
2. THE Asset_Provider SHALL 为两位居民的全部 9 个 Resident_State 各提供一个图形，并为 Flower 的每个 Growth_Stage、Fruit、Plank、Ladder、Toolbox 和每种气泡图标各提供一个图形，任何一项都不缺图。
3. THE Asset_Provider SHALL 让每个占位图形的尺寸与 `docs/art-spec.md` 中该角色或物件的规定尺寸一致，使替换 PNG 后 Overlay 中的显示尺寸和位置不变。
4. WHEN Windowfolk_App 启动，THE Asset_Provider SHALL 在 Overlay 首次渲染前扫描 `docs/art-spec.md` 指定的素材目录，对每个文件名符合命名规则、能解码、像素尺寸和帧数符合规格的 PNG，用它替代对应的占位图形。
5. IF 某个素材 PNG 缺失、无法解码、像素尺寸与规格不一致，或 sprite sheet 帧数与规格不一致，THEN THE Asset_Provider SHALL 只让对应的那一项使用占位图形，其他已加载的 PNG 继续使用，Windowfolk_App 继续正常运行且不弹出错误提示。
6. IF 素材目录不存在或其中没有符合命名规则的 PNG，THEN THE Asset_Provider SHALL 全部使用占位图形，Windowfolk_App 正常启动。
7. THE Windowfolk_App 的仓库 SHALL 包含 `docs/art-spec.md`，写明两位居民的角色设定（都都：圆脸银渐层小猫；嘟嘟：金丝熊）、每个角色和物件的像素尺寸、每个 Resident_State 的帧数、素材目录位置、文件命名规则、透明背景要求、sprite sheet 格式（帧的排列方向和每帧尺寸），以及用 gpt-image-2.5 生成时保持角色一致的注意事项。
8. THE `docs/art-spec.md` SHALL 为第 2 条列出的每一项图形写明一个对应的文件名，不能遗漏。

### Requirement 26: 调试菜单

**User Story:** 作为开发者和演示录制者，我希望有调试工具快速复现场景，这样录视频不用等待。

#### Acceptance Criteria

1. THE Debug_Menu SHALL 按顺序提供「让都都去找嘟嘟」「给都都一个花盆」「快进」「重新开始剧情」四项，四项在任意 Story_Stage 下均可选择。
2. WHEN 玩家选择「让都都去找嘟嘟」且 Nav_Graph 中存在从 Resident_A 所在 Surface 到 Resident_B 所在 Surface 的路线，THE Resident_A SHALL 在 1 秒内以 Resident_B 当前位置为目标开始移动，Story_Stage 保持不变。
3. IF 玩家选择「让都都去找嘟嘟」时不存在该路线，THEN THE Resident_A SHALL 按 Requirement 12 第 10 条或 Requirement 6 第 9 条等待，并在路线出现后 1 秒内以 Resident_B 当前位置为目标开始移动。
4. WHEN 玩家选择「给都都一个花盆」且 Resident_A 未持有 Item，THE Resident_A SHALL 在 1 秒内持有一个 Growth_Stage 为 `pot` 的 Flower，Story_Stage 保持不变。
5. IF 玩家选择「给都都一个花盆」时 Resident_A 已持有 Item，THEN THE Windowfolk_App SHALL 保持 Resident_A 当前持有的 Item 不变，且不新建 Flower。
6. WHEN 玩家选择「快进」，THE Story_Director SHALL 按 Requirement 17 第 5 至 7 条处理。
7. WHEN 玩家选择「重新开始剧情」，THE Story_Director SHALL 按 Requirement 20 第 6 条处理。

### Requirement 27: 可测试的核心模块

**User Story:** 作为开发者，我希望地形、寻路、剧情和存档逻辑脱离 AppKit 独立测试，这样改动可以通过 `swift test` 快速验证。

#### Acceptance Criteria

1. THE Windowfolk_App SHALL 把 Surface_Builder、Nav_Graph、Resident 状态机、Item、Plank、Ladder、Story_Director、Story_Clock、Event_Log、Persistence 以及 Window_Source 的接口定义放在 `WindowfolkCore` 库中。
2. THE `WindowfolkCore` SHALL 不导入 AppKit 和 SpriteKit：其源文件中没有 `import AppKit` 或 `import SpriteKit` 语句，且 `WindowfolkCore` 及其测试目标构建时不链接这两个框架。
3. THE `WindowfolkCore` SHALL 提供 `FakeWindowSource`，它实现与真实 Window_Source 相同的接口，可在测试中构造含 0 到 50 个 Window_Snapshot 的任意窗口布局，每个快照的窗口 ID、所属应用名称、边界矩形和前后层级都可任意指定。
4. WHEN 测试代码通过 `FakeWindowSource` 执行移动、缩放、调整前后层级、关闭、隐藏或恢复显示操作，THE `FakeWindowSource` SHALL 在下一次被读取时输出反映该操作的 Window_Snapshot 列表和窗口 ID 集合。
5. THE `WindowfolkCore` SHALL 允许测试注入可手动推进的 Story_Clock，使测试推进 Bloom_Duration、Round_Interval、Hang_Duration 和 Plant_Animation_Duration 时不需要实际等待。
6. THE `WindowfolkCore` SHALL 允许测试为 Event_Log 和 Persistence 指定其他存储位置，使 `swift test` 不读取、不修改 `~/Library/Application Support/Windowfolk/` 下的文件。
7. THE `WindowfolkCore` 的测试目标 SHALL 为 Surface_Builder、Nav_Graph、Resident 状态机、Story_Director、Event_Log 和 Persistence 各包含至少 1 个测试用例。
8. WHEN 开发者在项目根目录运行 `swift build`，THE 构建 SHALL 以退出码 0 完成。
9. WHEN 开发者在项目根目录运行 `swift test`，THE 测试运行 SHALL 以退出码 0 完成，全部测试通过，总耗时不超过 60 秒，且过程中不需要屏幕录制或辅助功能权限，也不创建 Overlay 或任何屏幕窗口。

### Requirement 28: 打包与演示验收

**User Story:** 作为参赛者，我希望能打包成 `.app` 并按脚本稳定录完演示视频，这样作品可以提交比赛。

#### Acceptance Criteria

1. WHEN 开发者在仓库根目录运行 `build-app.sh`，THE 构建脚本 SHALL 在无需额外输入的情况下以退出码 0 结束，并生成 `Windowfolk.app`。
2. IF `build-app.sh` 的任一构建步骤失败，THEN THE 构建脚本 SHALL 以非零退出码结束，并在终端输出说明失败步骤的错误信息。
3. WHEN 用户在 Finder 中双击 `Windowfolk.app`，THE Windowfolk_App SHALL 在 5 秒内在菜单栏显示图标，并按 Requirement 1 创建 Overlay。
4. THE Windowfolk_App 的仓库 SHALL 包含 `docs/demo-script.md`，写明录制时需要打开的窗口数量和所属应用、每个窗口的大致位置与尺寸、哪个窗口会被分配为都都和嘟嘟的 Home_Window，以及第 6 条流程每一步对应的玩家操作。
5. THE Windowfolk_App 的仓库 SHALL 在 README 中说明运行 `build-app.sh` 的命令、`Windowfolk.app` 的启动方法，以及 `docs/demo-script.md` 的位置。
6. WHEN 演示者从全新世界状态（不存在 `world.json`）启动 Windowfolk_App 并按 `docs/demo-script.md` 操作，THE Windowfolk_App SHALL 在只使用 Debug_Menu「快进」一项的情况下一次完成以下全部流程，过程中不崩溃、不退出、不需要重启，演示者也不手动修改世界状态：
   - 都都抱着花盆许愿，因无通路而张望；
   - 玩家拉近窗口并架设 Plank，都都开始过桥；
   - 玩家在都都位于 Plank 上时拖开窗口，都都挂在桥边 Hang_Duration 后掉到 Ground，花盆仍被都都持有；
   - 都都在 Ground 上张望，玩家放置 Ladder，都都爬上窗沿并沿新路线把花送到嘟嘟处；
   - 两位居民种花，快进后 Story_Flower 开花；
   - 嘟嘟带着 Fruit 找到都都，Fruit 留在都都所在的 Surface 上，两位居民庆祝。
7. WHEN 演示者连续 3 次独立运行第 6 条流程（每次都从全新世界状态开始），THE Windowfolk_App SHALL 每次都完成第 6 条列出的全部步骤。
8. WHEN 演示者在第 6 条流程的任一 Story_Stage 中途切换到其他桌面空间并在 60 秒内切回，THE Windowfolk_App SHALL 让流程继续完成，且每位居民和每个 Item 相对其所附着窗口左边缘的水平偏移与切换前相差不超过 1pt。
9. WHEN 演示者在第 6 条流程的任一 Story_Stage 中途最小化某个 Home_Window 并在 60 秒内恢复，THE Windowfolk_App SHALL 让流程继续完成，且附着在该窗口上的每位居民和每个 Item 相对窗口左边缘的水平偏移与最小化前相差不超过 1pt。

### Requirement 29: 性能与稳定性

**User Story:** 作为玩家，我希望应用长时间开着也不拖慢电脑、不出故障，这样它能成为桌面的日常陪伴。

#### Acceptance Criteria

1. WHILE 桌面处于静止状态（连续 60 秒内：所有 Eligible_Window 的边界矩形与前后层级均无变化，所有 Resident 均处于 `idle` 或 `waiting` 状态且位置不变，玩家没有拖拽，Story_Flower 的 Growth_Stage 不变，「显示路面」开关关闭），THE Windowfolk_App SHALL 在 Apple Silicon Mac 上保持 60 秒平均 CPU 占用不超过 Idle_CPU_Budget（按单核百分比计，取「活动监视器」中 Windowfolk_App 进程「% CPU」列在这 60 秒内的平均读数）。
2. WHILE 桌面处于第 1 条定义的静止状态，THE Game_Loop SHALL 以不高于 Idle_Poll_Rate 的频率轮询窗口列表。
3. WHEN Windowfolk_App 从启动起连续运行 2 小时，期间玩家至少移动窗口 20 次、关闭窗口 5 次、最小化并恢复窗口 5 次、切换桌面空间 2 次，并至少完成 1 个 Story_Round，THE Windowfolk_App SHALL 在整个 2 小时内保持进程运行，不崩溃也不被系统终止。
4. WHEN 第 3 条所述的 2 小时运行结束，THE Windowfolk_App SHALL 在玩家点击菜单栏图标后 1 秒内弹出 Status_Menu，且玩家移动某 Resident 所在窗口后 1 秒内该 Resident 随窗口一起移动。
5. WHILE Windowfolk_App 运行，THE Windowfolk_App SHALL 在每次世界更新结束时满足无悬空不变量：每个不处于 `falling` 或 `hanging` 状态的 Resident 和 Item 满足以下之一：(a) 底边与某条 Surface 的竖直距离不超过 1pt，且水平中心点落在该 Surface 的线段范围内；(b) 该 Resident 处于 `climbing` 状态且位于某架已架设的 Ladder 上；(c) 该 Item 由某个 Resident 持有；(d) 其 Attachment 指向一个 Hidden_Window。
6. IF 某个不处于 `falling` 或 `hanging` 状态的 Resident 或 Item 在世界更新中失去第 5 条所述的支撑（例如所在窗口被关闭、被移出主显示器，或其所在 Window_Ledge 被前方窗口完全遮住），THEN THE Windowfolk_App SHALL 在同一次世界更新中把该 Resident 设为 `falling` 状态，或让该 Item 开始下落。
