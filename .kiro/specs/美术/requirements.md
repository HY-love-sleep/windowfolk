# Requirements Document

## Introduction

窗间 · Windowfolk 的 v1 与 V2 玩法已全部实现，但画面上的居民、物件和气泡仍是 `Sources/Windowfolk/AssetProvider.swift` 中程序绘制的占位图形，仓库根目录的 `Assets/` 为空。本 spec 为当前玩法制作全部美术素材：按 `docs/art-spec.md`（v2）的清单产出 45 个 PNG，放入 `Assets/` 并提交，使应用启动后不再使用任何占位图形。

已与项目所有者确定的范围：

- **画风**：柔和手绘 Q 版。2px 左右的深色描边、平涂加一层阴影、柔和粉彩配色，即 `docs/art-spec.md` 6.2 节的提示词前缀方向。角色设定沿用 `docs/art-spec.md` 第 1 节（都都：圆脸银渐层小猫；嘟嘟：金丝熊）。
- **生产方式**：在仓库内建立完整的出图流水线，包括提示词清单、调用图像模型的批量生成工具、后处理工具（去背景、切帧、对齐、缩放、拼成序列帧条）和校验工具。项目所有者在本机运行流水线、挑选候选图，最终图由流水线写入 `Assets/`。
- **图像模型**：默认 `gpt-image-2.5-flare`，模型名可用 Model_Variable 覆盖。API Key 只从环境变量读取，不进入仓库。
- **范围**：`AssetCatalog.all` 中的 45 项游戏内素材全部产出。菜单栏图标、App 图标和宣传图不在本次范围内。
- **中间产物**：模型原始输出和候选图只放在被 `.gitignore` 忽略的工作目录中；仓库只提交角色设定图、提示词清单、流水线代码和最终 45 个 PNG。

不变的约束：素材清单、尺寸、帧数和文件名以 `Sources/WindowfolkCore/AssetCatalog.swift` 为唯一来源；`AssetProvider` 的加载与回退规则（v1 R25 第 3 至 6 条、V2 R16 第 4 条）不改动；`WindowfolkCore` 不依赖 AppKit 或 SpriteKit（v1 R27.2）。

## Glossary

- **Asset_Catalog**：`Sources/WindowfolkCore/AssetCatalog.swift` 中的素材清单 `AssetCatalog.all`，共 45 项，每项给出素材键、每帧 pt 尺寸、帧数和平铺方式。
- **Asset_Key**：Asset_Catalog 中一项素材的键，例如 `resident_a_walking`；文件名为 Asset_Key 加 `.png`。
- **Expected_Pixel_Size**：Asset_Catalog 为一项素材给出的整张 PNG 像素尺寸：宽 = 每帧 pt 宽 × 2 × 帧数，高 = 每帧 pt 高 × 2。
- **Asset_Provider**：应用层 `AssetProvider`，启动时从素材目录加载 PNG，不合格的单项回退到占位图形。
- **Final_Asset**：`Assets/` 目录中、文件名与某个 Asset_Key 对应的 PNG。
- **Art_Pipeline**：本 spec 新增的出图流水线整体，由 Prompt_Manifest、Prompt_Composer、Image_Generator、Post_Processor、Asset_Validator 和 Preview_Builder 组成。
- **Art_Directory**：仓库根目录下存放流水线输入的目录 `art/`，包含 Prompt_Manifest 和 Character_Sheet，纳入版本控制。
- **Work_Directory**：存放模型原始输出、候选图和预览图的目录 `art/work/`，被 `.gitignore` 忽略。
- **Prompt_Manifest**：Art_Directory 中的文本文件，为每个 Asset_Key 写一条提示词条目，并写明公共提示词前缀和四组 Palette。
- **Prompt_Entry**：Prompt_Manifest 中对应一个 Asset_Key 的条目，包含动作或物件描述、帧数、帧的排列方式、所用参考图和生成画布尺寸。
- **Prompt_Manifest_Parser**：把 Prompt_Manifest 文本解析为结构化清单对象的组件。
- **Prompt_Manifest_Printer**：把结构化清单对象格式化为 Prompt_Manifest 文本的组件。
- **Prompt_Composer**：根据结构化清单对象为一个 Asset_Key 组合完整提示词（公共前缀、适用 Palette 色值和 Prompt_Entry 描述）的组件，供 Image_Generator 使用。
- **Resident_A**：居民都都，圆脸银渐层小猫，素材键前缀为 `resident_a_`。
- **Resident_B**：居民嘟嘟，金丝熊，素材键前缀为 `resident_b_`。
- **Resident_State**：居民的 12 种动画状态之一，每位居民每个 Resident_State 对应一个 Asset_Key，见 `docs/art-spec.md` 第 4 节。
- **Receiver**：许愿气泡所指向的另一位居民；`bubble_wish` 右半边由应用叠加 Receiver 的头像。
- **Overlay**：应用在桌面上绘制居民和物件的透明覆盖窗口。
- **Character_Sheet**：一位居民的角色设定图 PNG，存放在 Art_Directory 中，包含正面、朝右的侧面、背面三视图和一行颜色色块。Resident_A 和 Resident_B 各一张。
- **Palette**：Prompt_Manifest 中记录的一组固定颜色，以 `#RRGGBB` 十六进制色值表示。共四组：Resident_A、Resident_B（各含主色、阴影色、高光色、描边色、腮红色），木制物件、植物（各含主色、阴影色、高光色、描边色）。
- **Image_Generator**：Art_Pipeline 中调用图像模型 API、为 Prompt_Entry 生成原始大图的命令行工具。
- **Raw_Candidate**：Image_Generator 为一个 Asset_Key 生成的一张原始大图，存放在 Work_Directory 中。
- **Post_Processor**：Art_Pipeline 中把一张 Raw_Candidate 转成符合 Asset_Catalog 规格的 PNG 的命令行工具。
- **Processed_Candidate**：Post_Processor 输出的、尚未写入 `Assets/` 的 PNG，存放在 Work_Directory 中。
- **Promotion**：项目所有者选定一张 Processed_Candidate 后，Art_Pipeline 把该图写入 `Assets/` 成为 Final_Asset 的操作。
- **Asset_Validator**：Art_Pipeline 中检查 PNG 是否符合 Asset_Catalog 规格和本 spec 像素规则的命令行工具与对应的测试。
- **Preview_Builder**：Art_Pipeline 中把 PNG 拼成一张总览图、分别放在深色和浅色背景上的命令行工具，供项目所有者目视检查。
- **Opaque_Pixel**：alpha 值不小于 128 的像素。
- **Transparent_Pixel**：alpha 值为 0 的像素。
- **Grounded_State**：居民脚底应贴住每帧底边的 Resident_State：`idle`、`walking`、`carrying`、`waiting`、`running`。
- **Framed_Asset**：四角应透明的素材：全部居民素材、三张花、Fruit、全部气泡、Chair、Lamp 两种外观、Visit_Flag。Plank、Ladder 和 Toolbox 不属于 Framed_Asset。
- **API_Key_Variable**：存放图像模型 API Key 的环境变量 `OPENAI_API_KEY`。
- **Model_Variable**：指定图像模型名的环境变量 `WINDOWFOLK_IMAGE_MODEL`；未设置时使用默认模型名 `gpt-image-2.5-flare`。

