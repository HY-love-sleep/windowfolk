# Requirements Document

## Introduction

窗间 · Windowfolk V2 在 v1「送花过桥」的基础上加入更自由的玩法。v1 只有一条固定的送花主线；V2 让桌面成为一个开放的小世界，由三部分组成：

- **自由建造与装饰**：工具箱里除了木板和梯子，还会出现椅子、台灯等装饰物。玩家可以把装饰物自由摆放到任意窗沿或地面，也可以拖回工具箱收起。居民会使用这些装饰物。
- **居民自主生活**：都都和嘟嘟按自己的意愿散步、回家、拜访邻居、坐椅子、赏花、在夜里睡觉，不再只等剧情推动。
- **开放式心愿**：居民会不定时冒出小心愿（送花给邻居、想要一把椅子、夜里想要一盏灯、想去某扇窗看看、想玩一场追逐）。玩家自己决定帮不帮、先帮哪个，没有固定顺序，不帮也没有惩罚。v1 的送花流程成为心愿之一。每种新装饰物都通过一个对应的心愿故事进入工具箱。
- **追逐游戏（猫捉老鼠）**：任一位居民都可能提出想玩追逐，之后都都追、嘟嘟跑，两人以比平时快的速度沿 Nav_Graph 跑动。玩家不用选边，只用已有操作（搭或拆 Plank 和 Ladder、拖动窗口）改变路线：给都都搭路就是帮追，拆路、把窗口挪开就是帮跑。都都抓到嘟嘟，或嘟嘟撑满追逐时长，两种结局都算心愿完成，两人一起庆祝，不计分、不显示倒计时、不分输赢（本文 Requirement 20 至 22）。

V2 还加入可选的 LLM 能力：根据事件记录生成居民日记，以及让居民偶尔冒出一句文字「小心思」。LLM 默认关闭；不配置 LLM 时，日记用模板生成，小心思不出现，其余玩法完全可用。

**与 v1 的关系**：除本文件明确修改或取代的条款外，`.kiro/specs/v1/requirements.md` 的全部需求在 V2 中继续有效（下文用「v1 R12.13」表示 v1 Requirement 12 第 13 条）。V2 取代或修改的 v1 条款：

- v1 R15（剧情开局）：Home_Window 分配规则保留，开局后不再直接开始送花，改由 Wish_Director 调度（本文 Requirement 6）。
- v1 R16 至 R19（送花、生长、回赠、轮流）：作为 Flower_Wish 的内部流程保留，触发与轮换方式改为本文 Requirement 8。
- v1 R15.9（气泡不出现文字）：仅对 Thought 放宽（本文 Requirement 14）。
- v1 R21.12（事件记录只写不读）：改为 Diary_Writer 可读取（本文 Requirement 13）。
- v1 R22（保存与恢复）：存档内容扩充、格式版本号升为 2（本文 Requirement 15）。
- v1 R25、R26（素材、调试菜单）：图形清单与菜单项扩充（本文 Requirement 16、17）。

**兼容性**：作品完成前处于开发迭代阶段，V2 不兼容 v1 存档。读到 v1 格式的 `world.json` 时沿用 v1 R22.12 的规则：备份原文件后重新开局。

**V2 不做、留作以后的创意**：

- 更多居民（通过小屋或达成条件迎来新居民）。
- 新的通路工具：绳索/滑索、弹簧、电梯。
- 更多装饰物（秋千、小屋、书架等），每种都要配一个心愿故事。
- 窗沿上装饰物的原位持久化。
- 多显示器支持。
- 追逐玩法的扩展：角色轮换（嘟嘟追都都）、逃者主动从窗沿跳下甩开追者、Decor 影响追逐路线、玩家先选边再帮忙、追逐中直接拖动居民。

## Glossary

V2 沿用 v1 Glossary 中的全部术语（Windowfolk_App、Overlay、Window_Source、Eligible_Window、Surface、Window_Ledge、Ground、Attachment、Closed_Window、Hidden_Window、Resident、Resident_A、Resident_B、Item、Ground_Object、Toolbox、Plank、Ladder、Nav_Graph、Story_Director、Home_Window、Growth_Stage、Story_Clock、Event_Log、Persistence、Asset_Provider、Game_Loop、Status_Menu、Debug_Menu、Tunable_Constant 等），并新增或修改以下术语：

- **Resident_State**（修改）：在 v1 的 9 个取值之外新增 `sitting`（坐在椅子上）、`sleeping`（睡觉）和 `running`（追逐中沿 Surface 水平跑动），共 12 个取值。
- **Decor**：装饰物。玩家从 Toolbox 拖出、摆放在 Window_Ledge、Plank 或 Ground 上的物件，居民不能持有或搬运。V2 包括 Chair 和 Lamp 两种。
- **Chair**：椅子，一种 Decor，同一时刻最多供 1 位居民坐。
- **Lamp**：台灯，一种 Decor，Night 期间发光，居民在其附近睡觉。
- **Decor_Type**：Decor 的种类，V2 取值为 `chair`、`lamp`。
- **Unlocked_Decor**：已解锁的 Decor_Type 集合。只有已解锁的 Decor_Type 出现在 Toolbox 中。
- **Decor_Slot**：Toolbox 中某个已解锁 Decor_Type 的取物区。
- **Activity**：居民在没有进行中的心愿行动时，自主选择的一项日常活动。取值为 `wander`（在当前 Surface 上散步）、`go_home`（回到自己的 Home_Window）、`visit_neighbor`（去找另一位居民）、`rest`（去坐一把 Chair）、`admire_flower`（去看一朵 Growth_Stage 为 `bloom` 的 Story_Flower）、`sleep`（在 Lamp 旁睡觉）。
- **Activity_Planner**：为每位居民选择和推进 Activity 的组件。
- **Wish**：一位或两位居民提出、等待玩家帮助完成的心愿。每个 Wish 有类型、提出者（Wisher）、状态和创建时间。
- **Wish_Type**：心愿种类，V2 取值为 `flower`（送花，即 Flower_Wish）、`chair`（想要椅子，即 Chair_Wish）、`lamp`（夜里想要灯，即 Lamp_Wish）、`visit`（想去某扇窗看看，即 Visit_Wish）、`chase`（想玩追逐，即 Chase_Wish）。
- **Wisher**：提出某个 Wish 的居民。Flower_Wish 的 Wisher 是 Giver。
- **Wish_State**：Wish 的状态，取值为 `active`（进行中）、`fulfilled`（已完成）、`dropped`（居民放弃）。
- **Wish_Director**：按条件生成、跟踪、完成和放弃 Wish 的组件，取代 v1 Story_Director 的开局与轮次调度职责；Flower_Wish 内部的送花流程仍由 Story_Director 执行。
- **Busy_Resident**：正在参与一个 `active` Wish 的居民。Flower_Wish 的 Giver 和 Receiver 都是 Busy_Resident；Chase_Wish 的 Chaser 和 Runner 都是 Busy_Resident；其他 Wish 只有 Wisher 是 Busy_Resident。
- **Chaser**：Chase_Wish 中负责追的居民，固定为 Resident_A（都都），与谁是 Wisher 无关。
- **Runner**：Chase_Wish 中负责跑的居民，固定为 Resident_B（嘟嘟），与谁是 Wisher 无关。
- **Chase_Phase**：`active` Chase_Wish 的阶段，取值为 `ready`（准备，两人停下对望）和 `running`（追逐进行中）。
- **Chase_Outcome**：Chase_Wish 的结局，取值为 `caught`（Chaser 抓到了 Runner）和 `escaped`（Runner 撑满 Chase_Duration）。两种结局都使 Chase_Wish 变为 `fulfilled`。
- **Chase_Candidate_Point**：Runner 选择逃跑目标时的候选位置。Runner 当前有 Nav_Graph 路线可达的每条 Surface（含其当前所在 Surface）各提供 2 个候选位置，即该 Surface 线段左右两端各向内收 Flee_Edge_Inset 的点；线段长度不超过 2 × Flee_Edge_Inset 时只提供线段中点 1 个。
- **Flee_Target**：Runner 从 Chase_Candidate_Point 中选出的当前逃跑目标。
- **Wish_Bubble**：Wisher 头顶表示心愿内容的图标气泡。
- **Visit_Target**：Visit_Wish 指定要去看看的窗口，必须是一个不属于任何居民 Home_Window 的 Eligible_Window。
- **Visit_Flag**：Visit_Wish 进行中时画在 Visit_Target 最长一段 Window_Ledge 中点上方的小旗标记。Visit_Flag 只是显示标记，不是 Item 也不是 Decor。
- **Walk_Distance**：居民自上次 `sitting` 或 `sleeping` 结束以来累计走过的水平距离（pt），用于判定是否累了。
- **Local_Clock**：可注入的本地墙钟，提供本地日期和时刻，用于判定 Night 和日记日期；测试中可替换。
- **Night**：Local_Clock 时刻处于 Night_Start 到次日 Night_End 之间（含 Night_Start，不含 Night_End）的时段；或 Debug_Menu 的昼夜覆盖设为「夜晚」时。
- **Day_Night_Override**：Debug_Menu 中的昼夜覆盖，取值为「自动」「白天」「夜晚」，默认「自动」，每次启动恢复为「自动」。正文中简称「昼夜覆盖」。
- **LLM_Settings**：LLM 相关设置：是否启用日记 LLM、是否启用小心思、服务地址、模型名、API Key。
- **LLM_Client**：按 LLM_Settings 向外部 LLM 服务发送请求并返回文本的组件。WindowfolkCore 只定义其接口。
- **Diary_Entry**：某位居民在某个本地日期的一篇日记，包含日期、居民、正文、生成方式（`template` 或 `llm`）。
- **Diary_Writer**：读取某个本地日期的事件记录并生成 Diary_Entry 的组件。
- **Diary_Store**：把 Diary_Entry 以 JSONL 写入 `~/Library/Application Support/Windowfolk/diary.jsonl` 并读取的组件。
- **Diary_Window**：显示 Diary_Entry 的应用自有窗口，从 Status_Menu 打开。
- **Settings_Window**：编辑 LLM_Settings 的应用自有窗口，从 Status_Menu 打开。
- **Thought**：LLM 生成、在居民头顶短暂显示的一句文字气泡。
- **Thought_Engine**：决定何时请求 Thought、并校验和显示 Thought 的组件。
- **Prompt_Payload**：发送给 LLM_Client 的事件摘要。
- **Tunable_Constant**（新增默认值，需试玩后调整）：
  - Wish_Check_Interval：10 秒（Wish_Director 检查是否生成新 Wish 的间隔）
  - Wish_Cooldown：3 分钟（某位居民的 Wish 结束后，到该居民可提出下一个 Wish 的最短间隔）
  - Wish_Timeout：30 分钟（`active` Wish 无人帮助时居民放弃的时长）
  - Wish_Spawn_Chance：0.3（每次检查时，满足条件的居民实际提出 Wish 的概率）
  - Tired_Walk_Distance：2000pt
  - Night_Start：19:00；Night_End：06:00
  - Lamp_Range：80pt（Lamp 与居民的水平距离不超过此值、且位于同一 Surface 时算「在灯旁」）
  - Sit_Duration：20 秒
  - Activity_Min_Duration：15 秒；Activity_Max_Duration：60 秒（`wander` 的持续时长范围）
  - Activity_Reach_Timeout：60 秒（Activity 的目标在此时长内未到达则放弃该 Activity）
  - Visit_Stay_Duration：5 秒（`visit_neighbor` 到达后停留的时长）
  - Max_Decor_Count：20（场上同时存在的 Decor 上限）
  - Toolbox_Return_Distance：24pt（松开 Decor 时，指针与 Toolbox 外接矩形的距离不超过此值算放回 Toolbox）
  - Thought_Min_Interval：10 分钟（两条 Thought 之间的最短间隔，两位居民共用）
  - Thought_Display_Duration：6 秒
  - Thought_Max_Length：24 个字符（按 Unicode 字素计）
  - LLM_Request_Timeout：15 秒
  - Diary_Max_Length：300 个字符（按 Unicode 字素计）
  - Chase_Ready_Duration：2 秒（Chase_Phase `ready` 的时长）
  - Chase_Duration：60 秒（Chase_Phase `running` 的最长时长，到时 Runner 算撑满）
  - Chaser_Speed_Factor：1.6；Runner_Speed_Factor：1.5（`running` 水平速度相对同一居民空手 `walking` 速度的倍数）
  - Catch_Distance：16pt（抓到判定的水平距离）
  - Chase_Replan_Interval：0.5 秒（追逐中重新选择目标和路线的最长间隔）
  - Flee_Edge_Inset：8pt

## Requirements

### Requirement 1: 装饰物的解锁

**User Story:** 作为玩家，我希望新的装饰物随着居民的心愿故事出现，这样每件物件都有来由，世界一点点变丰富。

#### Acceptance Criteria

