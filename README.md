# NegiPlayer

macOS 本地音乐播放器与歌词工作室，开发预览 0.4.0。提供 Negi（Miku 青绿与少量粉色）、日间、夜间三套主题及中文／日文／英文界面，macOS 27 使用原生 SwiftUI Liquid Glass；减少透明度时使用实色背景。最低部署目标 macOS 14，当前验证架构为 Apple Silicon / arm64。

本轮增加 iOS LAN 播放端、Mac 只读 HTTPS 曲库服务、三套主题／三种语言和两端共用图标。两端专辑页面可切换封面网格与缩略图列表，选择在本机保存；使用真实内嵌／文件夹封面，保留正在播放页面和自动 LRC 显示，延续本地 PCM 播放、歌词编辑与聆听设置。它仍是开发预览，完整 DSD、标签管理与正式发布验收见 [ROADMAP.md](ROADMAP.md)。

## iOS 与 LAN

Mac 的「iOS 连接」页面可手动开启服务、生成配对码、查看终端输出状态并撤销配对。iOS 原生工程位于 [iOS/NegiPlayeriOS.xcodeproj](iOS/NegiPlayeriOS.xcodeproj)；签名安装、配对步骤、音频与 MV 链路见 [iOS/README.md](iOS/README.md)。Mac 管理文件和索引，iOS 只读浏览分页 API，音频由 iOS EQ 与系统／USB 路由处理。Mac 不将自己的音量或 DSP 应用于传输流。

0.4 已通过 macOS Release、iOS 设备 SDK 和模拟器构建。Device Hub 的 iPhone Duo iOS 27.1 模拟器完成 LAN 配对、曲库浏览、PCM 播放、封面／LRC、静音 MV、展开／闭合布局和主题／语言检查；Mac 的 E.S.combo USB 声卡完成 44.1／48／96 kHz 回读，JadeAudio JA11 完成 44.1–384 kHz 的八档源采样率切换回读及 EQ／暂停恢复检查。iOS 实体 USB、硬件折叠、后台长时播放及断连恢复仍待真机验收，iOS 首版提供 Xcode 源码工程，需要自己的签名配置。详细证据和限制见 [VALIDATION.md](VALIDATION.md)。

「外观与语言」可独立选择主题和界面语言；音乐标签和歌词保持原文。共用图标母版与设计说明见 [Resources/Brand](Resources/Brand)。

## 音乐目录只读

导入采用**引用原目录**：不复制音乐、不搬移、不重命名、不写回标签、不在音乐目录中生成索引、封面缓存或歌词侧文件。目录书签使用 `securityScopeAllowOnlyReadAccess`；索引和歌词草稿保存在本机的 `~/Library/Application Support/NegiPlayer/Library.sqlite`。导出歌词和备份时，也拒绝音乐根目录及其子目录（包括符号链接指向的位置）。

只读引用是默认产品行为。未来文件编辑必须作为另行开启的功能，不可随导入或扫描自动执行。

扫描只读元数据，按相对路径、大小与修改时间复用结果；完成扫描后才提交完整索引。取消或失败保留旧索引。选中曲目时在后台计算音频载荷 SHA-256，用于歌词版本关联；它不参与首次全库扫描。磁盘离线时保留记录和歌词草稿，可重新授权。

## 使用

1. 解压应用包，打开 `NegiPlayer.app`，选择「导入文件夹」并引用本地或外置盘目录。
2. 在专辑、艺人或所有曲目页搜索并播放；格式、采样率和可用状态可以组合筛选，曲目可按标题、艺人、专辑、碟号／曲号、采样率、时长或路径排序。右键可安排下一首、加入队列、跳转专辑／艺人；队列支持移动、移除和清空待播。
3. 点击底栏封面／曲名或「正在播放」（⌘⇧P）：没有对应 LRC 时居中显示封面与控制；有对应 LRC 时左侧封面与控制、右侧随播放时间滚动高亮歌词。点击歌词定位，手动滚动暂停跟随，点击「恢复跟随」继续。
4. 从「歌词与时间轴」粘贴 TXT 或导入 TXT、LRC、Enhanced LRC、SRT、Negi 工程。选择逐句／逐字／逐词，播放时按 T 或拖过文字打点，暂停后精修；输入框拥有焦点时 T 正常输入文字。
5. 撤销／重做、行标记拖动、波形跳转、整体 offset 与纳秒时间输入均保存到本机草稿。重新载入曲目恢复未完成草稿。
6. 导出完整工程可保留未打点、显式结束时间和原始 Negi 工程字段；LRC 不包含结束时间和编辑历史。导出位置须在音乐目录外。

应用使用 ad-hoc 开发签名，尚未 Developer ID 签名或公证。预览包不默认启用 App Sandbox；书签与应用写入策略仍遵循上述只读规则。`LMP_SANDBOX=1` 可构建带沙盒 entitlement 的版本，但该配置尚未完成全流程验收。