## Requirements

### Requirement 1: 美术风格与角色设定

**User Story:** 作为项目所有者，我希望先定下画风、角色设定图和调色板，这样 45 张图看起来属于同一套美术。

#### Acceptance Criteria

1. THE Art_Directory SHALL 为 Resident_A 和 Resident_B 各包含恰好一张 Character_Sheet。每张都是带 alpha 通道的 PNG，上方一行从左到右依次排列正面、侧面（朝右）、背面三个视图，每个视图中角色不透明边界框的高度不小于 256 像素；下方一行是颜色色块，每个色块不小于 32×32 像素，按 Palette 的固定顺序（主色、阴影色、高光色、描边色、腮红色）为该居民的每个 Palette 颜色各画一块。
2. THE Prompt_Manifest SHALL 记录四组 Palette：Resident_A、Resident_B、木制物件（Plank、Ladder、Toolbox、花盆、Chair 共用）、植物。两组居民 Palette 各包含主色、阴影色、高光色、描边色、腮红色 5 个颜色；木制物件和植物 Palette 各包含主色、阴影色、高光色、描边色 4 个颜色。每个颜色写成 `#RRGGBB` 形式，即 `#` 后跟 6 位十六进制数字，大小写都可以。
3. THE Prompt_Manifest SHALL 包含一段所有 Prompt_Entry 共用的提示词前缀，内容与 `docs/art-spec.md` 6.2 节的方向一致，且逐项写明以下 10 点：柔和手绘 Q 版画风、2px 左右的深色描边、平涂加一层阴影、柔和粉彩配色、透明背景、居民朝右、脚底贴住底边、水平居中、画面中不出现文字、不画地面阴影和背景。
4. THE Character_Sheet SHALL 体现 `docs/art-spec.md` 第 1 节的角色设定。项目所有者按下列清单逐项确认，每一项都判为"符合"才算通过。Resident_A 的项目：圆脸、短鼻子；毛色从银白渐变到浅灰，背部和头顶略深，四肢和肚子偏白；三角形小耳朵，耳内粉色；翠绿或蓝绿色的大圆眼；蓬松尾巴，尖端略深。Resident_B 的项目：圆滚滚的身体；毛色金黄偏橘；肚子和嘴边奶白色；圆形小耳朵；黑亮小眼睛；鼓腮帮；前爪小，捧在胸前；几乎看不到尾巴。两位共同的项目：头部高度与身体（不含头部）高度之比在 0.8 到 1.25 之间（头身比约 1:1）；四肢很短。
5. THE Character_Sheet SHALL 让每个颜色色块中心像素的 RGB 值与 Prompt_Manifest 中该居民对应 Palette 颜色的 RGB 值完全相等。
6. IF Prompt_Manifest 缺少第 2 条列出的任一组 Palette、任一组 Palette 缺少第 2 条规定的颜色，或任一颜色值不符合 `#RRGGBB` 形式，THEN THE Prompt_Manifest_Parser SHALL 返回错误信息，指出缺失或格式错误的 Palette 组名和颜色名，并且不返回清单对象。
7. THE `docs/art-spec.md` SHALL 增加一节说明 Art_Pipeline 的使用步骤，按以下顺序列出：设置 API_Key_Variable（以及可选的 Model_Variable）、运行 Image_Generator、运行 Post_Processor、运行 Preview_Builder、执行 Promotion、运行 Asset_Validator。这一节还要写出两张 Character_Sheet 和 Prompt_Manifest 在仓库中的路径，并列出全部四组 Palette 的色值。每个路径都必须指向仓库中实际存在的文件，每个色值都必须与 Prompt_Manifest 中的对应值相等。

### Requirement 2: 提示词清单

**User Story:** 作为项目所有者，我希望每个素材都有一条写好的提示词，这样出图可以批量进行，也能在重新出某一张图时得到一致的结果。

#### Acceptance Criteria