1. WHEN Windowfolk_App 以全新世界状态开局（不存在 `world.json`，或按 v1 R22.12 的规则备份原文件后重新开局），THE Windowfolk_App SHALL 把 Unlocked_Decor 设为空集合，并且 Toolbox 中不显示任何 Decor_Slot。
2. WHEN 一个 Chair_Wish 变为 `active` 且 `chair` 不在 Unlocked_Decor 中，THE Wish_Director SHALL 在同一次世界更新中把 `chair` 加入 Unlocked_Decor。
3. WHEN 一个 Lamp_Wish 变为 `active` 且 `lamp` 不在 Unlocked_Decor 中，THE Wish_Director SHALL 在同一次世界更新中把 `lamp` 加入 Unlocked_Decor。
4. WHEN 某个 Decor_Type 被加入 Unlocked_Decor，THE Event_Log SHALL 写入恰好 1 条 `decor_unlocked` 记录，`detail` 中包含该 Decor_Type；IF 该 Decor_Type 在 Wish 变为 `active` 时已在 Unlocked_Decor 中，THEN THE Event_Log SHALL 不再写入 `decor_unlocked` 记录。
5. THE Wish_Director SHALL 在任意世界更新序列中保持 Unlocked_Decor 只增不减：Wish 变为 `dropped` 或 `fulfilled`、对应类型的 Decor 全部被收回 Toolbox、场上 Decor 数量达到 Max_Decor_Count，都不移除已解锁的 Decor_Type（单调性）。唯一的例外是第 6 条的「重置世界」。
6. WHEN 玩家在 Debug_Menu 中选择「重置世界」，THE Windowfolk_App SHALL 把 Unlocked_Decor 重置为空集合，并且 Toolbox 中不再显示任何 Decor_Slot。
7. WHEN 某个 Decor_Type 被加入 Unlocked_Decor，THE Toolbox SHALL 在下一次渲染帧中显示该 Decor_Type 的 Decor_Slot。THE Toolbox SHALL 始终只为 Unlocked_Decor 中的 Decor_Type 显示 Decor_Slot，每个 Decor_Type 恰好 1 个，并按固定顺序排列（先 `chair`，后 `lamp`）。
8. WHEN Windowfolk_App 从格式版本号为 2 的 `world.json` 恢复世界，THE Persistence SHALL 把 Unlocked_Decor 恢复为与保存时相同的集合，恢复过程中不写入 `decor_unlocked` 记录。
9. IF 恢复时存档中的 Unlocked_Decor 含有不属于 Decor_Type 取值（`chair`、`lamp`）的值或重复值，THEN THE Persistence SHALL 忽略未知值并合并重复值，同时保留其余合法的 Decor_Type，并继续恢复存档的其他内容。

### Requirement 2: 工具箱中的装饰物

**User Story:** 作为玩家，我希望从工具箱里拿出已解锁的装饰物，这样我可以按自己的想法布置桌面。

#### Acceptance Criteria

1. THE Toolbox SHALL 在 v1 的 Plank 取物区和 Ladder 取物区之外，为 Unlocked_Decor 中的每个 Decor_Type 显示恰好一个 Decor_Slot，每个 Decor_Slot 显示该 Decor_Type 的图标。取物区按 Plank、Ladder、`chair`、`lamp` 的固定顺序排列，未解锁的 Decor_Type 不占位（与 Requirement 1 第 7 条一致）。所有取物区两两互不重叠。Toolbox 底边仍与 Ground 对齐，右边缘与 `visibleFrame` 右边缘的水平距离仍不超过 16pt。
2. WHEN 某个 Decor_Type 被加入 Unlocked_Decor，THE Toolbox SHALL 在下一帧内显示该 Decor_Type 的 Decor_Slot，并保持已有取物区的相对顺序不变。
3. WHEN 玩家在某个 Decor_Slot 内按下鼠标并拖动超过 Click_Drag_Threshold，且场上 Decor 数量小于 Max_Decor_Count，THE Toolbox SHALL 新建一个该 Decor_Type 的 Decor，并在鼠标位置显示该 Decor 的拖动预览；之后每一帧，拖动预览都跟随鼠标位置，直到玩家松开鼠标。
4. IF 玩家在 Decor_Slot 内开始拖动时场上 Decor 数量已等于 Max_Decor_Count，THEN THE Toolbox SHALL 不新建 Decor，不显示拖动预览，场上 Decor 数量保持不变，并让该 Decor_Slot 左右晃动一次（时长不超过 0.5 秒）。
5. IF 玩家在 Decor_Slot 上按下后松开，且拖动距离不超过 Click_Drag_Threshold，THEN THE Toolbox SHALL 不新建 Decor，不显示拖动预览，场上 Decor 数量保持不变。
6. THE Toolbox SHALL 把正在拖动、尚未松开的 Decor 计入第 3、4 条中的「场上 Decor 数量」。
7. WHEN 玩家从某个 Decor_Slot 拖出一个 Decor，THE Toolbox SHALL 继续显示该 Decor_Slot。同一 Decor_Type 可以反复拖出，只受 Max_Decor_Count 限制。
8. IF Unlocked_Decor 为空，THEN THE Toolbox SHALL 只显示 Plank 取物区和 Ladder 取物区，不显示任何 Decor_Slot。

### Requirement 3: 自由摆放与收回装饰物

**User Story:** 作为玩家，我希望把装饰物放在任意窗沿或地面，随时挪动或收起，这样布置完全由我决定。

#### Acceptance Criteria

1. WHILE 玩家拖动 Decor，THE Overlay SHALL 每帧更新 Decor 预览的位置，使光标相对 Decor 外接矩形左下角的偏移与按下鼠标时相同（误差不超过 1pt）；拖动期间 Decor 不附着任何 Surface，也不受竖直下落影响。
2. WHEN 玩家松开一个正在拖动的 Decor，且松开点与 Toolbox 外接矩形的距离大于 Toolbox_Return_Distance，且松开点正下方 Drop_Snap_Distance 以内（含边界）存在 Window_Ledge 或已架设的 Plank，THE Windowfolk_App SHALL 把该 Decor 附着到其中与松开点竖直距离最小的那条 Surface 上（距离相同时取位置较高的一条）。Decor 的水平中心取松开点 x 坐标并限制在该 Surface 的线段范围内，底边与该 Surface 的竖直距离不超过 1pt。
3. IF 玩家松开 Decor 时，松开点正下方 Drop_Snap_Distance 以内没有 Window_Ledge 或已架设的 Plank，且松开点与 Toolbox 外接矩形的距离大于 Toolbox_Return_Distance，THEN THE Windowfolk_App SHALL 让该 Decor 按 v1 R6 竖直下落，落到正下方第一条 Surface 上；落在 Ground 上时成为 Ground_Object。
4. WHEN 玩家松开一个从世界中拖起的 Decor，且松开点与 Toolbox 外接矩形的距离不超过 Toolbox_Return_Distance（含距离为 0，即松开点在矩形内），THE Windowfolk_App SHALL 在同一帧内从世界中移除该 Decor，使场上 Decor 数量减 1，并写入一条 `decor_removed` 事件记录，`detail` 中包含 Decor_Type。即使松开点正下方 Drop_Snap_Distance 以内存在 Surface，本条也优先于第 2 条。
5. IF 玩家松开一个刚从 Decor_Slot 新建、尚未放置过的 Decor，且松开点与 Toolbox 外接矩形的距离不超过 Toolbox_Return_Distance，THEN THE Windowfolk_App SHALL 丢弃该 Decor，场上 Decor 数量与新建前相同，且不写入 `decor_placed` 或 `decor_removed` 记录。
6. WHEN 玩家在任意 Decor 的命中区域内按下鼠标左键并拖动超过 Click_Drag_Threshold，THE Windowfolk_App SHALL 让该 Decor 进入拖动状态，不论它位于 Window_Ledge、Plank 还是 Ground。按下后移动不超过 Click_Drag_Threshold 就松开时，该 Decor 的位置和附着的 Surface 保持不变，也不写入事件记录。
7. WHILE 鼠标指针位于某个 Decor 的命中区域内，THE Overlay SHALL 按 v1 R7.3 和 R7.4 接收鼠标事件，不把这些事件传给下方应用；指针离开命中区域后 100 毫秒内恢复穿透。
8. IF 玩家开始拖动一把有居民正处于 `sitting` 状态的 Chair，THEN THE 坐在该 Chair 上的 Resident SHALL 在同一帧内离开 `sitting` 状态并转为 `idle`，留在原来的 Surface 上，水平位置不变，底边与该 Surface 的竖直距离不超过 1pt；Chair 随鼠标移动。
9. THE Decor SHALL 遵守 v1 中窗沿 Item 的跟随、隐藏和掉落规则：跟随所附着窗口移动（v1 R4），所附着窗口为 Hidden_Window 时隐藏且不掉落（v1 R5），所附着窗口为 Closed_Window、所在 Window_Ledge 消失或所在 Plank 失效时竖直下落（v1 R6）。
10. WHEN 玩家松开一个 Decor 后，该 Decor 按第 2 条附着到 Surface 上，或按第 3 条下落后落地（包括移动已有 Decor 后再次放置），THE Event_Log SHALL 写入一条 `decor_placed` 记录，`detail` 中包含 Decor_Type 和 Surface 类型（Window_Ledge、Plank 或 Ground 之一）；Decor 按第 9 条被动下落后落地，以及启动时按 Requirement 15 第 2 条落到 Ground 上，都不写入 `decor_placed` 记录（与 Requirement 18 第 4 条一致）。
11. THE Windowfolk_App SHALL 让居民穿过 Decor 所在位置继续行走，Decor 不阻挡 Nav_Graph 中的任何边。多个 Decor 可以在同一 Surface 上部分或完全重叠，放置时不因重叠被拒绝或挪位。
12. FOR ALL Decor，THE Windowfolk_App SHALL 在每次世界更新结束时满足以下任一条件：Decor 处于拖动中；Decor 处于下落中；Decor 附着在 Hidden_Window 上；Decor 底边与某条 Surface 的竖直距离不超过 1pt 且水平中心点落在该 Surface 线段范围内（无悬空不变量，与 v1 R29.5 一致）。

### Requirement 4: 居民的自主活动

**User Story:** 作为玩家，我希望居民在没有心愿时也会自己找事做，这样桌面看起来真的有生命在生活。

#### Acceptance Criteria

1. WHILE 某位居民不是 Busy_Resident，且不处于 `falling`、`hanging` 或 `climbing` 状态，THE Activity_Planner SHALL 为该居民保持恰好一个当前 Activity；WHILE 居民是 Busy_Resident 或处于 `falling`、`hanging` 状态，THE Activity_Planner SHALL 不为其保持任何当前 Activity。
2. WHEN 某位居民的当前 Activity 结束或被放弃，或某位非 Busy_Resident 的居民从 `falling`、`hanging` 状态转为其他状态，或某位居民不再是 Busy_Resident，THE Activity_Planner SHALL 在 1 秒内从该时刻可执行的 Activity 中为其选出下一个 Activity。
3. THE Activity_Planner SHALL 按以下条件判定 Activity 是否可执行：`wander` 始终可执行；`go_home` 在三项条件同时成立时可执行，即居民有 Home_Window、当前不在其 Home_Window 的任何一段 Window_Ledge 上、Nav_Graph 中存在到该 Window_Ledge 的路线；`visit_neighbor` 在另一位居民不处于 `falling`、`hanging` 状态且 Nav_Graph 中存在到其当前所在 Surface 的路线时可执行；`rest` 在至少存在一把未被占用、不处于拖动中或下落中、且有路线可达的 Chair 时可执行；`admire_flower` 在至少存在一朵有路线可达、Growth_Stage 为 `bloom` 的 Story_Flower 时可执行；`sleep` 按 Requirement 5 第 3 条判定。
4. WHILE Night，WHEN Activity_Planner 为某位居民选择下一个 Activity 且 `sleep` 可执行，THE Activity_Planner SHALL 选择 `sleep`。
5. WHILE 不是 Night，WHEN Activity_Planner 为某位居民选择下一个 Activity，THE Activity_Planner SHALL 用可注入的随机源，按集中定义的权重（每种 Activity 的权重大于 0）在当时可执行的 Activity 中加权随机选择，不可执行的 Activity 被选中的概率为 0；给定相同的随机源种子和相同的世界状态序列，选择结果完全相同（确定性）。
6. WHEN 居民开始执行 `wander`，THE Activity_Planner SHALL 用第 5 条的可注入随机源，在 Activity_Min_Duration 到 Activity_Max_Duration 的闭区间内均匀抽取持续时长；居民只在当前所在 Surface 上按 v1 R12.13 来回行走，不经过 Nav_Graph 的任何边离开该 Surface，持续时长到时后该 Activity 结束。
7. WHEN 居民开始执行 `go_home`、`visit_neighbor`、`rest` 或 `admire_flower`，THE Resident SHALL 沿 Nav_Graph 路线前往对应目标，遵守 v1 R12 的寻路和重新规划规则。各目标为：`go_home` 是其 Home_Window 的 Window_Ledge；`visit_neighbor` 是另一位居民当前所在 Surface 和屏幕 x 坐标，每帧更新；`rest` 是目标 Chair；`admire_flower` 是目标 Story_Flower。到达的判定为：`go_home` 在居民站上其 Home_Window 的任意一段 Window_Ledge 时到达，并在到达的同一帧结束该 Activity；其余三种在居民与目标位于同一 Surface、屏幕 x 坐标之差的绝对值不超过 Gift_Reach_Distance 时到达。
8. WHEN 执行 `visit_neighbor` 的居民到达另一位居民，THE 两位居民 SHALL 停止水平移动并面朝对方，停留 Visit_Stay_Duration，期间双方头顶都显示心形气泡；如果被拜访的居民处于 `sitting` 或 `sleeping` 状态，则保持该状态，不转向。停留结束后，被拜访居民的当前 Activity 从暂停处继续，拜访者的 `visit_neighbor` 结束，Event_Log 写入一条 `visited` 记录，`detail` 中包含拜访者和被拜访者。
9. WHEN 执行 `rest` 的居民到达目标 Chair 且该 Chair 未被占用，THE Resident SHALL 在同一帧内进入 `sitting` 状态、停止移动并占用该 Chair；持续 Sit_Duration 后离开 `sitting` 转为 `idle`，释放该 Chair，把 Walk_Distance 归零，并结束 `rest`。
10. WHEN 执行 `admire_flower` 的居民到达目标 Story_Flower，THE Resident SHALL 停止移动，面朝该花停留 Visit_Stay_Duration，期间头顶显示花朵图标气泡；停留结束后该 Activity 结束。
11. IF 自 Activity 开始起 Activity_Reach_Timeout 内未到达其目标，或执行途中目标变为不可执行（例如 Chair 在居民到达前被占用、被拖动或被收回 Toolbox，Story_Flower 被移除，另一位居民进入 `falling` 或 `hanging` 状态，或 Nav_Graph 中已无到目标的路线），或居民进入 `falling`、`hanging` 状态，THEN THE Activity_Planner SHALL 在同一帧内放弃该 Activity，居民不进入 `waiting` 状态，不显示心愿或失败气泡；之后按第 2 条选择下一个 Activity。
12. WHEN 某位居民成为 Busy_Resident，THE Activity_Planner SHALL 在同一帧内结束该居民的当前 Activity；处于 `sitting` 状态的居民同帧转为 `idle` 并释放所占的 Chair，处于 `sleeping` 状态的居民同帧转为 `idle`，并按 Requirement 18 第 6 条写入一条 `woke` 记录。
13. THE Windowfolk_App SHALL 在每次世界更新结束时保证每把 Chair 最多被 1 位居民占用，且每位处于 `sitting` 状态的居民恰好占用 1 把 Chair（不变量）。
14. WHEN 处于 `walking` 或 `running` 状态的居民在一帧内发生水平位移，THE Windowfolk_App SHALL 把该帧水平位移的绝对值（pt）累加到该居民的 Walk_Distance；`falling`、`hanging`、`climbing` 状态下的位移不计入。
15. WHILE Night，IF Activity_Planner 为某位居民选择下一个 Activity 时 `sleep` 不可执行，THEN THE Activity_Planner SHALL 按第 5 条的加权随机规则，在其余可执行的 Activity 中选择。

