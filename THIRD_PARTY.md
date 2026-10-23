# 来源与许可清单

NegiPlayer 0.8.0 macOS 工作版本 的项目源码采用 [MIT](LICENSE) 许可。系统框架和参考项目各自保持原许可；未将 NegiFlick 原始 JavaScript 或其他组件重新标为 MIT。

| 项目 | 实际用途 | 分发与许可状态 |
| --- | --- | --- |
| Apple SDK / SwiftUI / AppKit / AVFoundation / Core Audio / AudioToolbox / CryptoKit / MediaPlayer | 系统界面、解码、输出、摘要 | 链接 macOS 系统框架；使用本机 Apple SDK，未复制 SDK 或系统框架 |
| SQLite | 系统 `/usr/lib/libsqlite3.dylib` | [SQLite 公共领域说明](https://sqlite.org/copyright.html)；仅动态链接系统库 |
| NegiFlick Studio | 歌词语义、Negi 工程格式和歌词测试参照；独立 Swift 实现 | 固定提交 `cf64f04900bf2429ee9a207b1bf7213feba6c2f9`；上游 README 明确尚未选择应用源码许可证，因此当前不把它视为 MIT 或无限制再分发授权 |
| FFmpeg 9.0.1（本机 Homebrew） | 生成测试样本；可选的本机流式分析后备解码 | 本机工具带 GPL 构建选项；播放器未链接、未打包 FFmpeg，也未复制其二进制库 |
| Xcode / Swift / Python / codesign / ditto | 构建、测试、打包 | 开发工具，不作为应用运行时分发 |

Negi 基线读取路径与 Git blob：

- `docs/core.mjs`：`bdf66a5a98597a86d6e33e396ae7da3fff350db7`。
- `docs/timing.mjs`：`aae55dea45ed7225edd3c800e9889883f2a0dc36`。
- `Tests/LyricTimingTests.mjs`：`1ac2672a379d1d625ce0d3433930ac19fe1db298`。
- `README.md`：`4a1d16e53bc9d00362b315f4fcf784aa5a4204cd`。

适配与变更：使用 Swift 字素簇和 UTF-16 映射；时间存储改为有符号纳秒；去除 600 秒和游戏 tick 限制；保留未打点 null、原文空白与标点；歌词和非歌词 Negi 工程字段分开更新；对不能无损表达的导出报错。未移植游戏玩法、浏览器音频播放器、角色资源或商业音乐。

参考 [上游固定提交](https://github.com/HachiMiku39/NegiFlick/tree/cf64f04900bf2429ee9a207b1bf7213feba6c2f9)。本仓库包含独立编写的 Swift 解析、时间与 Unicode 实现，不分发上述原始 JavaScript、上游测试文件或游戏资源。本项目 MIT 不授予复制或再分发未获授权上游源码的权利。

SFB Audio Engine、原生 TagLib C++、GRDB 与 FFmpeg DST 库尚未作为工程依赖引入；它们是规格中的候选后续组件，不列为已经集成的能力。未来接入需固定版本／commit、编译选项、补丁和真实链接方式，重新审核分发义务。

名称配色来自用户要求；界面只采用颜色和系统符号，未使用初音未来的官方角色图、Logo 或歌曲资源。测试信号由本项目脚本原创生成；用户外置盘音乐仅在本机只读测试，未复制或分发。

0.4 使用 Apple Network / Security 构建本地 HTTPS 与配对，并在本机首次开启服务时调用系统 LibreSSL/openssl 生成私有 TLS 身份；不打包 openssl，也不公开私钥或配对数据。iOS 同样使用系统 AVFoundation、UIKit、MediaPlayer、Security 与 SwiftUI。

MV 模式只参考 [SEGA MikuFlick 的官方呈现](https://miku.sega.jp/flick/en/)中音乐与影像的组合方向，实际交互为独立的本地静音视频加歌词，不复制游戏界面、源码、角色、音乐或视频。中性共用图标由内置 ImageGen 生成；母版和设计说明见 [Resources/Brand/README.md](Resources/Brand/README.md)。
# 0.5 Windows / Android additions

The native Windows/Android frontends use Microsoft .NET MAUI 10.0.110 (MIT) and .NET 10 (MIT). Windows audio uses NAudio 2.2.1 (MIT); read-only metadata uses TagLibSharp 2.3.0 (LGPL-2.1). TagLibSharp is a separate, replaceable DLL in the portable Windows package; NegiPlayer's read-only file abstraction rejects tag writes. Corresponding library source: https://github.com/mono/taglib-sharp/tree/b5ae84f2e84087bf160bb0471420200dd2b5d809 (TaglibSharp-2.3.0.0). The unmodified library source and build files are provided as `TagLibSharp-2.3.0-library-source.zip` alongside the Windows binary in the 0.5 release. License copies are in `cross/licenses/` and included in packages. Audio codecs use Windows Media Foundation/system components rather than bundled third-party decoders.

The Windows/Android app icon copies the existing original NegiPlayer PNG unchanged. Roon is a functional reference only; no Roon code, installers, patches, RAAT implementation, graphics or branding is included.


## 0.6 本机 Sony / Gracenote 兼容环境

NegiPlayer 的 Swift 和 Python ctypes 桥接代码独立编写。源码包与应用包不包含 Sony / Gracenote 二进制、提取出的应用授权、注册用户数据或 WinePrefix。用户提供的 Media Go 3.2 Build 191（MediaGo.exe SHA-256 `e6abbd21a861d2a5d96619b40f5a4c0435500280ac9ec1297eddc3e3f5f32ddc`）及其原组件保留于本机独立引擎目录，项目 MIT 许可不涵盖这些组件。本次未上传它们到公开仓库。

| 本机组件 | 核对版本与来源 | 使用方式 |
| --- | --- | --- |
| Sony MMLib11.dll | 1.1.2.640；用户提供的 Media Go 安装包 | 原 DLL 分析独立 PCM，生成完整 SMFMF |
| Gracenote GNSDK | 3.07.2.3083；同一 Media Go 包 | 原 SDK 注册和文字查询；授权只在本机恢复和保存 |
| Wine Devel | [Gcenx macOS Wine 11.18](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.18)；下载归档 SHA-256 `aa0ea4c82e636ae7bca2076387cb0a5affa26509ad13f119ecd0d62bd7ba6f82` | 独立、可替换的便携运行时，未链接 NegiPlayer；Wine 为 LGPL-2.1-or-later，原项目及其依赖保持原许可 |
| Python Win32 embeddable | [CPython 3.12.10 官方发行](https://www.python.org/downloads/release/python-31210/) | 独立、可替换的 Python；许可文本保留于引擎的 `python-win32/LICENSE.txt` |

兼容环境未作为开源源码的一部分分发。公开分发前需要另行核对每个运行时及专有组件的分发条款；本机调用成功不等于获得通用 Gracenote 开发者许可。应用界面目前只解释 BPM 和分块结构，未复制 Sony 的频道分类界面。

0.6.1 使用同一原 SDK 的完整专辑查询和内容地址获取用户选择的封面。源码与应用包不附带 Gracenote 返回的专辑图片、语言表或查询缓存；图片只在用户请求预览后下载到本机，并在手动采用后用于曲库显示与传输副本。

当前原生 SensMe 开发分支以独立 C 实现默认 1.6.1 的运算、恢复的数值参数和结果编码；应用源码中的 SensMe 分析不调用上述兼容环境或原 DLL。原 DLL 仅用于本机研究对照，不进入原生运行链。私人 Ghidra 工程、原始反编译输出、音乐及逐曲研究输入不纳入公开源码。可选 Gracenote 查询仍使用用户独立提供的原 SDK 和外部运行环境，与内置原生 SensMe 分离。原生进度和验证范围见 NATIVE_SENSME.md。