1. THE Prompt_Manifest SHALL 为 Asset_Catalog 中的每个 Asset_Key 恰好包含一条 Prompt_Entry，共 45 条；同一 Asset_Key 不出现两条及以上，且不包含 Asset_Catalog 之外的 Asset_Key。
2. THE Prompt_Entry SHALL 包含以下四项内容，每项都不为空：动作或物件描述（1 至 1000 个字符）、帧数、帧的排列方式（固定为从左到右水平排列、帧间无间隔）和生成画布尺寸（以正整数像素宽 × 高给出）。
3. THE Prompt_Entry SHALL 让动作或物件描述覆盖 `docs/art-spec.md` 中该素材的说明。居民素材对照第 4 节对应 Resident_State 行的动作说明，其余素材对照第 5 节对应素材行的说明。项目所有者按 45 个 Asset_Key 逐条核对，并记录每条是否覆盖。
4. THE Prompt_Entry SHALL 让帧数与 Asset_Catalog 中该 Asset_Key 的帧数相等。
5. THE Prompt_Entry SHALL 让生成画布宽度除以帧数的结果不小于该 Asset_Key 的每帧像素宽（每帧 pt 宽 × 2），并让画布高度不小于每帧像素高（每帧 pt 高 × 2），保证 Post_Processor 只需缩小、不需放大。
6. WHERE 一个 Prompt_Entry 属于 Resident_A 的素材，THE Prompt_Entry SHALL 把 Resident_A 的 Character_Sheet 列为参考图，且不列入 Resident_B 的 Character_Sheet；WHERE 一个 Prompt_Entry 属于 Resident_B 的素材，THE Prompt_Entry SHALL 把 Resident_B 的 Character_Sheet 列为参考图，且不列入 Resident_A 的 Character_Sheet。参考图以 Art_Directory 中已存在的 PNG 文件路径给出。
7. THE Prompt_Entry SHALL 在两位居民的 `carrying` 条目中明确写出不画被抱的物件，在 `climbing` 条目中明确写出不画梯子，在 `sitting` 条目中明确写出不画椅子，共 6 条。
8. WHEN Prompt_Manifest 文件是 UTF-8 文本且满足第 1、2、4、6、13 条，并含有非空的公共提示词前缀和满足 Requirement 1 第 2 条的全部 Palette，THE Prompt_Manifest_Parser SHALL 把文件解析为一个结构化的清单对象。该对象包含公共前缀、全部 Palette，以及按 Asset_Catalog 顺序排列的 45 条 Prompt_Entry。
9. IF Prompt_Manifest 文件出现以下任一情况：无法解析、缺少某个 Asset_Key 的条目、同一 Asset_Key 重复、含有未知 Asset_Key、某条目缺少第 2 条要求的内容、某条目的帧数与 Asset_Catalog 不一致、参考图路径指向不存在的文件、居民条目引用了另一位居民的 Character_Sheet、非居民条目引用了任一居民的 Character_Sheet、某个 Palette 色值不是 `#RRGGBB` 形式，THEN THE Prompt_Manifest_Parser SHALL 不返回清单对象，并返回错误信息。错误信息逐条列出每个问题；语法错误给出行号，条目问题给出 Asset_Key 和出错的字段名。
10. THE Prompt_Manifest_Printer SHALL 把结构化的清单对象格式化为能被 Prompt_Manifest_Parser 成功解析的 Prompt_Manifest 文本，条目按 Asset_Catalog 的顺序输出；同一个清单对象每次格式化得到的文本逐字节相同。
11. FOR ALL 合法的清单对象，先用 Prompt_Manifest_Printer 格式化、再用 Prompt_Manifest_Parser 解析 SHALL 得到与原对象相等的清单对象（往返性质）。这里的相等指公共前缀、每个 Palette 色值，以及每条 Prompt_Entry 的 Asset_Key、描述、帧数、排列方式、画布尺寸和参考图列表全部相同。
12. WHEN 为一个 Asset_Key 组合完整提示词，THE Prompt_Composer SHALL 从 Prompt_Manifest_Parser 返回的清单对象中依次拼接公共提示词前缀、该素材适用的 Palette 色值和该 Prompt_Entry 的描述，得到完整提示词；同一个清单对象对同一个 Asset_Key 每次组合出的完整提示词逐字节相同，使重新出图时使用的提示词一致。
13. WHERE 一个 Prompt_Entry 属于 Resident_A 和 Resident_B 之外的素材，THE Prompt_Entry SHALL 在参考图列表中不列入 Resident_A 或 Resident_B 的任一 Character_Sheet。

### Requirement 3: 批量生成原始图

**User Story:** 作为项目所有者，我希望一条命令就能为选定的素材调用图像模型生成候选图，这样不用在网页里一张张手动出图。

#### Acceptance Criteria