### Requirement 5: 昼夜与睡眠

**User Story:** 作为玩家，我希望夜里居民会在台灯旁睡觉，这样桌面的世界有一天的节奏。

#### Acceptance Criteria

1. THE Windowfolk_App SHALL 根据 Local_Clock 的本地时刻和 Day_Night_Override 判定当前是否为 Night。覆盖为「自动」时只按 Local_Clock 判定：本地时刻大于等于 Night_Start（19:00:00）或小于 Night_End（06:00:00）时为 Night，例如 19:00:00 和 05:59:59 是 Night，06:00:00 和 18:59:59 不是 Night。覆盖为「夜晚」时始终为 Night；覆盖为「白天」时始终不是 Night。
2. WHEN Night 状态因 Local_Clock 跨过 Night_Start 或 Night_End、或因玩家修改 Day_Night_Override 而发生变化，THE Windowfolk_App SHALL 在变化发生后 1 秒内更新 Night 判定结果，Activity_Planner 和 Overlay 都使用更新后的结果。
3. THE Activity_Planner SHALL 仅在以下条件同时成立时判定某位居民的 `sleep` 可执行：当前为 Night；场上至少有一盏 Lamp 放在 Window_Ledge、Plank 或 Ground 上，且没有被玩家拖动、也没有在下落；Nav_Graph 中存在从该居民当前位置到该 Lamp 所在 Surface 的路线。满足条件的 Lamp 有多盏时，以路线最短的一盏为目标 Lamp。两位居民可以以同一盏 Lamp 为目标，并同时在它旁边睡觉。
4. WHEN 执行 `sleep` 的居民走到与目标 Lamp 位于同一 Surface、水平距离不超过 Lamp_Range（80pt）的位置，THE Resident SHALL 进入 `sleeping` 状态，停止移动，并在 Event_Log 写入一条 `slept` 事件记录。每次进入 `sleeping` 只写一条 `slept` 记录。
5. IF 执行 `sleep` 的居民在到达目标 Lamp 之前，出现以下任一情况：Night 结束；目标 Lamp 被玩家开始拖动、被放回 Toolbox 或开始下落；从居民当前位置到目标 Lamp 的路线不再存在；从开始执行 `sleep` 起已过 Activity_Reach_Timeout（60 秒），THEN THE Activity_Planner SHALL 放弃该 `sleep`，让居民转为 `idle`，不写入 `slept` 记录，并按 Requirement 4 第 2 条选择下一个 Activity。
6. WHILE 居民处于 `sleeping` 状态，THE Overlay SHALL 在该居民头顶显示「Zzz」图标气泡。该气泡用图形绘制，不属于文字气泡，并在居民离开 `sleeping` 状态的同一帧消失。
7. WHEN Night 结束（包括 Local_Clock 到达 Night_End，以及昼夜覆盖改为「白天」或在非 Night 时刻改为「自动」），THE 处于 `sleeping` 状态的居民 SHALL 在 1 秒内转为 `idle`，Walk_Distance 归零，Event_Log 写入一条 `woke` 记录，然后按 Requirement 4 第 2 条选择下一个 Activity。
8. IF `sleeping` 居民的目标 Lamp 被玩家开始拖动、被放回 Toolbox 或开始下落，或该居民所在 Surface 消失，THEN THE Resident SHALL 在 1 秒内离开 `sleeping` 状态，Walk_Distance 归零，Event_Log 写入一条 `woke` 记录。Surface 消失时，居民按 v1 R6 进入 `falling`；其他情况下，居民转为 `idle`，并按 Requirement 4 第 2 条重新选择 Activity。
9. WHEN 玩家点击处于 `sleeping` 状态的居民，THE Resident SHALL 只显示「?」气泡 1.5 秒，保持 `sleeping` 状态和位置不变，不写入 `woke` 记录，Walk_Distance 也不变（扩展 v1 R7.8 的状态列表）。
10. WHILE Night，THE Overlay SHALL 为每盏放在 Window_Ledge、Plank 或 Ground 上的 Lamp 绘制发光效果；不是 Night 时，所有 Lamp 都不绘制发光效果。Night 状态变化后，发光效果在 1 秒内按新状态出现或消失。

### Requirement 6: 心愿的生成与调度

**User Story:** 作为玩家，我希望居民不定时冒出各种小心愿，由我决定帮不帮、先帮哪个，这样玩法没有固定路线。

#### Acceptance Criteria

1. WHEN Home_Window 分配完成（v1 R15 第 1 至 4、7 条），THE Wish_Director SHALL 开始调度 Wish，第一次检查在分配完成后满 1 个 Wish_Check_Interval 时进行，并不再按 v1 R15.5 直接开始送花轮次。
2. WHILE Home_Window 已分配，THE Wish_Director SHALL 按 Story_Clock 每隔 Wish_Check_Interval 对每位居民各检查一次。只有同时满足以下 4 个条件的居民才参与本次生成：该居民不是 Busy_Resident；该居民不处于 `falling` 或 `hanging` 状态；距其上一个 Wish 变为 `fulfilled` 或 `dropped` 已满 Wish_Cooldown（从未参与过 Wish 的居民视为已满足）；至少有一种 Wish_Type 满足第 3 条的生成条件。
3. THE Wish_Director SHALL 按以下条件判定各 Wish_Type 的生成条件：Flower_Wish 按 Requirement 8 第 1 条；Chair_Wish 在该居民 Walk_Distance ≥ Tired_Walk_Distance、且场上不存在一把未被占用且从该居民当前位置有路线可达的 Chair 时满足；Lamp_Wish 在 Night 期间、且场上不存在一盏从该居民当前位置有路线可达的 Lamp 时满足；Visit_Wish 在存在至少一个可作为 Visit_Target 的 Eligible_Window（不属于任何 Home_Window、当前至少有一段 Window_Ledge、且不是另一个 `active` Visit_Wish 的 Visit_Target）时满足；Chase_Wish 按 Requirement 20 第 1 条。
4. WHEN 某位居民通过第 2 条的检查，THE Wish_Director SHALL 用可注入的随机源抽取一次，抽中概率等于 Wish_Spawn_Chance；抽中时为该居民生成 1 个 Wish，未抽中时本次不生成，等待下一次检查。两位居民各自独立抽取。
5. WHEN Wish_Director 为某位居民生成 Wish 且该居民同时满足多种 Wish_Type 的生成条件，THE Wish_Director SHALL 用可注入的随机源在这些 Wish_Type 中等概率选择一种。
6. WHEN Wish_Director 生成一个 Visit_Wish 且有多个窗口可作为 Visit_Target，THE Wish_Director SHALL 用可注入的随机源在这些窗口中等概率选择 1 个作为 Visit_Target，并在该 Wish 为 `active` 期间显示其 Visit_Flag。
7. THE Wish_Director SHALL 让每位居民同一时刻最多参与 1 个 `active` Wish（不变量）。
8. WHEN 一个 Wish 变为 `active`，THE Wish_Director SHALL 记录其 Wish_Type、Wisher 和 Story_Clock 创建时间，在 Wisher 头顶显示对应的 Wish_Bubble，并写入一条 `wish_started` 事件记录。
9. WHILE 一个 Wish 为 `active`，THE Wisher SHALL 持续显示 Wish_Bubble，直到该 Wish 变为 `fulfilled` 或 `dropped`；Flower_Wish 的气泡规则另按 v1 R16.2。
10. WHEN 一个 Wish 变为 `fulfilled`，THE Wish_Director SHALL 隐藏 Wish_Bubble，让 Wisher 播放一次 `celebrating` 动画，写入一条 `wish_fulfilled` 记录，结束该 Wish 所有参与者的 Busy_Resident 身份，并以此刻的 Story_Clock 时间作为这些居民 Wish_Cooldown 的起点。
11. IF 一个既非 Flower_Wish 也非 Chase_Wish 的 Wish 按 Story_Clock 保持 `active` 达到 Wish_Timeout，THEN THE Wish_Director SHALL 把该 Wish 设为 `dropped`，隐藏 Wish_Bubble 和 Visit_Flag（如有），写入一条 `wish_dropped` 记录，结束 Wisher 的 Busy_Resident 身份，以此刻的 Story_Clock 时间作为 Wisher Wish_Cooldown 的起点，并让 Wisher 转为 `idle` 后恢复自主活动。此过程不改变任何其他世界状态：不扣分，不移除物件，不改变 Unlocked_Decor，不影响之后 Wish 的生成概率。
12. IF 一个 Wish 保持 `active` 期间其生成条件中的场景前提消失（Visit_Target 成为 Closed_Window，或 Visit_Target 不再有任何 Window_Ledge；或 Lamp_Wish 进行中 Night 结束），THEN THE Wish_Director SHALL 在下一次世界更新中按第 11 条把该 Wish 设为 `dropped`，不必等到 Wish_Timeout。Visit_Target 成为 Hidden_Window 不属于场景前提消失，按 Requirement 9 第 7 条处理。Flower_Wish 按 Requirement 8 第 5 条、Chase_Wish 按 Requirement 20 第 6 条，都不适用本条。
13. WHILE 一个非 Chase_Wish 的 Wish 为 `active` 且该 Wish 所需路线不存在，THE Wisher SHALL 按 v1 R12.10 或 v1 R6.9 进入 `waiting`，以 Wish_Bubble 代替「...」气泡，并且该 Wish 的 Wish_Timeout 计时继续累计。Chase_Wish 中路线不存在时按 Requirement 21 第 3、6 条处理。

### Requirement 7: 椅子与台灯心愿

**User Story:** 作为玩家，我希望在居民累了或怕黑时给它们摆上椅子或台灯，这样我的布置直接回应了它们的需要。

#### Acceptance Criteria

