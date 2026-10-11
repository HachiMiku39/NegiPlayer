# 来源与许可清单

NegiPlayer 0.2.0 的项目源码采用 [MIT](LICENSE) 许可。系统框架和参考项目各自保持原许可；未将 NegiFlick 原始 JavaScript 或其他组件重新标为 MIT。

| 项目 | 实际用途 | 分发与许可状态 |
| --- | --- | --- |
| Apple SDK / SwiftUI / AppKit / AVFoundation / Core Audio / AudioToolbox / CryptoKit / MediaPlayer | 系统界面、解码、输出、摘要 | 链接 macOS 系统框架；使用本机 Apple SDK，未复制 SDK 或系统框架 |
| SQLite | 系统 `/usr/lib/libsqlite3.dylib` | [SQLite 公共领域说明](https://sqlite.org/copyright.html)；仅动态链接系统库 |
| NegiFlick Studio | 歌词语义、Negi 工程格式和歌词测试参照；独立 Swift 实现 | 固定提交 `cf64f04900bf2429ee9a207b1bf7213feba6c2f9`；上游 README 明确尚未选择应用源码许可证，因此当前不把它视为 MIT 或无限制再分发授权 |
| FFmpeg 9.0.1（本机 Homebrew） | 生成原创 WAV 的 MP3/FLAC/AAC/ALAC 测试样本 | 本机工具带 GPL 构建选项；播放器未链接、未打包 FFmpeg，也未复制其二进制库 |
| Xcode / Swift / Python / codesign / ditto | 构建、测试、打包 | 开发工具，不作为应用运行时分发 |

Negi 基线读取路径与 Git blob：

- `docs/core.mjs`：`bdf66a5a98597a86d6e33e396ae7da3fff350db7`。
- `docs/timing.mjs`：`aae55dea45ed7225edd3c800e9889883f2a0dc36`。
- `Tests/LyricTimingTests.mjs`：`1ac2672a379d1d625ce0d3433930ac19fe1db298`。
- `README.md`：`4a1d16e53bc9d00362b315f4fcf784aa5a4204cd`。

适配与变更：使用 Swift 字素簇和 UTF-16 映射；时间存储改为有符号纳秒；去除 600 秒和游戏 tick 限制；保留未打点 null、原文空白与标点；歌词和非歌词 Negi 工程字段分开更新；对不能无损表达的导出报错。未移植游戏玩法、浏览器音频播放器、角色资源或商业音乐。

参考 [上游固定提交](https://github.com/HachiMiku39/NegiFlick/tree/cf64f04900bf2429ee9a207b1bf7213feba6c2f9)。本仓库包含独立编写的 Swift 解析、时间与 Unicode 实现，不分发上述原始 JavaScript、上游测试文件或游戏资源。本项目 MIT 不授予复制或再分发未获授权上游源码的权利。

SFB Audio Engine、TagLib、GRDB 与 FFmpeg DST 库尚未作为工程依赖引入；它们是规格中的候选后续组件，不列为已经集成的能力。未来接入需固定版本／commit、编译选项、补丁和真实链接方式，重新审核分发义务。

名称配色来自用户要求；界面只采用颜色和系统符号，未使用初音未来的官方角色图、Logo 或歌曲资源。测试信号由本项目脚本原创生成；用户外置盘音乐仅在本机只读测试，未复制或分发。