1. WHEN 项目所有者运行 Image_Generator 并指定 1 个或多个 Asset_Key，THE Image_Generator SHALL 为每个指定的 Asset_Key 向图像模型发送请求，生成数量等于候选数量选项的 Raw_Candidate。每个请求包含 Prompt_Composer 为该 Asset_Key 组合的完整提示词（含公共提示词前缀和 Prompt_Entry 描述）、Prompt_Entry 列出的全部参考图，以及 Prompt_Entry 写明的生成画布尺寸。候选数量选项的取值为 1 至 8 的整数，未指定时为 2。
2. WHEN 项目所有者运行 Image_Generator 且未指定 Asset_Key，THE Image_Generator SHALL 只为 Work_Directory 中对应子目录不存在或其中没有 PNG 文件的 Asset_Key 生成 Raw_Candidate。如果 Prompt_Manifest 中每个 Asset_Key 都已有至少 1 张 Raw_Candidate，THE Image_Generator SHALL 不发出网络请求，输出一条说明无待生成素材的信息，并以退出码 0 结束。
3. THE Image_Generator SHALL 在每个请求中使用 Model_Variable 的值作为模型名。Model_Variable 未设置、为空字符串或只含空白字符时，THE Image_Generator SHALL 使用 `gpt-image-2.5-flare`。
4. THE Image_Generator SHALL 在每个请求中要求图像模型输出透明背景的图像。
5. THE Image_Generator SHALL 把每张 Raw_Candidate 保存为 PNG 文件，放在 Work_Directory 中以 Asset_Key 命名的子目录内。文件名包含从 1 开始的整数序号；新文件的序号与子目录中已有文件冲突时，使用大于现有最大序号的下一个整数，已有文件保持不变。
6. IF API_Key_Variable 未设置、为空字符串或只含空白字符，THEN THE Image_Generator SHALL 在发出任何网络请求之前以非零退出码结束，并输出一条错误信息，说明需要设置 API_Key_Variable。
7. IF 某个 Asset_Key 的某次请求返回错误、返回的内容无法解码为图像，或在发出后 180 秒内没有返回结果，THEN THE Image_Generator SHALL 不为这次请求写出任何文件，保留该 Asset_Key 已成功保存的 Raw_Candidate，记录该 Asset_Key 和错误原因，并继续处理其余请求。全部请求处理完后，THE Image_Generator SHALL 列出每个失败的 Asset_Key、该 Asset_Key 的成功张数和失败原因，并以非零退出码结束。
8. IF 指定的任一 Asset_Key 不在 Prompt_Manifest 中、Prompt_Manifest 未通过 Prompt_Manifest_Parser 解析、待处理的 Prompt_Entry 列出的参考图文件不存在，或候选数量选项不是 1 至 8 的整数，THEN THE Image_Generator SHALL 在发出任何网络请求之前以非零退出码结束，并输出每个出错的 Asset_Key、参考图路径或选项值。
9. WHERE 项目所有者启用试运行选项，THE Image_Generator SHALL 逐个输出每个将要发送的请求的 Asset_Key、模型名、完整提示词、参考图路径和生成画布尺寸，不发出任何网络请求，不在 Work_Directory 中写入任何文件，并以退出码 0 结束。
10. THE Image_Generator SHALL 确保 API_Key_Variable 的值不以完整或部分形式出现在标准输出、标准错误、日志和 Work_Directory 中保存的任何文件里，包括请求失败时输出的错误信息。
11. WHEN 全部请求都成功，THE Image_Generator SHALL 为每个 Asset_Key 输出一行，包含该 Asset_Key 和新保存的每张 Raw_Candidate 的文件路径，并以退出码 0 结束。
12. WHILE 请求正在处理，THE Image_Generator SHALL 每发出一个请求和每完成一个请求时各输出一行进度，内容包含 Asset_Key、该 Asset_Key 的候选序号和已完成请求数与总请求数。
13. IF 某个 Asset_Key 的全部请求都失败，THEN THE Image_Generator SHALL 在第 7 条的最终失败报告中列出该 Asset_Key，成功张数显示为 0，并使用与部分成功的 Asset_Key 相同的报告格式（Asset_Key、成功张数、失败原因）。

### Requirement 4: 后处理成规格图

**User Story:** 作为项目所有者，我希望模型生成的大图能被自动切帧、对齐、缩放并拼成规格要求的序列帧条，这样不用在图像编辑器里逐帧手工处理。

#### Acceptance Criteria

