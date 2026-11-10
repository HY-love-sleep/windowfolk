# 窗间 · Windowfolk

> 你的窗口，是它们的世界。
>
> A little civilization between your windows.

把电脑窗口布局变成地形的桌面微型世界：移动窗口、搭起桥梁，让小居民搬运物件、拜访邻居，留下属于你的生活痕迹。

Windowfolk turns application window edges into paths and the gaps between them into obstacles. Shape the layout, connect a bridge, and help little residents make themselves at home.

## 当前状态

**创意与仓库初始化阶段，尚无可运行应用。** 没有选定框架、安装依赖或实现桌面功能。后续由项目所有者与 Kiro 共同开发，优先验证 macOS。

## 从这里开始

- [完整创意说明](docs/concept.md)：体验、核心循环、范围、技术风险和参赛表达。
- [开发接手说明](AGENTS.md)：已确定的边界、未定事项和首个验证目标。
- [Kiro 项目上下文](.kiro/steering/product.md)：供后续开发读取的产品基线。

```bash
cd ~/Code/personal/windowfolk
kiro-cli
```

建议给 Kiro 的第一条消息：

> 先阅读 README.md、AGENTS.md 和 docs/concept.md。先不要写代码。结合 macOS 真实窗口感知、透明覆盖层、焦点和鼠标穿透需求，检查可复用项目并比较最小实现路线，向我说明建议及风险；确认后再做“两个居民、两个平台、一座桥、一次花盆搬运”的验证切片。

## 核心循环

改变布局 → 连接通路 → 居民行动 → 留下变化。

窗口边缘行走本身不是创新点。我们要验证的是：用户是否愿意主动改变布局，帮助居民把一件事做成。

## 范围

- 本地桌面客户端优先；不依赖 VPS 或模型 API。
- 核心行为使用可测试的规则、状态机与路径计算。
- 不默认读取截图、窗口内容或键盘输入，不操作其他应用和真实文件。
- 不抢键盘焦点，提供隐藏、暂停和退出。
- 真实窗口集成和模拟窗口演示的验收结果必须分开。

## 参赛与复用

拟探索 Kiroween Resurrection 方向，最终资格与交付要求需核对官方规则。

`.kiro/` 已纳入版本管理。初始化文件由 Hermes 准备，不代表已经使用 Kiro 完成实现；后续应保留真实的 Kiro 开发与测试记录，不补造证据。

目前没有引入第三方项目代码或角色素材。后续复用时须分别核对代码及素材许可证，并披露来源。

## License

本仓库原创内容使用 [MIT License](LICENSE)。未来引入的第三方代码与素材遵循各自许可证。