## 本轮能力

| 内容 | 当前行为 |
| --- | --- |
| MP3 / FLAC / WAV | AVAudioFile 真正解码与 PCM 兼容播放；WAV 按整数／浮点实际编码识别 |
| M4A | 分别识别 AAC 与 ALAC；均实际解码 |
| AIFF | 扩展格式实际解码，识别整数 PCM；不代表所有 AIFF 变体已验收 |
| DSF / DFF | 识别 DSD 参数，区分 raw DSD 与 DST；原始 DSD 解码、DoP 设备输出尚未接通 |
| 封面 | FLAC PICTURE、ID3 APIC/PIC（MP3／WAV／DSF）、M4A covr；缺失时读取同目录图片，缓存仅写本机应用数据 |
| 正在播放 | 居中封面或封面／歌词双栏；同目录 LRC 只读匹配、offset、高亮滚动与点击定位 |
| ISO 专区 | 单独收录、识别 SACD 主目录／ISO 9660／无效头；不进入音频队列，镜像播放未接通 |
| 输出与 EQ | 按 UID 记住设备，USB 连接类型、支持采样率及驱动物理格式回读；可选跟随源采样率，停止输出并确认后载入；10 段 PCM EQ 与前级可旁路 |
| LAN 与 iOS | 手动开启私有网络 HTTPS、完整证书指纹核对和一次性配对码；Mac 只读输出源 PCM，iOS 负责增益、EQ 和系统／USB 路由 |
| iOS MV | 同目录唯一同名本地视频，手动开启；播放项只插入视频轨道并强制静音，失败回退封面和歌词 |
| 聆听设置 | 逐曲／专辑 ReplayGain、数字余量、标签峰值保护、音量上限、静音；设置本机保存 |
| 系统控制 | MediaPlayer Now Playing、媒体控制命令、原生播放菜单；系统控件交互仍待验收 |
| 输出状态 | 显示实际源编码、PCM 处理、软件音量、设备与输出采样率；明确标注系统混音 |
| 浏览与队列 | 组合筛选、数值与自然排序；独立队列、下一首、移动、移除与清空待播 |
| SQLite | WAL、原子扫描提交、草稿与修订、完整性检查、Online Backup 一致备份 |
| 歌词 | 精确到纳秒，0 与未打点分开，100 分钟以上，正负 offset，UTF-16 与完整字素簇边界 |

Mac USB PCM 设备与采样率回读已验证；没有完成独占、PCM bit-perfect、实体 iOS USB 或 DoP 接收端验收。DoP 封装器只有纯数据测试，未连接输出设备。DSD 文件会明确提示未接通，禁止冒用直通状态。

AVFoundation 的标签读取覆盖随容器而异，当前不是完整 mp3tag 替代品。原生多值字段全覆盖、批量标签编辑、播放列表、自动监听、无缝播放、库切换与恢复向导仍待完成。

## 封面与 LRC 匹配

封面优先读取音频标签内的正面封面（如 Mp3tag 写入的 APIC／PICTURE），再尝试同一发行分组内其他曲目的内嵌图；缺失时读取 `Cover`、`Folder`、`Front`、`Album` 等同目录 JPG／JPEG／PNG／WebP。`CD1`、`Disc 1` 等碟片目录可回退到其父目录，但不会越过已授权根目录或读取指向根目录外的符号链接。图片保持比例；768 像素缩略图缓存和尺寸／修改时间失效检查均在本机应用数据完成，不会把封面写入 WAV 或其他音频。单个标签／图片限制 24 MiB；超限、损坏或未知变体回退为占位图。

LRC 先匹配音频文件同名（扩展名忽略大小写），其次匹配同目录唯一的歌曲标题同名文件，不随机选取其他歌词。支持 UTF-8、带 BOM 的 UTF-16、Enhanced LRC 的行时间和正负 offset；播放页目前高亮整行。找不到、损坏或编码不支持时保持居中布局；播放页菜单可刷新封面与歌词。自动显示不修改歌词工作室草稿，也不写回侧文件。

ISO 仅做头部识别。有效 `SACDMTOC` 只能证明存在 SACD 主目录，不能证明全部轨道可解码；ISO 9660 是数据镜像，不等同于 CD-DA。SACD 曲目解析、DST／DSD 解码与 BIN／CUE 播放列入后续工作。

## 构建

需要支持 SwiftUI `glassEffect` 的 Xcode / macOS SDK（26 或更新）及 Swift 6 编译器。本机使用 Xcode 27.1 beta、macOS SDK 27.0、Swift 6.4；Swift 语言模式为 5。没有外部 Swift Package 下载依赖。