1. WHEN 项目所有者对一张 Raw_Candidate 运行 Post_Processor 并且处理成功，THE Post_Processor SHALL 输出一张 8 位 RGBA PNG 作为 Processed_Candidate，其像素尺寸等于该 Asset_Key 的 Expected_Pixel_Size。该文件写入 Work_Directory 中以 Asset_Key 命名的子目录，文件名包含序号，不覆盖已有文件。Post_Processor 随后输出该文件路径，并以退出码 0 结束。
2. THE Post_Processor SHALL 把 Raw_Candidate 沿水平方向等分为 Asset_Catalog 给出的该 Asset_Key 帧数。宽度不能整除时，余下的像素列归入最后一帧。每一帧独立处理后按原顺序从左到右拼接，相邻帧之间没有间隔，第 n 帧占据输出图的第 (n−1) × 每帧像素宽 列起、宽度为每帧像素宽的区域。
3. IF 输入图的像素尺寸不等于该 Asset_Key 的 Expected_Pixel_Size，且输入图四角的 4 个像素中至少有一个 alpha 值大于 0，THEN THE Post_Processor SHALL 以这些角像素的平均颜色为背景色，把从图像边缘出发、与背景色在 R、G、B 每个通道上相差都不超过 24 的连通区域设为 Transparent_Pixel。输入图的像素尺寸已等于 Expected_Pixel_Size 时（例如把 Processed_Candidate 或 Final_Asset 再次作为输入），Post_Processor 跳过本条的去背景和第 4、7 条的缩放，以 1:1 比例保留每帧像素，只按第 5、8、9、15 条中适用于该 Asset_Key 的规则做平移对齐。这样第 13 条的幂等性质成立，`plank`、`ladder`、`toolbox` 等四角不透明的成品图也不会被抹掉像素。
4. THE Post_Processor SHALL 先计算每帧 Opaque_Pixel 的边界框，再对该 Asset_Key 的所有帧使用同一个缩放比例（输入图像素尺寸已等于 Expected_Pixel_Size 时按第 3 条不缩放）。这个比例取让每一帧边界框都能放进每帧像素尺寸的最大比例，且保持宽高比。缩放使用高质量插值。项目所有者之后在 Preview_Builder 的总览图上目视确认缩放后的素材没有明显锯齿或异色色块；这项目视确认是独立的下游质量检查，不影响 Post_Processor 本次运行的退出码和成功判定。
5. WHERE 一个 Asset_Key 属于 Grounded_State 的居民素材、Chair、Visit_Flag、Toolbox、Fruit（`fruit`）或全部 10 个气泡素材（`bubble_*`），THE Post_Processor SHALL 让每帧最下方的 Opaque_Pixel 行位于每帧底部 2 像素以内，并让不透明边界框的水平中心与每帧水平中心相差不超过 1 像素。三张花和 Lamp 两种外观不按本条对齐，分别按第 8、9 条以花盆中心和底座中心为锚点居中贴底。
6. WHILE 处理同一个 Asset_Key 的多帧 sprite sheet，THE Post_Processor SHALL 让所有帧使用第 4 条得出的同一个缩放比例，使同一 Asset_Key 中各帧的内容大小比例与 Raw_Candidate 中各帧的相同。
7. WHEN 处理一位居民 Grounded_State 的 Asset_Key，并且 `Assets/` 中已有该居民 `idle` 的 Final_Asset，THE Post_Processor SHALL 调整第 4 条的缩放比例，使每帧不透明边界框的高度与该 Final_Asset 第 1 帧不透明边界框的高度相差不超过 10%，且调整后的内容仍不超出每帧像素尺寸。该居民的 `idle` 尚无 Final_Asset 时，只按第 4 条缩放。
8. WHEN 处理 `flower_pot`、`flower_sprout` 或 `flower_bloom`，THE Post_Processor SHALL 把每帧最下方 4 行 Opaque_Pixel 的边界框水平中心作为花盆中心，并让花盆中心与每帧水平中心相差不超过 1 像素、最下方 Opaque_Pixel 行位于每帧底部 2 像素以内。这样三张 Processed_Candidate 中花盆的底边行和水平中心列相差不超过 1 像素。
9. WHEN 处理 `decor_lamp_off` 或 `decor_lamp_on`，THE Post_Processor SHALL 把每帧最下方 4 行 Opaque_Pixel 的边界框水平中心作为底座中心，并让底座中心与每帧水平中心相差不超过 1 像素、最下方 Opaque_Pixel 行位于每帧底部 2 像素以内。这样两张 Processed_Candidate 中底座的底边行和水平中心列相差不超过 1 像素。
10. WHEN 处理 `plank`，THE Post_Processor SHALL 让输出图最左一列与最右一列的每一对同行像素满足：alpha 差不超过 16，R、G、B 每个通道差不超过 24。这样水平平铺无缝。
11. WHEN 处理 `ladder`，THE Post_Processor SHALL 让输出图最上一行与最下一行的每一对同列像素满足：alpha 差不超过 16，R、G、B 每个通道差不超过 24。这样竖直平铺无缝。
12. IF 出现以下任一情况：Asset_Key 不在 Asset_Catalog 中、Raw_Candidate 无法解码、某一帧在去背景后没有任何 Opaque_Pixel、处理结果无法满足第 10 或 11 条的平铺边缘阈值，THEN THE Post_Processor SHALL 以非零退出码结束，并输出 Asset_Key、文件路径和出错原因；与帧有关的错误还要输出出错的帧序号。此时不写出 Processed_Candidate，Work_Directory 中已有的文件保持不变。
13. FOR ALL 已符合 Expected_Pixel_Size 和第 5、8、9、15 条中适用于该 Asset_Key 的对齐规则的 Processed_Candidate，把它作为输入再次运行 Post_Processor SHALL 得到像素尺寸相同的结果，且每帧不透明边界框四条边的位置与输入相差都不超过 1 像素（幂等性质）。
14. WHERE 一个 Asset_Key 属于 Framed_Asset，THE Post_Processor SHALL 让输出图每帧四角各 2×2 像素全部为 Transparent_Pixel，使 Processed_Candidate 满足 Requirement 6 第 3 条。
15. WHERE 一个 Asset_Key 属于居民素材但不属于 Grounded_State，THE Post_Processor SHALL 对所有帧使用同一个平移量，使各帧内容之间的相对位置与 Raw_Candidate 中相同；该平移量让所有帧中最下方的 Opaque_Pixel 行位于每帧底部 2 像素以内，并让所有帧不透明边界框的并集在水平方向居中，误差不超过 1 像素。这样 `planting` 的跳起和 `celebrating` 回到站姿等帧间位移得以保留。

### Requirement 5: 挑选与写入最终素材

**User Story:** 作为项目所有者，我希望从几张候选图里挑一张写入 `Assets/`，且写入前自动校验，这样不合格的图不会进入仓库。

#### Acceptance Criteria

1. WHEN 项目所有者指定一个 Asset_Key 和一张 Processed_Candidate 的文件路径执行 Promotion，THE Art_Pipeline SHALL 先用 Asset_Validator 按该 Asset_Key 对应的 Requirement 6 第 2 至 7 条规则校验该图。校验时以指定的 Asset_Key 作为文件名判定依据，与候选图自身的文件名无关。
2. WHEN Promotion 中的 Processed_Candidate 通过 Asset_Validator，THE Art_Pipeline SHALL 把该图写为 `Assets/<Asset_Key>.png`，写入的文件与该 Processed_Candidate 逐字节相同；`Assets/` 不存在时先创建该目录。Art_Pipeline 不修改该 Processed_Candidate，也不改动 `Assets/` 中其余文件。完成后以退出码 0 结束，并输出 Asset_Key 和写入路径。
3. IF Promotion 中的 Processed_Candidate 未通过 Asset_Validator，THEN THE Art_Pipeline SHALL 保持 `Assets/` 中已有的同名文件内容不变；原本没有同名文件时不创建该文件。随后以非零退出码结束，并逐条输出每一条未通过的规则名称。
4. WHEN Promotion 将覆盖 `Assets/` 中已有的同名 Final_Asset，THE Art_Pipeline SHALL 在写入新文件之前，把原文件逐字节复制到 Work_Directory 中的备份子目录。备份文件名包含 Asset_Key 和一个不与已有备份重复的序号或时间戳，已有的备份文件不被覆盖。
5. IF Promotion 指定的 Asset_Key 不在 Asset_Catalog 中，或指定的 Processed_Candidate 文件不存在或无法读取，THEN THE Art_Pipeline SHALL 在校验和写入任何文件之前以非零退出码结束，并输出该 Asset_Key 或文件路径。
6. IF 备份原文件或写入 `Assets/<Asset_Key>.png` 失败，THEN THE Art_Pipeline SHALL 保持 `Assets/<Asset_Key>.png` 为写入前的完整内容，原本没有该文件时不留下任何部分写入的文件；随后以非零退出码结束，并输出失败的步骤（备份或写入）和失败原因。
7. THE `.gitignore` SHALL 包含 Work_Directory，使 Raw_Candidate、Processed_Candidate、备份和预览图不进入版本控制。