1. WHILE 一个 Chair_Wish 为 `active` 且 Wisher 没有目标 Chair，THE Wisher SHALL 在头顶显示以图形绘制的「椅子」图标 Wish_Bubble（不含文字），在该 Wish 变为 `active` 后 1 帧内停止水平移动并保持在当前 Surface 上；Wisher 当前位置与任何 Chair 之间都没有 Nav_Graph 路线时，按 Requirement 6 第 13 条进入 `waiting`，否则处于 `idle`。
2. WHILE 一个 Chair_Wish 为 `active` 且 Wisher 没有目标 Chair，WHEN 某次世界更新结束时存在至少一把未被占用、且 Wisher 有 Nav_Graph 路线可达的 Chair（包括 Chair 被放置、被其他居民释放、或通往 Chair 的路线新出现），THE Wisher SHALL 在 1 秒内把其中路线水平总长度最短的一把设为目标 Chair，并按 v1 R12 的寻路和重新规划规则出发；如果有多把 Chair 的路线水平总长度相等，选择最早被放置到当前 Surface 的那一把；出发后即使出现更近的 Chair，Wisher 也不更换目标。
3. WHEN Chair_Wish 的 Wisher 到达目标 Chair 且该 Chair 仍未被占用，从而按 Requirement 4 第 9 条进入 `sitting` 并占用该 Chair，THE Wish_Director SHALL 在同一次世界更新中把该 Chair_Wish 设为 `fulfilled`，隐藏 Wish_Bubble，写入一条 `wish_fulfilled` 记录，并结束 Wisher 的 Busy_Resident 身份；Wisher 保持 `sitting`，不播放 `celebrating` 动画（本条优先于 Requirement 6 第 10 条的庆祝动画）；Activity_Planner 把 Wisher 的当前 Activity 视为 `rest`，按 Requirement 4 第 9 条在 Sit_Duration 后让 Wisher 离开 `sitting`、释放 Chair 并把 Walk_Distance 归零。
4. WHILE 一个 Lamp_Wish 为 `active` 且 Wisher 没有目标 Lamp，THE Wisher SHALL 在头顶显示以图形绘制的「台灯」图标 Wish_Bubble（不含文字），在该 Wish 变为 `active` 后 1 帧内停止水平移动并保持在当前 Surface 上；Wisher 当前位置与任何 Lamp 之间都没有 Nav_Graph 路线时，按 Requirement 6 第 13 条进入 `waiting`，否则处于 `idle`。
5. WHILE 一个 Lamp_Wish 为 `active` 且 Wisher 没有目标 Lamp，WHEN 某次世界更新结束时存在至少一盏 Wisher 有 Nav_Graph 路线可达的 Lamp（包括 Lamp 被放置、或通往 Lamp 的路线新出现），THE Wisher SHALL 在 1 秒内把其中路线水平总长度最短的一盏设为目标 Lamp，并按 v1 R12 的寻路和重新规划规则出发，走向与该 Lamp 同一 Surface、水平距离不超过 Lamp_Range 的位置；如果有多盏 Lamp 的路线水平总长度相等，选择最早被放置到当前 Surface 的那一盏；出发后即使出现更近的 Lamp，Wisher 也不更换目标。
6. WHEN Lamp_Wish 的 Wisher 走到与目标 Lamp 同一 Surface、水平距离不超过 Lamp_Range 的位置，从而按 Requirement 5 第 4 条进入 `sleeping`，THE Wish_Director SHALL 在同一次世界更新中把该 Lamp_Wish 设为 `fulfilled`，隐藏 Wish_Bubble，写入一条 `wish_fulfilled` 记录，并结束 Wisher 的 Busy_Resident 身份；Wisher 保持 `sleeping`，不播放 `celebrating` 动画（本条优先于 Requirement 6 第 10 条的庆祝动画）；Activity_Planner 把 Wisher 的当前 Activity 视为 `sleep`，之后按 Requirement 5 第 7、8 条醒来。
7. IF Chair_Wish 或 Lamp_Wish 的 Wisher 在前往目标途中，目标 Chair 被另一位居民占用，目标 Decor 被玩家拖动、被收回 Toolbox 或开始下落，或者 Wisher 到目标的 Nav_Graph 路线消失，THEN THE Wisher SHALL 在 1 帧内清除目标、停止水平移动，回到第 1 条（Chair_Wish）或第 4 条（Lamp_Wish）的等待行为，并重新显示对应的 Wish_Bubble；该 Wish 保持 `active`，创建时间不变，Wish_Timeout 继续计时；之后按第 2 条或第 5 条重新选择目标。
8. WHILE Chair_Wish 或 Lamp_Wish 为 `active`，THE Wish_Director SHALL 只按 Requirement 6 第 11、12 条的 Wish_Timeout 和场景前提规则放弃该 Wish；Activity_Reach_Timeout 不适用于 Wisher 前往目标 Decor 的过程，前往途中 Wisher 也不按 Requirement 4 第 11 条放弃。

### Requirement 8: 送花心愿

**User Story:** 作为玩家，我希望 v1 的送花故事成为众多心愿中的一个，并且两位居民仍会轮流送花，这样熟悉的故事还在，但不再是唯一的路线。

#### Acceptance Criteria

1. WHEN Wish_Director 按 Requirement 6 第 2 条检查某位居民，THE Wish_Director SHALL 仅在以下 3 个条件同时成立时判定该居民满足 Flower_Wish 生成条件：（a）两位居民都不是 Busy_Resident；（b）该居民是下一次 Flower_Wish 的 Giver，即第 1 次 Flower_Wish 的 Giver 为 Resident_A，此后每次 Flower_Wish 的 Giver 与上一次 Flower_Wish 的 Receiver 相同；（c）从上一个 Flower_Wish 的 Story_Stage 进入 `Done` 算起，Story_Clock 已经过的时长 ≥ Round_Interval，从未有过 Flower_Wish 时跳过此条。任一条件不成立时，Flower_Wish 不计入该居民可选的 Wish_Type，下一次 Flower_Wish 的 Giver 也不变。
2. WHEN 一个 Flower_Wish 变为 `active`，THE Wish_Director SHALL 在同一次世界更新中完成以下设置：把 Giver 设为当前 Wisher，把 Receiver 设为另一位居民，把两位居民都设为 Busy_Resident，把已开始过的 Flower_Wish 次数加 1，并把加 1 后的次数（含本次）作为该 Flower_Wish 的 v1 Story_Round 编号。
3. WHILE 一个 Flower_Wish 为 `active`，THE Story_Director SHALL 按 v1 R16、R17、R18 和 v1 R20 第 1 至 5 条执行送花、种花、生长、回赠流程。
4. WHEN 该 Flower_Wish 的 Story_Stage 进入 `Done`，THE Wish_Director SHALL 在同一次世界更新中把该 Flower_Wish 设为 `fulfilled`，按 Requirement 6 第 10 条处理气泡、动画和事件记录，结束 Giver 和 Receiver 两位居民的 Busy_Resident 身份，并让两位居民按 Requirement 4 恢复自主活动。v1 R18.9 中 `Done` 阶段的活动限制不再适用。
5. WHILE 一个 Flower_Wish 为 `active`，THE Wish_Director SHALL 让该 Flower_Wish 保持 `active` 直到其 Story_Stage 进入 `Done`。无论保持 `active` 多久，THE Wish_Director SHALL 不按 Requirement 6 第 11 条（Wish_Timeout）或第 12 条（场景前提消失）把它设为 `dropped`。
6. FOR ALL Flower_Wish 次数 n（n ≥ 1），THE Wish_Director SHALL 使第 n 次 Flower_Wish 的 Giver 在 n 为奇数时为 Resident_A，在 n 为偶数时为 Resident_B；Receiver 是另一位居民。中间夹着多少个其他 Wish_Type 的 Wish、有没有被 `dropped` 的 Wish、是否经过保存与恢复，都不影响这一轮换不变量。该条取代 v1 R19.5 的轮次定义。
7. THE Story_Director SHALL 继续按 v1 R19.4 在场上保留至多 Max_Story_Flowers 朵 Story_Flower。
8. WHEN 玩家在 Debug_Menu 中选择「快进」且存在一个 Story_Stage 为 `Growing` 的 `active` Flower_Wish，THE Story_Clock SHALL 按 v1 R17.5 让该 Flower_Wish 的 Story_Flower 立即进入下一个 Growth_Stage（`pot` 变为 `sprout`，`sprout` 变为 `bloom`），之后从该阶段的起始时长继续计时，不跳过阶段。
9. WHEN 玩家在 Debug_Menu 中选择「快进」，并且当前没有 `active` Flower_Wish、至少有过 1 个 `fulfilled` Flower_Wish、上一个 Flower_Wish 进入 `Done` 后经过的 Story_Clock 时长 < Round_Interval，THE Story_Clock SHALL 立即结束 Round_Interval 等待，使第 1 条的条件（c）成立；Wish_Director 继续对下一次 Flower_Wish 应用 Requirement 6 第 2 条的 Wish_Check_Interval、Wish_Cooldown 和 Wish_Spawn_Chance 规则，不跳过这些规则（取代 v1 R17.6 中立即开始下一轮的处理）。
10. IF 玩家在 Debug_Menu 中选择「快进」时，第 8 条和第 9 条的条件都不成立，THEN THE Story_Clock SHALL 不改变任何 Story_Flower 的 Growth_Stage、任何 Flower_Wish 的 Story_Stage 或 Wish_State，也不改变下一次 Flower_Wish 的 Giver。

### Requirement 9: 去看看心愿

**User Story:** 作为玩家，我希望居民偶尔想去别的窗口看看，这样我会去连通平时没人去的角落。

#### Acceptance Criteria

1. WHEN 一个 Visit_Wish 变为 `active`，THE Wish_Director SHALL 用可注入的随机源，从满足 Requirement 6 第 3 条 Visit_Wish 条件的 Eligible_Window 中等概率选出一个作为 Visit_Target。该 Visit_Wish 结束（`fulfilled` 或 `dropped`）前，Visit_Target 不更换。
2. WHILE 一个 Visit_Wish 为 `active` 且 Visit_Target 不是 Hidden_Window，THE Overlay SHALL 每帧在 Visit_Target 当前最长一段 Window_Ledge 的中点上方绘制 Visit_Flag。Visit_Target 移动或改变大小后，Visit_Flag 在下一帧跟到新位置。
3. WHILE 一个 Visit_Wish 为 `active`，THE Wisher SHALL 显示「小旗」图标的 Wish_Bubble，气泡里有一个水平箭头。Visit_Flag 中点的 x 坐标小于 Wisher 的 x 坐标时，箭头朝左；其余情况朝右。Wisher 或 Visit_Flag 移动后，箭头方向在下一帧更新。
4. WHILE 一个 Visit_Wish 为 `active`，且 Nav_Graph 中存在从 Wisher 当前 Surface 到 Visit_Target 任一段 Window_Ledge 的路线，THE Wisher SHALL 在路线出现后 1 秒内出发，沿路线前往 Visit_Target。存在多条路线时，Wisher 走水平总长度最短的一条。
5. IF 一个 Visit_Wish 为 `active`，且 Wisher 前往 Visit_Target 途中路线消失，THEN THE Wisher SHALL 按 Requirement 6 第 13 条进入 `waiting`，该 Visit_Wish 保持 `active`，Visit_Target 不变。
6. WHEN Visit_Wish 的 Wisher 落在 Visit_Target 的任一段 Window_Ledge 上，且处于既非 `falling` 也非 `hanging` 的状态，THE Wish_Director SHALL 在同一次世界更新中把该 Visit_Wish 设为 `fulfilled`，移除 Visit_Flag，写入一条 `visited` 事件记录（其 `target` 为 Visit_Target 所属应用的名称），并按 Requirement 6 第 10 条执行完成处理。
7. WHILE 一个 Visit_Wish 为 `active` 且 Visit_Target 为 Hidden_Window，THE Overlay SHALL 不绘制 Visit_Flag。此时 Visit_Wish 保持 `active`，Wish_Timeout 继续计时，Wisher 按 Requirement 6 第 13 条等待。Visit_Target 不再是 Hidden_Window 后，Visit_Flag 在下一帧恢复绘制。Visit_Target 成为 Closed_Window 时，按 Requirement 6 第 12 条处理。
8. WHEN Visit_Wish 变为 `fulfilled`，且庆祝动画结束后 Activity_Planner 为该 Wisher 选择下一个 Activity，THE Activity_Planner SHALL 在 Nav_Graph 存在从 Wisher 当前 Surface 到其 Home_Window 的路线时，把 `go_home` 放进候选 Activity 集合。
9. IF 一个 Visit_Wish 按 Requirement 6 第 11 条或第 12 条被设为 `dropped`，THEN THE Overlay SHALL 在下一帧移除 Visit_Flag，Wisher 不再前往 Visit_Target。

### Requirement 10: 心愿与玩家操作的关系

**User Story:** 作为玩家，我希望自由决定先帮哪个心愿或干脆不帮，这样陪伴是轻松的，没有压力。

#### Acceptance Criteria

1. WHILE 存在至少 1 个 `active` Wish，THE Windowfolk_App SHALL 让玩家从 Toolbox 拖出 Plank、Ladder 和已解锁的 Decor，拖动场上的 Plank、Ladder、Item 和 Decor，以及点击居民。这些操作的结果与不存在 `active` Wish 时相同，不受 `active` Wish 的数量（0 至 2 个）、Wish_Type 或 Wisher 的限制。
2. WHILE 两位居民各有一个 `active` 的非 Flower_Wish，THE Wish_Director SHALL 独立跟踪这两个 Wish。玩家可以按任意顺序完成它们，也可以只完成其中一个，或一个都不完成。
3. WHEN 两个同时 `active` 的 Wish 中有一个变为 `fulfilled` 或 `dropped`，THE Wish_Director SHALL 保持另一个 Wish 的 Wish_State、Wisher、Wish_Bubble 显示和 Story_Clock 创建时间不变，也不重置它的 Wish_Timeout 计时。
4. THE Windowfolk_App SHALL 在 Overlay、Toolbox、Status_Menu 和 Wish_Bubble 中都不显示分数、进度条、倒计时、剩余时间、已完成或已放弃 Wish 的计数，也不显示失败提示。
5. WHEN 一个 Wish 按 Requirement 6 第 11 或 12 条变为 `dropped`，THE Windowfolk_App SHALL 只按 Requirement 6 第 11 条隐藏 Wish_Bubble，不显示额外的图标、气泡、动画、声音或文字提示。
6. WHEN 玩家点击一位 Wisher，THE Resident SHALL 按 v1 R7 第 6 至 9 条（`sleeping` 状态下按 Requirement 5 第 9 条）反应。「?」气泡显示期间隐藏 Wish_Bubble；该 Wish 仍为 `active` 时，「?」气泡结束后的下一帧恢复显示 Wish_Bubble。
7. WHEN 玩家点击一位 Wisher，THE Wish_Director SHALL 保持该 Wish 的 Wish_State、Wish_Type、Wisher、Visit_Target 和 Story_Clock 创建时间不变，不暂停也不重置 Wish_Timeout 计时，也不因这次点击把该 Wish 设为 `fulfilled` 或 `dropped`。

