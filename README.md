# 窗间 · Windowfolk

> 你的窗口，是它们的世界。
>
> A little civilization between your windows.

**窗间是一个住在电脑窗口之间的微型世界。** 窗口上沿是道路，窗口之间的空隙是峡谷。移动窗口、搭起桥梁，让小居民搬运物件、拜访邻居，布置自己的小家。

## 不只是桌宠

你不直接操纵居民，而是改变它们生活的环境。把两个窗口拉近，一次拜访变得可能；架起一座桥，一盆花终于送到邻居手中。花留在窗沿，你的桌面也多了一点生活。

窗间想找回早期桌面宠物和 Flash 小游戏的亲切感：可以随手摆弄，观察回应，也可以安静地陪在一旁。不追求效率，不需要赢。

**改变布局 → 连接通路 → 居民行动 → 留下变化。**

## About

Windowfolk is a tiny world living between your application windows. Move windows and build bridges to help little residents carry objects, visit neighbors, and make themselves at home.

**v1「送花过桥」已可运行。** 都都（银渐层小猫）抱着花盆想送给住在另一扇窗户上的嘟嘟（金丝熊）。你从右下角的工具箱拖出木板和梯子，帮它把花送到；花开之后，嘟嘟会回赠一颗果子。更多构想见 [创意说明](docs/concept.md)。

## 运行

### 环境要求

- macOS 14 或更高版本。
- Xcode（或 Command Line Tools），Swift 6。
- 首次构建需要联网下载测试依赖 swift-property-based。

窗间只读取窗口的位置、大小、层级和所属应用名称，不读取窗口标题和画面，因此不需要屏幕录制或辅助功能权限。

### 打包并启动

```sh
./build-app.sh
open Windowfolk.app
```

`build-app.sh` 在仓库根目录生成 `Windowfolk.app`，也可以在 Finder 中双击打开。窗间运行在菜单栏，没有 Dock 图标。

### 开发运行与测试

```sh
swift run Windowfolk
swift test
```

`swift run` 时在仓库根目录执行，这样会读取根目录下的 `Assets/`。`swift test` 只测试核心逻辑库 `WindowfolkCore`，不创建窗口，也不读写用户数据。

### 菜单

点击菜单栏图标：

- **显示路面**：用彩色线段画出居民能走的路（窗沿蓝、地面棕、木板橙），用于排查布局。
- **调试**：
  - **让都都去找嘟嘟**：让都都以嘟嘟为目标出发。
  - **给都都一个花盆**：都都手上没有东西时给它一个花盆。
  - **快进**：花长到下一个阶段；一轮结束后立即开始下一轮。
  - **重新开始剧情**：清除所有花和果子，保留木板和梯子，从第 1 轮重新开局。
- **退出**：保存世界后退出。

### 数据位置

数据保存在 `~/Library/Application Support/Windowfolk/`：

- `world.json`：世界存档，退出时和每 30 秒自动保存。删除它（先退出应用）即可从全新世界开始。
- `events.jsonl`：关键事件记录，每行一条 JSON，为以后的日记功能预留，v1 只写不读。

### 替换素材

默认使用程序生成的占位图形。按 [素材规格](docs/art-spec.md) 把 PNG 放进仓库根目录的 `Assets/`，重新运行 `./build-app.sh`（或 `swift run`）后对应图形就会被替换。缺失或不合格的文件只让那一项继续使用占位图形。

### 演示

录制演示视频的窗口布局、逐步操作和手动验收清单见 [演示脚本](docs/demo-script.md)。

## License

[MIT](LICENSE)