### Requirement 6: 素材校验

**User Story:** 作为项目所有者，我希望有一条命令和一组测试检查 `Assets/` 中的全部素材，这样能确认应用启动后不会有任何一项回退到占位图形。

#### Acceptance Criteria

1. WHEN 项目所有者对一个目录运行 Asset_Validator，THE Asset_Validator SHALL 按 Asset_Catalog 的顺序为 45 个 Asset_Key 各输出一行结果。每行包含 Asset_Key 和以下三种状态之一：「通过」；「缺失」（目录中没有 `<Asset_Key>.png`）；「未通过」，并列出该文件未通过的全部规则名称，不能只列第一条。规则名称取自固定集合：文件格式、像素尺寸、alpha 通道、四角透明、贴底、水平居中、空帧、帧内容相同、平铺边缘。
2. THE Asset_Validator SHALL 在以下条件全部成立时判定一个 PNG 合规，否则判定不合规：文件名为某个 Asset_Key 加 `.png`；文件内容能解码为 PNG（规则「文件格式」）；像素尺寸等于该 Asset_Key 的 Expected_Pixel_Size（规则「像素尺寸」）；PNG 颜色类型包含 alpha 通道（规则「alpha 通道」）；满足本需求第 3 至 7 条中适用于该 Asset_Key 的规则。第 3 至 7 条所说的「帧」指把整张图从左到右按每帧像素宽（每帧 pt 宽 × 2）切出的各段。如果文件格式或像素尺寸未通过，第 3 至 7 条不再检查，该行只列出已未通过的规则。
3. WHERE 一个 Asset_Key 属于 Framed_Asset，THE Asset_Validator SHALL 要求每帧四个角上各 2×2 像素的区域全部为 Transparent_Pixel（规则「四角透明」）。Plank、Ladder 和 Toolbox 不做此项检查。
4. WHERE 一个 Asset_Key 属于 Grounded_State 的居民素材，THE Asset_Validator SHALL 要求每帧最下方含 Opaque_Pixel 的像素行距该帧底边不超过 2 像素（规则「贴底」），并要求每帧不透明边界框的水平中心与该帧水平中心相差不超过 6 像素（规则「水平居中」）。
5. THE Asset_Validator SHALL 要求每一帧至少含有一个 Opaque_Pixel；有任一帧不含 Opaque_Pixel 时，判定规则「空帧」未通过，并在结果中注明该帧的序号（从 1 开始）。
6. WHERE 一个 Asset_Key 的帧数大于 1，THE Asset_Validator SHALL 要求至少有两帧在同一位置上有至少一个像素的 RGBA 值不同（规则「帧内容相同」）。
7. WHERE 一个 Asset_Key 是 `plank`，THE Asset_Validator SHALL 要求最左一列与最右一列对应像素的 alpha 差不超过 16、每个颜色通道差不超过 24；WHERE 一个 Asset_Key 是 `ladder`，THE Asset_Validator SHALL 要求最上一行与最下一行对应像素同样满足这两个阈值（规则「平铺边缘」，阈值同 Requirement 4 第 10、11 条）。
8. THE Asset_Validator SHALL 仅当 45 个 Asset_Key 的结果都是「通过」时以退出码 0 结束；只要有一个 Asset_Key 为「缺失」或「未通过」，就以非零退出码结束。
9. IF 被检查目录中存在文件名不对应任何 Asset_Key 的 `.png` 文件，THEN THE Asset_Validator SHALL 在 45 行结果之后逐个列出这些文件名并标为「未知文件」。未知文件不改变第 8 条的退出码判定。
10. THE Asset_Validator SHALL 对像素尺寸和帧数使用 `AssetCatalog.validation(fileName:pixelWidth:pixelHeight:)` 的判定，使任一 PNG 在 Asset_Validator 中的「像素尺寸」结论与 Asset_Provider 对同一文件的加载结论一致。
11. THE `WindowfolkCoreTests` 测试套件 SHALL 包含一项测试，对仓库 `Assets/` 目录中已存在的每个 Asset_Key 的 PNG 执行与 Asset_Validator 相同的合规检查。只要其中任一文件不合规，测试就失败，失败信息包含该 Asset_Key 和未通过的规则名称；缺失的 Asset_Key 按第 14、15 条处理，不使测试失败。
12. FOR ALL 由 Post_Processor 输出且通过 Asset_Validator 的 PNG，Asset_Catalog 的尺寸校验 SHALL 判定为合规（模型一致性性质：Post_Processor 的输出尺寸与 Asset_Catalog 的期望一致）。
13. IF 运行 Asset_Validator 时指定的目录不存在或无法读取，THEN THE Asset_Validator SHALL 不输出任何 Asset_Key 的结果，输出包含该目录路径的错误信息，并以非零退出码结束。
14. IF 仓库 `Assets/` 中没有任何文件名对应 Asset_Key 的 PNG，THEN THE `WindowfolkCoreTests` 中第 11 条的测试 SHALL 标记为跳过而不是通过，并输出原因：`Assets/` 中尚无 Final_Asset。
15. WHILE 仓库 `Assets/` 中对应 Asset_Key 的 PNG 有 1 到 44 个，THE `WindowfolkCoreTests` 中第 11 条的测试 SHALL 列出全部缺失的 Asset_Key 和缺失数量，且不因缺失而失败。交付时「45 项都合规」以 Asset_Validator 对 `Assets/` 运行时 45 行全部为「通过」并以退出码 0 结束（第 8 条）作为判定依据，与 Requirement 8 第 1 条一致。