### Requirement 11: LLM 设置

**User Story:** 作为玩家，我希望自己决定是否接入 LLM 以及接哪个服务，这样不想联网时世界照样可玩。

#### Acceptance Criteria

1. WHEN Windowfolk_App 启动且本机没有已保存的 LLM_Settings，THE Windowfolk_App SHALL 把「日记使用 LLM」和「小心思」两项都设为关闭，并把服务地址、模型名、API Key 都设为空。
2. WHEN 玩家在 Status_Menu 中选择「设置…」，THE Windowfolk_App SHALL 打开 Settings_Window。Settings_Window 中可编辑服务地址（最多 2048 个字符）、模型名（最多 128 个字符）、API Key（最多 512 个字符），以及「日记使用 LLM」和「小心思」两个开关。各项显示当前已保存的值，API Key 以掩码字符显示。如果 Settings_Window 已经打开，THE Windowfolk_App SHALL 把已打开的窗口移到最前，不再新开第二个。
3. THE Windowfolk_App SHALL 把 API Key 存入 macOS 钥匙串，不写入 `world.json`、`events.jsonl`、`diary.jsonl`、Prompt_Payload 或任何日志。
4. WHEN 玩家在 Settings_Window 中修改任一项 LLM_Settings，THE Windowfolk_App SHALL 在 1 秒内保存该值，并让 Diary_Writer 和 Thought_Engine 此后的请求使用新值。保存后的 LLM_Settings（包括两个开关的状态）在 Windowfolk_App 重启后保持不变。
5. IF 服务地址、模型名或 API Key 任一项为空，或去掉首尾空白后为空，THEN THE Settings_Window SHALL 让「日记使用 LLM」和「小心思」两个开关不可打开，把处于打开状态的开关改为关闭，并在开关旁显示每一个需补全的项目名称。
6. IF 服务地址去掉首尾空白后不是以 `http://` 或 `https://` 开头、且带主机名的 URL，THEN THE Settings_Window SHALL 在服务地址旁显示地址格式无效的提示，并按第 5 条处理两个开关，与服务地址为空时相同。
7. WHEN 某个开关（「日记使用 LLM」或「小心思」）在本机第一次被玩家切到打开，THE Settings_Window SHALL 先显示一次说明，在玩家确认前该开关保持关闭。说明的内容是：发送给 LLM 服务的内容只有居民名字、事件类型、事件时间、日期、物件种类、心愿种类、心愿状态、追逐结局和花的生长阶段（与 Requirement 12 第 1 条一致），不包含窗口标题和应用名称。说明提供「确认」和「取消」两个选项。
8. WHEN 玩家在第 7 条的说明中选择「确认」，THE Settings_Window SHALL 打开对应开关，并记住该开关的说明已确认，以后再打开该开关时不再显示说明。WHEN 玩家选择「取消」或关闭说明，THE Settings_Window SHALL 让该开关保持关闭，下次尝试打开时重新显示说明。
9. IF API Key 写入或读取 macOS 钥匙串失败，THEN THE Windowfolk_App SHALL 在 Settings_Window 中显示钥匙串操作失败的提示，按 API Key 为空处理第 5 条，并且不把 API Key 改存到任何其他位置。
10. WHILE 「日记使用 LLM」和「小心思」都关闭，THE Windowfolk_App SHALL 不发起任何网络请求。
11. THE Settings_Window 和 Diary_Window SHALL 属于 Windowfolk_App 自身，按 v1 R2 和 R3.3 不成为 Eligible_Window，也不生成 Window_Ledge。

### Requirement 12: 发送给 LLM 的内容

**User Story:** 作为玩家，我希望接入 LLM 时只发送必要的信息，这样我的电脑使用情况不会外泄。

#### Acceptance Criteria

1. THE Diary_Writer 和 Thought_Engine SHALL 只通过 Prompt_Payload 向 LLM_Client 提供世界信息。Prompt_Payload 只能包含以下内容：居民名字（都都、嘟嘟）、事件 `type`、事件 `time`、Decor_Type、Wish_Type、Wish_State、Chase_Outcome、Growth_Stage、Local_Clock 的本地日期，以及 Windowfolk_App 内置的固定提示文本。除这些之外，Prompt_Payload 不包含其他字段或文本，尤其不包含应用名称、窗口 ID、窗口边界矩形、屏幕坐标、Surface 位置、API Key，以及 `thought_shown` 记录 `detail` 中的 Thought 文本。
2. FOR ALL 事件记录序列（包括事件中带有任意应用名称字符串和任意窗口 ID 的序列），THE Diary_Writer 和 Thought_Engine 由该序列生成的 Prompt_Payload SHALL 满足以下条件：该序列中出现过的应用名称字符串都不作为子串出现在 Prompt_Payload 中，窗口 ID 数值也都不作为独立字段值出现在 Prompt_Payload 中（隐私不变量）。
3. IF LLM_Client 请求在 LLM_Request_Timeout（15 秒）内未返回、返回错误状态、返回空文本或返回只含空白字符的文本，THEN THE LLM_Client SHALL 把该请求判为失败且不重试；调用方按各自的回退规则处理（Requirement 13 第 7 条、Requirement 14 第 5 条）；Windowfolk_App 继续运行，不弹出错误对话框，世界状态和存档内容不因该失败发生回滚或丢失。
4. IF 某次 LLM_Client 请求已被判为超时，之后才收到该请求的响应，THEN THE 调用方 SHALL 丢弃该响应，不据此生成 Diary_Entry，也不显示 Thought。
5. THE LLM_Client SHALL 在 Game_Loop 之外异步执行请求。请求进行期间，Game_Loop 不等待请求结果，每帧世界更新照常进行：居民移动、Decor 拖放和 Wish 计时都与没有请求时一致。
6. IF「日记使用 LLM」和「小心思」两个开关都处于关闭状态，或服务地址、模型名、API Key 任一项为空，THEN THE Windowfolk_App SHALL 不向任何外部服务发送请求。只有「日记使用 LLM」关闭时，Diary_Writer 不发送请求；只有「小心思」关闭时，Thought_Engine 不发送请求。
7. WHEN LLM_Client 发送请求，THE LLM_Client SHALL 只向 LLM_Settings 中配置的服务地址发送，API Key 只用于该请求的身份验证，不写入 Prompt_Payload。

### Requirement 13: 居民日记

**User Story:** 作为玩家，我希望看到都都和嘟嘟写下的日记，这样桌面上发生的小事会被记住。

#### Acceptance Criteria

1. THE Diary_Writer SHALL 把 `events.jsonl` 中每条记录的 `time` 换算到 Local_Clock 当前时区，按换算后的本地日期（00:00:00 含，到次日 00:00:00 不含）归入对应日期，作为该日期日记的素材；某居民在某日期的「相关事件」指该日期内 `actor` 或 `target` 等于该居民标识的记录。IF 某行不是合法 JSON，或缺少 `time`、`type` 字段，或 `time` 无法解析，THEN THE Diary_Writer SHALL 跳过该行，其余行照常读取。
2. WHEN Windowfolk_App 运行期间 Local_Clock 的本地日期从 D 变为下一日期，THE Diary_Writer SHALL 为日期 D 中每位有至少 1 条相关事件、且在 Diary_Store 中还没有日期 D 的 Diary_Entry 的居民，各生成恰好 1 篇 Diary_Entry。
3. WHEN Windowfolk_App 启动，THE Diary_Writer SHALL 为早于今天的每个本地日期中，每位有至少 1 条相关事件、且在 Diary_Store 中还没有该日期 Diary_Entry 的居民，各生成恰好 1 篇 Diary_Entry；已有该日期 Diary_Entry 的居民不重新生成。
4. WHEN 玩家在 Diary_Window 中选择「写今天的日记」，THE Diary_Writer SHALL 只用今天 00:00:00 到选择时刻之间的事件，为每位今天有至少 1 条相关事件的居民各生成 1 篇 Diary_Entry，并替换该居民今天已有的 Diary_Entry；今天没有相关事件的居民不生成，已有的 Diary_Entry 也保持不变。
5. WHILE 「日记使用 LLM」关闭，THE Diary_Writer SHALL 用模板生成 Diary_Entry 正文：每种事件类型对应固定句式（Chase_Wish 的 `wish_fulfilled` 记录按 Requirement 22 第 8 条在 4 种固定句式中选择），句子顺序与事件在 `events.jsonl` 中的行顺序一致；输入相同的居民和相同的事件序列时，正文逐字符相同。生成方式记为 `template`。
6. WHILE 「日记使用 LLM」打开，THE Diary_Writer SHALL 把该居民在该日期的相关事件作为 Prompt_Payload 交给 LLM_Client 生成 Diary_Entry 正文，要求以第一人称、该居民的口吻书写；Prompt_Payload 中不包含窗口标题。LLM 生成成功时，生成方式记为 `llm`。
7. IF LLM 生成失败（按 Requirement 12 第 3 条判定），THEN THE Diary_Writer SHALL 改用第 5 条的模板为该篇生成 Diary_Entry，生成方式记为 `template`，不弹出提示；同一批次中其他居民的 Diary_Entry 仍各自尝试 LLM 生成。
8. THE Diary_Writer SHALL 把每篇 Diary_Entry 正文截断到不超过 Diary_Max_Length 个 Unicode 字素；不超过 Diary_Max_Length 的正文原样保留。
9. THE Diary_Store SHALL 以每行一篇 Diary_Entry 的 JSONL 格式追加写入 `diary.jsonl`，保留文件中已有的全部行；FOR ALL 合法的 Diary_Entry，编码为一行 JSON 再解码 SHALL 得到相等的值，包括正文含引号、换行和非 ASCII 字符的情况（往返属性）。
10. WHEN Diary_Store 读取 `diary.jsonl`，THE Diary_Store SHALL 跳过无法解析为合法 Diary_Entry 的行；同一居民、同一本地日期有多行时，只取文件中最靠后的一行作为该居民该日期的 Diary_Entry。
11. IF 写入 `diary.jsonl` 失败（包括目录无法创建、文件无写权限或磁盘已满），THEN THE Diary_Store SHALL 丢弃该篇 Diary_Entry，不重试，不弹出提示，Windowfolk_App 继续运行；`diary.jsonl` 中已有的行保持不变。
12. WHEN 玩家在 Status_Menu 中选择「日记」，THE Windowfolk_App SHALL 打开 Diary_Window，按本地日期从新到旧列出第 10 条规则读出的全部 Diary_Entry，每篇显示日期、居民名字和正文；IF 没有任何 Diary_Entry，THEN THE Diary_Window SHALL 显示一条空状态提示，说明还没有日记，同时仍提供「写今天的日记」。
13. IF 某个本地日期没有任何事件记录，或某位居民在该日期没有相关事件，THEN THE Diary_Writer SHALL 不为该日期或该居民生成 Diary_Entry。

### Requirement 14: 小心思

**User Story:** 作为玩家，我希望居民偶尔冒出一句自己的小心思，这样它们更像有想法的生命。

#### Acceptance Criteria

1. WHILE 「小心思」打开，WHEN 发生 `wish_fulfilled`、`landed`、`woke` 或 `visited` 事件，且距上一条 Thought 开始显示已满 Thought_Min_Interval（本次启动以来尚未显示过 Thought 时视为已满），且没有进行中的 Thought 请求，THE Thought_Engine SHALL 用该事件的 `actor` 居民和 Event_Log 中最近 20 条事件（不足 20 条时用全部已有事件）组成 Prompt_Payload，向 LLM_Client 请求一条以该居民第一人称口吻书写的 Thought。
2. WHEN LLM_Client 返回文本，THE Thought_Engine SHALL 把每一段连续的换行符（含 `\r`、`\n`、`\r\n`）替换为一个空格，去除首尾空白，按 Unicode 字素截断到不超过 Thought_Max_Length 个字符；IF 处理后文本为空，THEN THE Thought_Engine SHALL 按第 5 条的失败处理，否则在对应居民头顶以文字气泡显示该 Thought，显示时长为 Thought_Display_Duration，气泡随居民移动。
3. IF 返回 Thought 时，或 Thought 显示期间，对应居民处于 `falling`、`hanging` 或 `sleeping` 状态，或其所在窗口为 Hidden_Window，或世界因 v1 R23 隐藏，THEN THE Thought_Engine SHALL 丢弃尚未显示的 Thought，或在同一帧内移除正在显示的 Thought 气泡；尚未显示就被丢弃的 Thought 不计入第 1 条的 Thought_Min_Interval，也不写入 `thought_shown` 记录；已开始显示后被移除的 Thought 已按第 8 条写入的 `thought_shown` 记录保留不变。
4. WHILE 某位居民正在显示 Wish_Bubble，THE Overlay SHALL 把 Thought 气泡画在 Wish_Bubble 上方，两者的外接矩形不重叠。
5. IF LLM 请求失败（按 Requirement 12 第 3 条），THEN THE Thought_Engine SHALL 不显示任何 Thought，不重试该次请求，不更新第 1 条的 Thought_Min_Interval 计时，并结束该次请求的进行中状态，使后续符合第 1 条的事件可以发起新请求。
6. WHILE 「小心思」关闭，或「小心思」打开但没有正在显示的 Thought，THE Overlay SHALL 不显示任何文字气泡，v1 R15.9「气泡中不出现文字」的规则对 Thought 以外的全部气泡继续有效。
7. FOR ALL LLM_Client 返回的文本，THE Thought_Engine 显示的 Thought SHALL 不含换行符，长度不超过 Thought_Max_Length 个字符（按 Unicode 字素计），首尾无空白，且不为空（不变量）。
8. WHEN 一条 Thought 开始显示，THE Event_Log SHALL 写入一条 `thought_shown` 记录，`actor` 为该居民，`detail` 中包含显示出来的 Thought 文本（即第 2 条处理后的文本）。
9. WHILE 有一个 Thought 请求在进行中，THE Thought_Engine SHALL 不发起新的 Thought 请求，期间发生的第 1 条所列事件不排队、不补发。
10. WHEN 玩家关闭「小心思」，THE Thought_Engine SHALL 丢弃进行中请求在关闭之后返回的任何文本，并在同一帧内移除正在显示的 Thought 气泡。