```sh
# 可以明确指定本机安装的 Xcode；脚本不会修改系统 xcode-select。
export DEVELOPER_DIR=/Applications/Xcode-27.1-beta.app/Contents/Developer
zsh scripts/build-app.sh
open dist/NegiPlayer.app
```

默认为 release 构建。缓存、签名 staging bundle 放在临时目录，避免 iCloud 给应用添加 FinderInfo 影响签名；可用 `LMP_WORK_DIR` 指定本机缓存位置。成功后应用复制到 `dist/NegiPlayer.app`，签名验证针对 staging bundle 执行。

## 验证

```sh
# FFmpeg 仅用于生成原创、低电平测试音，不是播放器依赖。
python3 scripts/generate-fixtures.py /tmp/NegiPlayer-fixtures
python3 scripts/generate-presentation-fixtures.py /tmp/NegiPlayer-fixtures /tmp/NegiPlayer-presentation
NEGI_FIXTURES=/tmp/NegiPlayer-fixtures zsh scripts/swift.sh test

# 原生应用解码报告，使用上述同一批样本。
open -n dist/NegiPlayer.app --args --verify-fixtures /tmp/NegiPlayer-fixtures --report /tmp/NegiPlayer-native-codecs.json
```

受限命令执行环境可能无法使用系统压缩音频解码服务。本次将真实原生应用的解码结果单独记录在 [validation/presentation-native-codecs.json](validation/presentation-native-codecs.json)，核心测试通过 `NEGI_NATIVE_REPORT` 校验对应文件的音频载荷摘要、格式与解码帧数。报告不能代替 DAC 实测。`SelectedLibraryTests` 是可选的本机集成测试，未设置 `NEGI_PRESENTATION_REAL_INPUT` 时明确跳过；JSON 中的路径仅由用户本机提供，测试目录外不保存音乐或封面。

```sh
NEGI_FIXTURES=/tmp/NegiPlayer-fixtures \
NEGI_NATIVE_REPORT=/tmp/NegiPlayer-native-codecs.json \
NEGI_NATIVE_DSP_REPORT=/tmp/NegiPlayer-native-codecs.dsp.json zsh scripts/swift.sh test
```

原生验证命令还会生成同名 `.dsp.json`，记录原创 PCM 经真实增益节点的离线渲染结果。实际命令、41 项测试（含本机选择的只读集成样本）、外置盘测试和界面检查见 [VALIDATION.md](VALIDATION.md)。WAV 标签验证器只对生成样本的新副本写入 ASCII RIFF INFO，保留未知 chunk 并验证载荷不变；未接入应用，也不会对用户音乐调用。

现代 Hi-Fi 功能与已实现／后续范围见 [MODERN_HIFI.md](MODERN_HIFI.md)。

已实地检查本机 Audirvana 3.5.50 的浏览与设置界面，功能对照和接入次序见 [AUDIRVANA_REFERENCE.md](AUDIRVANA_REFERENCE.md)。研究项与已接通功能分别标注。

## 模块与工具来源

- `LibraryDomain`：曲目、目录、只读引用策略；`LibraryStore`：系统 SQLite。
- `MediaIO`：只读扫描、格式探测、载荷摘要、独立 PCM 波形分析、只读封面／侧文件歌词与 ISO 头部识别。
- `AudioCore`：一个 AVAudioEngine 播放会话、Core Audio 设备、EQ、时钟与独立 DoP 数据封装器。
- `LyricCore`：文档、解析、Unicode、时间、Negi 适配；`FileOperations`：生成 WAV 副本验证工具。
- `NegiPlayer`：SwiftUI / AppKit 界面、MediaPlayer 系统控制与文件选择授权。
- Apple [Swift](https://www.swift.org/)、[AVFoundation](https://developer.apple.com/documentation/avfoundation)、[Core Audio](https://developer.apple.com/documentation/coreaudio)、[Liquid Glass](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)。
- [SQLite Online Backup](https://sqlite.org/backup.html)；[FFmpeg](https://ffmpeg.org/) 只用于本机样本生成。
- [NegiFlick 固定歌词基线](https://github.com/HachiMiku39/NegiFlick/tree/cf64f04900bf2429ee9a207b1bf7213feba6c2f9)，版本与许可证状态见 [THIRD_PARTY.md](THIRD_PARTY.md) 和 [DEPENDENCIES.json](DEPENDENCIES.json)。未包含其音频、角色图像或游戏运行模块。

## 开源与贡献

NegiPlayer 源码采用 [MIT](LICENSE) 许可。第三方和参考项目的状态见 [THIRD_PARTY.md](THIRD_PARTY.md)，本项目许可不改变它们的许可。欢迎提交 issue 或 PR，贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。公开仓库仅包含源码和原创信号验证记录，不包含个人曲库、书签或音乐。