### Requirement 7: 预览与目视检查

**User Story:** 作为项目所有者，我希望一次看到全部素材在深色和浅色背景上的效果，这样能发现白边、风格不一致和动作不清楚的问题。

#### Acceptance Criteria

1. WHEN 项目所有者对一个存在且可读的目录运行 Preview_Builder，THE Preview_Builder SHALL 在 Work_Directory 中输出两张总览 PNG，一张为深色背景、一张为浅色背景，文件名分别标明深色或浅色；同名的旧总览 PNG 被覆盖，被检查目录中的文件内容保持不变。
2. THE Preview_Builder SHALL 让深色总览图背景为单一纯色，且每个颜色通道值不大于 48；让浅色总览图背景为单一纯色，且每个颜色通道值不小于 208；两张图的背景都不使用渐变或棋盘格。
3. THE Preview_Builder SHALL 在每张总览图中按 Asset_Catalog 的顺序为 45 个 Asset_Key 各画一行，每行把该素材的全部帧按帧序从左到右排列，相邻两帧之间至少留 4 像素背景间隔，并在该行左侧用文字标出 Asset_Key，文字高度不小于 10 像素且不与任何帧重叠。
4. IF 被检查目录中缺少某个 Asset_Key 的 PNG，或该 PNG 未通过 Asset_Validator，THEN THE Preview_Builder SHALL 在该 Asset_Key 所在行画一个与 Expected_Pixel_Size 等大的标记区域代替素材内容，缺失时在标记中写明「缺失」，不合规时写明 Asset_Validator 报告的未通过规则名称，然后继续绘制其余 Asset_Key。
5. THE Preview_Builder SHALL 把全部 24 个居民素材（Resident_A 与 Resident_B 各 12 个 Resident_State）在每张总览图中各画两遍：一遍为 2 倍比例，即素材的 1 个像素对应总览图的 1 个像素；另一遍为 1 倍比例，即每帧缩小为每帧 pt 宽 × 每帧 pt 高个像素，用于检查 32pt 显示尺寸下的辨认度。非居民素材只按 2 倍比例画一遍。
6. WHEN Preview_Builder 写完两张总览 PNG，THE Preview_Builder SHALL 输出两张总览 PNG 的路径以及正常显示、缺失和不合规的 Asset_Key 各自的数量和名单，并以退出码 0 结束。
7. IF 指定的目录不存在或不可读，THEN THE Preview_Builder SHALL 不写出或改动任何总览 PNG，输出包含该目录路径的错误信息，并以非零退出码结束。

### Requirement 8: 最终素材内容

**User Story:** 作为玩家，我希望居民和物件的图形能清楚表达当前在做什么，这样不看文字也能看懂桌面上发生的事。

#### Acceptance Criteria

1. THE `Assets/` 目录 SHALL 恰好包含 Asset_Catalog 中全部 45 个 Asset_Key 的 Final_Asset，不含其他 `.png` 文件；对 `Assets/` 运行 Asset_Validator 时 45 行结果均为通过、没有未知文件，且退出码为 0。
2. THE Final_Asset SHALL 让每位居民 12 个 Resident_State 的每一帧都符合 `docs/art-spec.md` 第 4 节对应行的动画内容描述；项目所有者在 Preview_Builder 的深色和浅色两张总览图上逐一检查全部 24 个居民 Asset_Key，任一 Asset_Key 在任一张总览图上不符合描述即判为不通过。
3. THE Final_Asset SHALL 让 Resident_A 的 12 个素材呈现 Resident_A Character_Sheet 的特征（银白到浅灰的渐层毛色、三角形耳朵、翠绿或蓝绿色眼睛、蓬松尾巴），让 Resident_B 的 12 个素材呈现 Resident_B Character_Sheet 的特征（金黄偏橘毛色、圆形耳朵、黑色小眼睛、奶白色肚子），且每位居民的主色使用 Prompt_Manifest 中该居民 Palette 的主色；项目所有者在 Preview_Builder 总览图的 1 倍比例（每帧 32×32pt）行上确认，同一 Resident_State 的 Resident_A 帧与 Resident_B 帧可以互相区分。
4. THE Final_Asset SHALL 让 `resident_a_carrying` 和 `resident_b_carrying` 的每一帧都不出现被抱的物件，`resident_a_climbing` 和 `resident_b_climbing` 的每一帧都不出现梯子，`resident_a_sitting` 和 `resident_b_sitting` 的每一帧都不出现椅子；全部 24 个居民 Final_Asset 的每一帧都不出现地面阴影或背景。
5. THE Final_Asset SHALL 让全部 10 个气泡素材都不出现任何文字字符，「...」「?」和「Zzz」都以图形线条绘制，`bubble_zzz` 由三个从大到小的 Z 形组成；每个气泡的图案与 `docs/art-spec.md` 5.3 节表格对应行的内容一致；`bubble_wish` 的左半边画小花盆，右半边除气泡本身的底色和轮廓外不画任何图案，留给应用叠加 Receiver 头像；`bubble_flag` 的箭头指向右方。
6. THE Final_Asset SHALL 让 `toolbox`（72×40pt，即 144×80 像素）的左半边（像素列 0 至 71）显示木板、右半边（像素列 72 至 143）显示梯子，两半之间有一条可见的分隔线或分隔板，并且最下方的 Opaque_Pixel 行位于图像底部 2 像素以内。
7. THE Final_Asset SHALL 让 `resident_a_idle` 和 `resident_b_idle` 的第 1 帧为正面或四分之三侧面且两只眼睛都可见，使该帧缩小到 10×10pt 作为许愿气泡头像时，项目所有者仍能分辨出是哪位居民。
8. THE Final_Asset SHALL 让 `decor_lamp_on` 的灯罩为暖黄色，灯罩外圈有一圈 alpha 值在 1 至 254 之间的半透明光晕，光晕不超出每帧边界，也不覆盖每帧四角各 2×2 像素（满足 Requirement 6 第 3 条）；`decor_lamp_off` 的灯罩为灰色或暗色，且不画光晕。
9. THE Final_Asset SHALL 让 `flower_pot`、`flower_sprout`、`flower_bloom` 三张图中花盆的底边行和水平中心列两两相差不超过 1 像素，并让 `decor_lamp_off` 与 `decor_lamp_on` 中底座的底边行和水平中心列相差不超过 1 像素（与 Requirement 4 第 8、9 条的后处理结果一致）。
10. THE Final_Asset SHALL 让每位居民的 `planting` 第 1 至 4 帧的不透明边界框高度小于该居民 `idle` 第 1 帧的不透明边界框高度（蹲下），第 5、6 帧中至少一帧最下方 Opaque_Pixel 行距每帧底边不少于 4 像素（跳起）；`celebrating` 最后一帧的最下方 Opaque_Pixel 行位于每帧底部 2 像素以内，且不透明边界框高度与该居民 `idle` 第 1 帧相差不超过 10%（回到站姿）；`sleeping` 每帧的不透明边界框宽度大于高度（横躺）。`planting`、`celebrating` 和 `sleeping` 不属于 Grounded_State，不受 Requirement 6 第 4 条约束，帧间位移按 Requirement 4 第 15 条保留。
11. THE Final_Asset SHALL 让 `flower_pot` 盆中只有土、`flower_sprout` 盆中有两片嫩芽、`flower_bloom` 盆中有一朵花，`fruit` 为一个圆形果子，`decor_chair` 画有椅背、椅面和四条腿，`visit_flag` 画有竖杆和一面红色三角旗；`plank`、`ladder`、`toolbox`、花盆和 `decor_chair` 的木色，以及三张花图的植物绿色，使用 Prompt_Manifest 中对应 Palette 的色值。