### Requirement 15: 保存与恢复（V2 版本）

**User Story:** 作为玩家，我希望退出再打开后解锁的物件、心愿和花都还在，这样我的布置和帮助不会白费。

#### Acceptance Criteria

1. THE Persistence SHALL 把每次写入的 `world.json` 的格式版本号设为 2，并在 v1 R22.3 所列内容之外保存以下内容：Unlocked_Decor（可以为空集）；每个 Decor 的 Decor_Type 和屏幕 x 坐标，按 v1 R22.4 的规则记录为 Ground_Object（附着在 Hidden_Window 上的 Decor 取该窗口最后一次可见时的屏幕 x 坐标）；每位 Resident 的 Walk_Distance 和上一个 Wish 结束时间（从未结束过 Wish 时为空）；每个 Wish_State 为 `active` 且不是 Chase_Wish 的 Wish 的 Wish_Type、Wisher、创建时间，Visit_Wish 另存 Visit_Target 所属应用名称；已开始过的 Flower_Wish 次数（含当前 `active` 的那次，与 Requirement 8 第 2 条的 Story_Round 编号一致）；上一个 Flower_Wish 进入 `Done` 的时间（从未进入时为空）。Wish_State 为 `fulfilled` 或 `dropped` 的 Wish 不写入 `world.json`。
2. THE Persistence SHALL 不保存 Decor 和 Item 在 Window_Ledge 或 Plank 上的原位。WHEN Windowfolk_App 启动且 `world.json` 解析成功，THE Windowfolk_App SHALL 让每个保存的 Decor 按 v1 R22.6 从主显示器上沿上方落到 Ground 上保存的 x 坐标处；保存的 x 超出当前主显示器宽度时，落点限制在屏幕宽度范围内。
3. WHEN Windowfolk_App 启动并恢复出 `active` 的 Chair_Wish、Lamp_Wish 或 Flower_Wish，且该 Wish 是 Flower_Wish，或 Story_Clock 当前时间与保存的创建时间之差小于 Wish_Timeout，THE Wish_Director SHALL 在恢复完成后 1 秒内恢复该 Wish 及其 Wisher 头顶的 Wish_Bubble。Chair_Wish 和 Lamp_Wish 的 Wish_Timeout 从保存的创建时间起算，不从启动时刻起算；Flower_Wish 不受 Wish_Timeout 约束（Requirement 8 第 5 条），Story_Director 按 v1 R22 第 9、10 条从保存的 Story_Stage 继续，Story_Round 编号等于保存的已开始过的 Flower_Wish 次数。
4. WHEN Windowfolk_App 启动并恢复出 `active` 的 Visit_Wish，且 Story_Clock 当前时间与保存的创建时间之差小于 Wish_Timeout，THE Wish_Director SHALL 在当前 Eligible_Window 中查找所属应用名称与保存值完全相同、且不是任何 Resident 的 Home_Window 的窗口，作为 Visit_Target。有多个窗口符合时，取窗口层级最靠前的那个，并在其最长一段 Window_Ledge 的中点上方显示 Visit_Flag。IF 没有符合条件的窗口，THEN THE Wish_Director SHALL 把该 Visit_Wish 设为 `dropped`，不显示它的 Wish_Bubble 和 Visit_Flag。
5. IF `world.json` 的格式版本号不是 2（包括 v1 存档），THEN THE Persistence SHALL 按 v1 R22.12 把原文件重命名为带时间戳的备份文件，再按 v1 R22.11 重新开局，不做迁移。新开局时 Unlocked_Decor 为空集，Ground 上没有 Decor。
6. FOR ALL 合法的 V2 世界状态（Decor 数量在 0 到 Max_Decor_Count 之间，`active` Wish 满足 Requirement 6 的约束），THE Persistence 先保存再读取 SHALL 得到与保存前相等的世界状态，第 1 条所列的每一项都相等（往返属性）。
7. THE Persistence SHALL 不把 LLM_Settings 中的 API Key 写入 `world.json`；任何 `world.json` 的内容中都不出现所配置的 API Key 字符串。
8. IF Windowfolk_App 启动时恢复出的某个 `active` Wish（Flower_Wish 以外的任意 Wish_Type）满足 Story_Clock 当前时间与保存的创建时间之差大于或等于 Wish_Timeout，THEN THE Wish_Director SHALL 在恢复完成后 1 秒内把该 Wish 设为 `dropped`，不显示它的 Wish_Bubble 或 Visit_Flag，并把对应 Wisher 的上一个 Wish 结束时间记为放弃的时刻。
9. WHEN Windowfolk_App 启动并恢复出某位 Resident 的上一个 Wish 结束时间，THE Wish_Director SHALL 以该时间为起点计算 Wish_Cooldown；在 Story_Clock 当前时间与该时间之差达到 Wish_Cooldown 之前，不让这位 Resident 提出新的 Wish。
10. WHEN Windowfolk_App 启动并按 v1 R22.7 让 Resident 落位，THE Windowfolk_App SHALL 不让任何 Resident 处于 `sitting`、`sleeping` 或 `running` 状态，并恢复其保存的 Walk_Distance；这位 Resident 不是 Busy_Resident 时，由 Activity_Planner 重新为其选择 Activity。
11. IF Windowfolk_App 退出时存在 `active` 的 Chase_Wish，THEN THE Persistence SHALL 不保存该 Chase_Wish 及其 Chase_Phase、追逐计时和 Flee_Target；下次启动时 THE Wish_Director SHALL 不恢复任何 Chase_Wish，两位居民都不是 Busy_Resident，各自的上一个 Wish 结束时间按存档中的值恢复，不因这次未完成的追逐而改变。

### Requirement 16: 素材与气泡图形扩充

**User Story:** 作为美术制作者，我希望 V2 新增的物件和状态都有明确的素材规格，这样可以继续用 PNG 替换占位图。

#### Acceptance Criteria

1. THE Asset_Provider SHALL 在 v1 R25.2 的清单之外，为以下 16 项各提供一个占位图形，任何一项都不缺图：Resident_A 的 `sitting`、Resident_A 的 `sleeping`、Resident_A 的 `running`、Resident_B 的 `sitting`、Resident_B 的 `sleeping`、Resident_B 的 `running`、Chair、Lamp 不发光外观、Lamp 发光外观、Visit_Flag，以及「椅子」「台灯」「小旗」「花朵」「Zzz」「脚印」6 个图标气泡。Requirement 4 第 8 条和 Requirement 22 第 3 条使用的心形气泡沿用 v1 已有的心形气泡图形，不计入本清单。
2. THE Asset_Provider SHALL 让第 1 条中 Resident_A 的 `sitting`、`sleeping`、`running` 占位图形沿用 v1 R25.1 中 Resident_A 的颜色和耳形，Resident_B 的沿用 Resident_B 的颜色和耳形；同一居民的 `sitting`、`sleeping`、`running` 占位图形两两不同，也与该居民 v1 的 9 个 Resident_State 图形都不同；Lamp 的发光与不发光两种占位图形也彼此不同。
3. THE `docs/art-spec.md` SHALL 为第 1 条列出的 16 项分别写明像素尺寸（宽 × 高）、帧数和文件名，不能遗漏；这些文件名两两不同，也不与 v1 R25.8 已有的任何文件名重复。
4. THE Asset_Provider SHALL 对第 1 条的 16 项新图形沿用 v1 R25 第 3 至 6 条的尺寸一致、加载和回退规则，即某一项 PNG 缺失或不合规时只有该项使用占位图形。
5. WHILE Night，THE Overlay SHALL 用 Lamp 发光外观绘制场上每个 Lamp；WHILE 不处于 Night，THE Overlay SHALL 用 Lamp 不发光外观绘制每个 Lamp。
6. THE Overlay SHALL 用与图标气泡相同的气泡底框绘制 Thought 文字气泡，文字只占一行，不换行、不省略、不被裁切。
7. THE Overlay SHALL 让 Thought 文字气泡的宽度等于文字宽度加左右内边距，且不小于图标气泡的宽度；两条字素数不同的 Thought 中，字素数较多的那条气泡宽度不小于字素数较少的那条（假设两条使用相同字符类别），含 Thought_Max_Length 个字素的 Thought 也完整显示在一行内。

### Requirement 17: 调试菜单（V2 版本）

**User Story:** 作为开发者和演示录制者，我希望能直接触发各种心愿和昼夜，这样录演示不用等待。

#### Acceptance Criteria

1. THE Debug_Menu SHALL 在 v1 R26 的四项之外提供「触发心愿」子菜单、「昼夜」子菜单和「解锁全部物件」一项，并把 v1 的「重新开始剧情」更名为「重置世界」。「触发心愿」子菜单依次包含送花、椅子、台灯、去看看、追逐五项：椅子、台灯、去看看、追逐四项各有「都都」（Resident_A）和「嘟嘟」（Resident_B）两个子项，子项决定 Wisher（追逐的 Chaser 和 Runner 仍按 Requirement 20 第 2 条固定）；送花只有一个子项，即按 Requirement 8 第 1 条确定的下一次 Flower_Wish 的 Giver。「昼夜」子菜单包含自动、白天、夜晚三项，对应 Day_Night_Override 的三个取值，当前选中项前显示勾选标记，其余两项不显示。所有菜单项在任意 Wish_State 和 Story_Stage 下都可以选择。
2. WHEN 玩家在「触发心愿」中选择某个子项，且该子项满足生成前提，THE Wish_Director SHALL 在选择后 1 秒内为该子项对应的居民生成一个该 Wish_Type 的 `active` Wish，同时显示该居民的 Wish_Bubble；生成时不检查 Wish_Cooldown、Wish_Spawn_Chance、Walk_Distance、Night 和 Round_Interval。生成前提如下：送花要求两位居民都不是 Busy_Resident；椅子和台灯要求对应居民不是 Busy_Resident；去看看要求对应居民不是 Busy_Resident，并且至少存在一个可作为 Visit_Target 的 Eligible_Window；追逐要求两位居民都不是 Busy_Resident，并且两位居民都不处于 `falling` 或 `hanging` 状态（不检查两人之间是否有路线）。
3. IF 玩家在「触发心愿」中选择某个子项时，第 2 条列出的该子项生成前提有任意一项不满足，THEN THE Wish_Director SHALL 不生成 Wish，所有 Wish、Busy_Resident 身份、Unlocked_Decor 和 Resident_State 保持不变，Event_Log 也不写入 Wish 相关记录。
4. WHEN 玩家在「昼夜」子菜单中选择某一项，THE Windowfolk_App SHALL 在选择后 1 秒内按该项判定 Night：选「夜晚」时始终判定为 Night，选「白天」时始终判定为非 Night，选「自动」时按 Local_Clock 与 Night_Start、Night_End 判定。每次 Windowfolk_App 启动时，「昼夜」恢复为「自动」。
5. WHEN 玩家选择「解锁全部物件」，THE Windowfolk_App SHALL 在 1 秒内把 `chair` 和 `lamp` 中尚未解锁的项加入 Unlocked_Decor，Toolbox 随即为这两种 Decor_Type 各显示一个 Decor_Slot。每个新加入的 Decor_Type 按 Requirement 1 第 4 条写一条 `decor_unlocked` 记录。原本已在 Unlocked_Decor 中的 Decor_Type 不重复加入，也不重复写记录。
6. WHEN 玩家选择「重置世界」，THE Windowfolk_App SHALL 在 1 秒内完成以下处理：执行 v1 R20.6 的处理；清除场上全部 Decor；清除全部 Wish，连同 Wish_Bubble、Visit_Flag 和所有居民的 Busy_Resident 身份；把 Unlocked_Decor 设为空集合；把已开始过的 Flower_Wish 次数和每位居民的 Walk_Distance 都归零；清除每位居民的上一个 Wish 结束时间，使其视为从未参与过 Wish；清除上一个 Flower_Wish 进入 `Done` 的时间。`events.jsonl` 和 `diary.jsonl` 的内容保持不变，「昼夜」子菜单的当前选择也保持不变。在任意 Wish_State 和 Story_Stage 下选择「重置世界」，结果都相同。