### Requirement 9: 应用内生效

**User Story:** 作为玩家，我希望打包后的应用直接显示新美术，这样不需要任何额外设置。

#### Acceptance Criteria

1. WHEN 仓库 `Assets/` 中的 45 个 Final_Asset 都通过 Asset_Validator，且项目所有者在环境变量 `WINDOWFOLK_ASSETS` 未设置或为空的情况下，从仓库根目录运行 `swift run Windowfolk`，THE Asset_Provider SHALL 选用仓库根目录下的 `Assets/` 作为素材目录，在 Overlay 首次渲染之前为 Asset_Catalog 中全部 45 个 Asset_Key 加载 PNG，并在日志中恰好输出一条「素材目录 <仓库根目录>/Assets：加载 45 / 45 项 PNG」。
2. WHILE Asset_Provider 已从全部 45 个 Final_Asset 加载 PNG，THE Asset_Provider SHALL 对每个 Asset_Key 的 `isUsingPNG` 返回 true，且日志中不出现任何「无法解码，使用占位图形」「不符合规格」或「未找到素材目录，全部使用占位图形」的记录。
3. WHEN 仓库 `Assets/` 中有 45 个 Final_Asset 时项目所有者运行 `build-app.sh` 且该脚本以退出码 0 结束，THE `build-app.sh` SHALL 把 45 个 Final_Asset 复制到 `Windowfolk.app/Contents/Resources/Assets/`，保持文件名不变、每个文件与仓库 `Assets/` 中的同名文件字节相同，并在「复制素材」步骤中输出「已复制 45 个 PNG」。
4. WHEN 项目所有者在环境变量 `WINDOWFOLK_ASSETS` 未设置或为空、且不经过任何额外配置的情况下，用 `open Windowfolk.app` 启动第 3 条生成的应用，THE Asset_Provider SHALL 选用 `Windowfolk.app/Contents/Resources/Assets/` 作为素材目录，并在日志中恰好输出一条「素材目录 <Windowfolk.app 路径>/Contents/Resources/Assets：加载 45 / 45 项 PNG」。
5. THE Art_Pipeline SHALL 让 `Sources/WindowfolkCore/AssetCatalog.swift` 中 45 个 Asset_Key 的素材键、每帧 pt 尺寸、帧数和平铺方式与本 spec 开始前的取值相同，使 Overlay 中每项图形的显示尺寸（pt）和位置与使用占位图形时相同。
6. THE Art_Pipeline SHALL 只依赖 macOS 14 自带的系统框架、系统命令行工具和 Swift 工具链（Xcode 或 Command Line Tools），使流水线的每个命令行工具在没有安装 Homebrew、pip 或其他第三方包的 macOS 14 机器上都能运行。
7. WHEN Art_Pipeline 的任一命令行工具的输入合法且操作成功，THE Art_Pipeline SHALL 让该命令行工具以退出码 0 结束；退出码 0 只取决于输入合法与操作成功这两个条件，各工具的具体成功条件见 Requirement 3 第 2、9、11 条，Requirement 4 第 1 条，Requirement 5 第 2 条，Requirement 6 第 8 条和 Requirement 7 第 6 条。
8. THE `WindowfolkCore` 模块 SHALL 继续不导入 AppKit 和 SpriteKit，使 v1 R27.2 的架构测试在本 spec 的改动完成后继续通过。