### Requirement 18: 事件记录扩充

**User Story:** 作为开发者，我希望新玩法的关键事件也写进事件记录，这样日记和小心思有素材可用。

#### Acceptance Criteria

1. WHEN 发生 `decor_unlocked`、`decor_placed`、`decor_removed`、`wish_started`、`wish_fulfilled`、`wish_dropped`、`visited`、`sat`、`slept`、`woke`、`thought_shown` 中任一事件，THE Event_Log SHALL 在 v1 R21.1 的事件列表之外，为该次事件向 `events.jsonl` 末尾追加恰好一行记录；记录格式、字段集合（`time`、`type`、`actor`、`target`、`detail`）、窗口只记应用名称不记标题的规则，以及写入方式沿用 v1 R21 第 2 至 11 条；本条与 v1 R21.1 两个列表之外的事件不写入。
2. WHEN 一个 Wish 变为 `active`、`fulfilled` 或 `dropped`，THE Event_Log SHALL 分别写入一条 `wish_started`、`wish_fulfilled` 或 `wish_dropped` 记录：`actor` 为 Wisher；Flower_Wish 的 `target` 为 Receiver，Chase_Wish 的 `target` 为另一位居民，Visit_Wish 的 `target` 为 Visit_Target 所属应用名称，Chair_Wish 和 Lamp_Wish 的 `target` 为 JSON `null`；`detail` 中包含 Wish_Type，Chase_Wish 的 `wish_fulfilled` 记录的 `detail` 中另含 Chase_Outcome。同一次世界更新中产生多条记录时，`wish_started` 写在由它引起的 `decor_unlocked`（Requirement 1 第 2、3 条）之前；`sat`、`slept` 和 Requirement 9 第 6 条的 `visited` 写在由它们引起的 `wish_fulfilled`（Requirement 7 第 3、6 条，Requirement 9 第 6 条）之前。
3. WHEN 居民按 Requirement 4 第 9 条进入 `sitting`（包括 Requirement 7 第 3 条中 Chair_Wish 的 Wisher），THE Event_Log SHALL 写入恰好一条 `sat` 记录：`actor` 为该居民，`target` 为所坐 Chair 的标识，`detail` 为空对象；居民离开 `sitting`（包括坐满 Sit_Duration、按 Requirement 3 第 8 条被拖走 Chair、按 Requirement 4 第 12 条成为 Busy_Resident）时不写入任何记录。
4. WHEN Decor 相关事件发生，THE Event_Log SHALL 按以下规则写入：`decor_unlocked`（Requirement 1 第 4 条）的 `actor` 和 `target` 为 JSON `null`，`detail` 中包含 Decor_Type；`decor_placed`（Requirement 3 第 10 条）在玩家松开 Decor 后该 Decor 附着到 Surface 或下落落地时写入恰好一条，`actor` 为玩家，`target` 为该 Decor 的标识，`detail` 中包含 Decor_Type 和 Surface 类型（Window_Ledge、Plank 或 Ground）；`decor_removed`（Requirement 3 第 4 条）的 `actor` 为玩家，`target` 为该 Decor 的标识，`detail` 中包含 Decor_Type。Decor 因所附着窗口变为 Closed_Window、Window_Ledge 消失或 Plank 失效而被动下落，以及启动时按 Requirement 15 第 2 条落到 Ground 上，都不写入 `decor_placed`。
5. WHEN 发生 `visited`、`slept` 或 `thought_shown` 事件，THE Event_Log SHALL 按以下规则写入：按 Requirement 4 第 8 条完成的 `visit_neighbor` 每次只写入一条 `visited`，在停留 Visit_Stay_Duration 结束时写入，`actor` 为执行 `visit_neighbor` 的居民，`target` 为被拜访的居民；按 Requirement 9 第 6 条完成的 Visit_Wish 写入的 `visited` 中，`actor` 为 Wisher，`target` 为 Visit_Target 所属应用名称；两种 `visited` 的 `detail` 中都包含来源（`visit_neighbor` 或 Visit_Wish）。`slept`（Requirement 5 第 4 条）的 `actor` 为该居民，`target` 为目标 Lamp 的标识。`thought_shown`（Requirement 14 第 8 条）只在 Thought 实际显示时写入，按 Requirement 14 第 3、5 条被丢弃或未生成的 Thought 不写入。
6. WHEN 处于 `sleeping` 状态的居民因任何原因离开 `sleeping`（Requirement 5 第 7 条 Night 结束、Requirement 5 第 8 条 Lamp 被移走或下落或所在 Surface 消失、Requirement 4 第 12 条成为 Busy_Resident），THE Event_Log SHALL 写入恰好一条 `woke` 记录：`actor` 为该居民，`target` 为 JSON `null`，`detail` 中包含离开原因（Night 结束、Lamp 移走或下落、Surface 消失、成为 Busy_Resident 四者之一）。

### Requirement 19: 可测试性与性能

**User Story:** 作为开发者，我希望新增逻辑同样能脱离 AppKit 测试，并且不拖慢电脑，这样 V2 和 v1 一样可靠。

#### Acceptance Criteria

1. THE `WindowfolkCore` SHALL 包含 Activity_Planner、Wish_Director、追逐规则（Chase_Phase 推进、Flee_Target 选择、抓到与撑满判定）、Decor 规则（摆放、收回 Toolbox、Max_Decor_Count 上限、Chair 同一时刻最多 1 位居民坐）、Diary_Writer 的模板生成、Diary_Store 的 JSONL 编解码、Thought_Engine 的文本校验（含 Thought_Max_Length 检查），以及 Local_Clock 和 LLM_Client 的接口定义；`WindowfolkCore` 的任一源文件都不导入 AppKit 和 SpriteKit。
2. THE `WindowfolkCore` SHALL 提供两种测试替身：一是 Local_Clock 实现，测试可以把它设为任意本地日期和时刻，也可以把它向前推进任意时长；二是假 LLM_Client，它按测试预设返回指定文本、返回失败或模拟超过 LLM_Request_Timeout 的超时，并记录收到的请求次数和每次的 Prompt_Payload。测试用这两种替身推进 Night_Start、Night_End、Wish_Timeout、Wish_Cooldown、Sit_Duration、Thought_Min_Interval、Chase_Ready_Duration、Chase_Duration 等时长时不需要实际等待，也不发起网络请求。
3. THE `WindowfolkCore` SHALL 允许测试注入带固定种子的随机数源，供 Wish_Director 使用（判定 Wish_Spawn_Chance、选择 Wish_Type 和 Visit_Target），也供 Activity_Planner 使用（选择 Activity、决定 `wander` 的持续时长）。两次测试运行注入相同种子、相同初始状态和相同的 Local_Clock 推进序列时，产生的 Wish 序列与 Activity 序列完全相同。
4. THE `WindowfolkCore` SHALL 允许测试为 Diary_Store 和 LLM_Settings 指定其他存储位置，使 `swift test` 不读取也不修改 `~/Library/Application Support/Windowfolk/` 下的 `diary.jsonl`、`world.json` 及 LLM_Settings 的存储内容。
5. THE `WindowfolkCore` 的测试目标 SHALL 为 Activity_Planner、Wish_Director、追逐规则、Decor 规则、Diary_Writer、Diary_Store 和 Thought_Engine 各包含至少 1 个测试用例，并且至少有 1 个测试用例在假 LLM_Client 返回失败时验证 Diary_Writer 生成的 Diary_Entry 生成方式为 `template`。
6. WHEN 开发者在项目根目录运行 `swift test`，THE 测试运行 SHALL 以退出码 0 完成，并满足以下全部条件：全部测试通过（包括按 V2 行为更新后的 v1 测试）；从命令开始到结束总耗时不超过 90 秒；过程中不需要屏幕录制或辅助功能权限；不创建 Overlay 或任何屏幕窗口；不发起任何网络请求。
7. WHILE 桌面处于 V2 静止状态，且 LLM_Settings 中「小心思」和「日记使用 LLM」均关闭，THE Windowfolk_App SHALL 在 Apple Silicon Mac 上保持 60 秒平均 CPU 占用不超过 Idle_CPU_Budget（与 v1 R29.1 相同的预算口径）。V2 静止状态指连续 60 秒内同时满足以下各项：v1 R29.1 的全部条件，其中居民状态条件放宽为每位 Resident 处于 `idle`、`waiting`、`sitting` 或 `sleeping` 状态且位置不变；玩家没有拖拽 Item 或 Decor；场上 Decor 的数量和位置不变；没有 Wish 被生成、完成或放弃；Night 与非 Night 之间没有切换。CPU 占用按单核百分比计，取「活动监视器」中 Windowfolk_App 进程「% CPU」列在这 60 秒内的平均读数。
8. WHILE 连续 2 秒内同时满足以下四项：每次 Window_Snapshot 与上一次相比，Eligible_Window 集合、各窗口的边界矩形和前后层级都没有变化；每位 Resident 的 Resident_State 和屏幕位置都没有变化，处于 `sitting` 或 `sleeping` 状态的 Resident 同样适用；玩家没有拖拽 Item 或 Decor；场上 Decor 的数量和位置都没有变化；THE Game_Loop SHALL 以 Idle_Poll_Rate 轮询窗口，任意连续 1 秒内的轮询次数在 Idle_Poll_Rate ±1 次以内（扩展 v1 R24.2）。

### Requirement 20: 追逐心愿的生成与开始

**User Story:** 作为玩家，我希望都都和嘟嘟偶尔想玩一场猫捉老鼠，这样桌面上会突然热闹起来，我可以顺手参与。

#### Acceptance Criteria

1. WHEN Wish_Director 按 Requirement 6 第 2 条检查某位居民，THE Wish_Director SHALL 仅在以下 4 个条件同时成立时判定该居民满足 Chase_Wish 生成条件：（a）当前不是 Night；（b）另一位居民不是 Busy_Resident，且不处于 `falling` 或 `hanging` 状态；（c）另一位居民距其上一个 Wish 变为 `fulfilled` 或 `dropped` 已满 Wish_Cooldown（从未参与过 Wish 的居民视为已满足）；（d）Nav_Graph 中存在从 Resident_A 当前所在 Surface 到 Resident_B 当前所在 Surface 的路线，两人位于同一条 Surface 时视为路线存在。任一条件不成立时，Chase_Wish 不计入该居民按 Requirement 6 第 5 条可选的 Wish_Type。两位居民都可以成为 Chase_Wish 的 Wisher。同一次检查中，THE Wish_Director SHALL 先检查 Resident_A 再检查 Resident_B，使先生成的 Wish 在检查后一位居民时已计入 Busy_Resident 身份。
2. WHEN 一个 Chase_Wish 变为 `active`（包括按 Requirement 17 第 2 条从 Debug_Menu 触发的 Chase_Wish），THE Wish_Director SHALL 在同一次世界更新中完成以下设置：把 Resident_A 设为 Chaser、Resident_B 设为 Runner（与 Wisher 是哪一位无关）；把两位居民都设为 Busy_Resident，并按 Requirement 4 第 12 条结束两人的当前 Activity；把 Chase_Phase 设为 `ready`，并记录此刻的 Story_Clock 时间作为 `ready` 开始时间；按 Requirement 18 第 2 条写入一条 `wish_started` 记录，`actor` 为 Wisher，`target` 为另一位居民，`detail` 中包含 Wish_Type `chase`。
3. WHILE Chase_Phase 为 `ready`，THE Chaser 和 Runner SHALL 在 Chase_Wish 变为 `active` 后 1 帧内停止水平移动并处于 `idle` 状态，每帧按对方屏幕 x 坐标更新朝向（对方 x 坐标较小时朝左，较大时朝右，相等时保持当前朝向）；只有 Wisher 头顶按 Requirement 6 第 9 条显示以图形绘制的「脚印」图标 Wish_Bubble（不含文字），另一位居民头顶不显示 Wish_Bubble。
4. WHEN 按 Story_Clock 从 `ready` 开始时间算起已满 Chase_Ready_Duration（2 秒），THE Wish_Director SHALL 在同一次世界更新中把 Chase_Phase 设为 `running`，并记录此刻的 Story_Clock 时间作为追逐开始时间；从这次世界更新起，Chaser 和 Runner 按 Requirement 21 行动。`ready` 期间两人之间的路线消失、任一居民下落或所在窗口成为 Hidden_Window，都不暂停也不重置 Chase_Ready_Duration 计时。
5. WHILE 一个 Chase_Wish 为 `active`，THE Wish_Director SHALL 让 Chaser 和 Runner 两位居民都不参与其他 Wish，也不为任何一位生成其他 Wish（由 Requirement 6 第 7 条和本条第 2 条的 Busy_Resident 身份保证）；Flower_Wish 按 Requirement 8 第 1 条（a）不生成。
6. WHILE 一个 Chase_Wish 为 `active`，THE Wish_Director SHALL 让该 Chase_Wish 保持 `active`，直到按 Requirement 22 第 1、2 条得出 Chase_Outcome，或玩家选择「重置世界」；THE Wish_Director SHALL 不按 Requirement 6 第 11 条（Wish_Timeout）或第 12 条（场景前提消失）把 Chase_Wish 设为 `dropped`，Night 在追逐途中开始也不影响该 Chase_Wish。
7. FOR ALL Wish 生成与结束序列，THE Wish_Director SHALL 在每次世界更新结束时满足：至多存在 1 个 `active` Chase_Wish；存在 `active` Chase_Wish 时不存在其他 `active` Wish；`active` Chase_Wish 的 Chaser 为 Resident_A、Runner 为 Resident_B（不变量）。
8. IF Chase_Wish 变为 `active` 时 Chaser 或 Runner 处于 `climbing` 状态，或 Chase_Phase 为 `ready` 期间任一居民按 v1 R6 进入 `falling` 或 `hanging`，THEN THE 该居民 SHALL 按 v1 规则完成攀爬或下落，在落到某条 Surface 上的同一帧停止水平移动，并按第 3 条转为 `idle`、面朝对方；Chase_Phase 仍按第 4 条在 Chase_Ready_Duration 到时变为 `running`，届时仍处于 `climbing`、`falling` 或 `hanging` 的居民按 Requirement 21 第 9 条处理。
9. WHEN 玩家在 Chase_Phase 为 `ready` 时点击 Chaser 或 Runner，THE Resident SHALL 只显示「?」气泡 1.5 秒，不跳跃，保持 `idle` 状态、位置和朝向不变；Chase_Phase 和 Chase_Ready_Duration 计时不受影响（与 Requirement 21 第 8 条一致，扩展 v1 R7.8 的状态列表）。Wish_Bubble 的隐藏与恢复按 Requirement 10 第 6 条处理。

### Requirement 21: 追与逃

**User Story:** 作为玩家，我希望用搭拆木板梯子和拖动窗口去帮嘟嘟跑或帮都都追，不用先选边，这样怎么玩全看我当下的心情。

#### Acceptance Criteria

1. WHILE Chase_Phase 为 `running`，THE Chaser SHALL 在 Surface 上水平移动时处于 `running` 状态，水平速度等于其空手 `walking` 速度乘以 Chaser_Speed_Factor（1.6）；THE Runner SHALL 在 Surface 上水平移动时处于 `running` 状态，水平速度等于其空手 `walking` 速度乘以 Runner_Speed_Factor（1.5）。在任意连续 1 秒的水平移动中，实测水平位移与「速度 × 时长」之差不超过 5%。小跳、往下跳、`climbing`、`hanging` 和 `falling` 沿用 v1 的规则和速度，期间不处于 `running` 状态。
2. WHILE Chase_Phase 为 `running`，且 Nav_Graph 中存在从 Chaser 当前所在 Surface 到 Runner 当前所在 Surface 的路线，THE Chaser SHALL 以 Runner 当前所在 Surface 和屏幕 x 坐标为目标，沿水平总长度最短的路线移动。相邻两次按 Runner 最新位置重新规划的间隔不超过 Chase_Replan_Interval（0.5 秒）。Nav_Graph 发生变化（Plank 或 Ladder 被架设、拆除或失效，窗口移动、改变大小、成为 Hidden_Window 或 Closed_Window）后，Chaser 在 Chase_Replan_Interval 内改用新路线。
3. IF Chase_Phase 为 `running` 时 Nav_Graph 中不存在从 Chaser 当前所在 Surface 到 Runner 当前所在 Surface 的路线，THEN THE Chaser SHALL 在 1 帧内停止水平移动、进入 `waiting` 状态并面朝 Runner（以 Runner 屏幕 x 坐标判定朝向），不显示「...」气泡，也不显示其他新气泡；追逐计时继续累计；路线重新出现后，Chaser 在 Chase_Replan_Interval 内离开 `waiting`，并按第 2 条继续追。
4. WHILE Chase_Phase 为 `running`，且 Chaser 有路线可达 Runner 当前所在 Surface，THE Runner SHALL 从 Chase_Candidate_Point 中重新选择 Flee_Target。相邻两次选择的间隔不超过 Chase_Replan_Interval，Nav_Graph 发生变化后也在 Chase_Replan_Interval 内重新选择。选出后，Runner 沿自己到 Flee_Target 水平总长度最短的路线移动。路线水平总长度包括起点 Surface 上从当前 x 坐标到离开点的水平距离、途经各边的水平距离，以及终点 Surface 上到候选点的水平距离。选择规则依次为：取 Chaser 当前位置到该点的 Nav_Graph 路线水平总长度最大的点，Chaser 没有路线可达的候选点视为长度大于任何可达候选点；并列时，取 Runner 到该点路线水平总长度较小的点；仍并列时，取屏幕 x 坐标较小的点。
5. FOR ALL Nav_Graph、Chaser 位置和 Runner 位置的组合（Chaser 有路线可达 Runner 当前所在 Surface），THE Runner 按第 4 条选出的 Flee_Target SHALL 是 Chase_Candidate_Point 中 Chaser 路线水平总长度最大值的点之一（Chaser 不可达的点按第 4 条视为最大）；对同一组输入重复选择，结果相同（确定性）。
6. WHILE Chase_Phase 为 `running` 且 Nav_Graph 中不存在从 Chaser 当前所在 Surface 到 Runner 当前所在 Surface 的路线，THE Runner SHALL 在 1 帧内停止水平移动、转为 `idle` 并面朝 Chaser（以 Chaser 屏幕 x 坐标判定朝向），追逐计时继续累计；路线重新出现后，Runner 在 Chase_Replan_Interval 内按第 4 条继续跑。
7. WHILE Chase_Phase 为 `ready` 或 `running`，THE Windowfolk_App SHALL 按 Requirement 10 第 1 条让玩家使用全部已有操作，并对 Chaser 和 Runner 一视同仁。玩家的每次操作只通过改变 Nav_Graph 和窗口位置影响追逐。Windowfolk_App 不弹出询问或选边界面；Event_Log 的任何记录中，都不包含表示玩家帮助哪一方的字段或值。
8. WHEN 玩家在 Chase_Phase 为 `running` 期间点击 Chaser 或 Runner，且该居民处于 `running`、`waiting` 或 `idle` 状态，THE Resident SHALL 只显示「?」气泡 1.5 秒，不跳跃，Resident_State、目标、Flee_Target、路线和追逐计时都不受影响（扩展 v1 R7.8 的状态列表）。
9. WHEN Chaser 或 Runner 在 Chase_Phase 为 `running` 期间因所在窗口关闭、Window_Ledge 消失或 Plank 失效而按 v1 R6 下落并落地，且该 Chase_Wish 仍为 `active`，THE Resident SHALL 在落地后 1 秒内按第 2 至 4 条或第 3、6 条继续追逐；追逐计时在下落期间继续累计。
10. WHILE Chaser 或 Runner 所附着的窗口为 Hidden_Window，THE Windowfolk_App SHALL 按 v1 R5.3 暂停该居民的行动，追逐计时继续累计；另一位居民按第 3 条或第 6 条处理（v1 R5.5 使该窗口的通路不在 Nav_Graph 中）。该窗口不再是 Hidden_Window 后，两位居民在 Chase_Replan_Interval 内按第 2 至 6 条恢复。
11. WHEN Chase_Phase 为 `running`、Chaser 有路线可达 Runner 当前所在 Surface，且 Runner 已站在 Flee_Target 所在 Surface 上，与 Flee_Target 的屏幕 x 坐标之差不超过 1pt，THE Runner SHALL 停止水平移动、转为 `idle` 并面朝 Chaser。之后按第 4 条重新选择 Flee_Target：选出不同的点时，在 Chase_Replan_Interval 内以 `running` 状态出发；选出的点不变时，保持 `idle`。

### Requirement 22: 追逐的结束与反馈

**User Story:** 作为玩家，我希望不论抓到还是没抓到都是开心的结局，这样追逐只是一场游戏，没有输赢的压力。

#### Acceptance Criteria

1. WHILE Chase_Phase 为 `running`，WHEN 某次世界更新结束时以下条件同时成立：Chaser 与 Runner 位于同一条 Surface；两者都不处于 `falling`、`hanging` 或 `climbing` 状态；两者所附着的窗口都不是 Hidden_Window；两者屏幕 x 坐标之差的绝对值不超过 Catch_Distance（16pt，含边界）；THE Wish_Director SHALL 在同一次世界更新中把 Chase_Outcome 设为 `caught`。Chase_Phase 为 `ready` 时，即使上述条件成立，THE Wish_Director 也 SHALL 不判定 `caught`。
2. WHILE Chase_Phase 为 `running`，WHEN 按 Story_Clock 从追逐开始时间（Requirement 20 第 4 条）算起已满 Chase_Duration（60 秒），且尚未按第 1 条得出 `caught`，THE Wish_Director SHALL 在同一次世界更新中把 Chase_Outcome 设为 `escaped`。下落、`waiting`、Hidden_Window 暂停期间，该计时都继续累计（与 Requirement 21 第 3、9、10 条一致）。同一次世界更新中第 1 条和本条条件同时成立时，取 `caught`。
3. WHEN 一个 Chase_Wish 得出 Chase_Outcome，THE Wish_Director SHALL 在同一次世界更新中完成以下处理：把该 Chase_Wish 设为 `fulfilled`；隐藏 Wish_Bubble；按 Requirement 18 第 2 条写入恰好一条 `wish_fulfilled` 记录，`actor` 为 Wisher，`target` 为另一位居民，`detail` 中包含 Wish_Type 和 Chase_Outcome；结束 Chaser 和 Runner 两位居民的 Busy_Resident 身份；以此刻的 Story_Clock 时间作为两位居民 Wish_Cooldown 的起点；让两位居民都离开 `running` 和 `waiting` 状态。两位居民中不处于 `falling`、`hanging` 或 `climbing` 状态、且所附着窗口不是 Hidden_Window 的，在同一帧内停止水平移动，并一起播放一次 `celebrating` 动画，播放期间头顶显示心形气泡，动画结束的同一帧心形气泡消失（本条取代 Requirement 6 第 10 条中只有 Wisher 庆祝的规则）。不满足上述条件的居民不播放 `celebrating` 动画，也不显示心形气泡。
4. THE Wish_Director SHALL 对 `caught` 和 `escaped` 两种 Chase_Outcome 使用相同的气泡图形、相同的 `celebrating` 动画和相同的播放时长；两种结局在 Overlay 上的显示没有任何差别，只在 `wish_fulfilled` 记录 `detail` 中的 Chase_Outcome 值上不同。
5. WHILE 从一个 Chase_Wish 变为 `active` 起，到第 3 条中所有庆祝居民的 `celebrating` 动画都结束为止（没有居民庆祝时到 Chase_Wish 变为 `fulfilled` 的那次世界更新为止），THE Windowfolk_App SHALL 按 Requirement 10 第 4 条，在 Overlay、Toolbox、Status_Menu 和 Wish_Bubble 中只显示 Requirement 20 第 3 条的「脚印」Wish_Bubble 和本节第 3 条的心形气泡与 `celebrating` 动画，不显示 Chase_Duration 的剩余时间、Chase_Outcome、胜负、抓到次数或撑满次数，也不显示任何文字（Thought 按 Requirement 14 另行处理）。
6. WHEN 第 3 条的 `celebrating` 动画结束，或第 3 条中未庆祝的居民离开 `falling`、`hanging`、`climbing` 状态，或其所附着窗口不再是 Hidden_Window，THE Activity_Planner SHALL 按 Requirement 4 第 2 条在 1 秒内为该居民选择下一个 Activity；此后该居民的水平移动速度恢复为 v1 的 `walking` 速度，且在下一个 Chase_Wish 的 Chase_Phase 变为 `running` 之前不再进入 `running` 状态。该居民的 Walk_Distance 保留追逐期间按 Requirement 4 第 14 条累计的值，不因追逐结束而归零。
7. WHEN 玩家在 Chase_Wish 为 `active`（Chase_Phase 为 `ready` 或 `running`）时选择「重置世界」，THE Windowfolk_App SHALL 按 Requirement 17 第 6 条清除该 Chase_Wish 及其 Chase_Phase、追逐计时和 Flee_Target，并在同一次处理中让处于 `running` 或 `waiting` 状态的 Chaser 和 Runner 转为 `idle`；不得出 Chase_Outcome，不播放 `celebrating` 动画，不显示心形气泡，不写入 `wish_fulfilled` 或 `wish_dropped` 记录。
8. WHILE 「日记使用 LLM」关闭，THE Diary_Writer SHALL 按 Requirement 13 第 5 条，为 Chase_Wish 的 `wish_fulfilled` 记录从 4 种固定句式中选择一种：按 Chase_Outcome（`caught` 或 `escaped`）以及写日记的居民是 Chaser 还是 Runner 确定。Chaser 在 `caught` 时用「我抓到了对方」的句式，在 `escaped` 时用「我没抓到对方」的句式；Runner 在 `caught` 时用「我被抓到了」的句式，在 `escaped` 时用「我没被抓到」的句式。4 种句式都不包含「输」「赢」「失败」这几个字。输入相同的居民和相同的事件序列时，生成的句子逐字符相同。
9. FOR ALL Chase_Wish，THE Wish_Director SHALL 使每个 Chase_Wish 至多得出 1 次 Chase_Outcome，并至多写入 1 条 `wish_fulfilled` 记录。得出 Chase_Outcome 之后，不再按第 1、2 条重新判定，Chase_Outcome 也不再改变。被第 7 条清除的 Chase_Wish 不得出 Chase_Outcome（不变量）。
