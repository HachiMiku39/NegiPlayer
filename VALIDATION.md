# NegiPlayer 0.4.0 验证记录

2026-10-11，Apple Silicon arm64、macOS 27.2、Xcode 27.1 beta、macOS SDK 27.0／iOS SDK 27.1、Swift 6.4（语言模式 5）。最低 macOS 14／iOS 17；低版本及 Intel 真机未验收。下文 0.3 记录保留为历史证据。

## 构建与自动化

macOS Release 与 ad-hoc 签名、iOS 设备 SDK 未签名构建、模拟器本地签名构建均通过。iOS 模拟器使用默认的 Sign to Run Locally，以便正常使用 Keychain；设备 SDK 的未签名产物不能作为可安装 IPA。[Mac 日志](validation/lan-mac-build.log)、[iOS 设备编译日志](validation/lan-ios-device-build.log)、[模拟器日志](validation/lan-ios-simulator-build.log)均移除个人路径。

**42 项 XCTest 通过，0 失败、0 跳过**：[测试日志](validation/lan-core-tests.log)。新增 LAN 检查包括有界 HTTP 报文／Range、私有 IPv4／IPv6、一次性配对与撤销、路径与符号链接边界、PCM 浮点交错／定位、MV 唯一同名匹配、Duo 窗口布局，以及真实 NWListener／URLSession HTTPS 配对、错误证书指纹拒绝、206 流与 LRC offset。大响应回归使用 14,000 首原创元数据、1,400 张专辑和 500 首分页，连续三轮完整核对数量；曾复现提前取消 TLS 导致连接中断，现使用最终消息并等待对端关闭／有界超时后清理。设置测试确认新增可选采样率策略能读取 0.2／0.3 无该键的历史 JSON。选择真实曲库的两项集成方法由本机输入和原生报告支持；未设置这些本机输入时会明确跳过，不包含私人文件。

[原创 PCM 解码与 LAN 报告](validation/lan-native-codecs.json)由原生应用生成：WAV／MP3／FLAC／AAC／ALAC 各 4096 帧，LAN 浮点 PCM 与独立 AVAudioFile 解码逐样本相同，源大小／时间未变。DSF／raw DFF 仅探测，不宣称解码或移动播放。三个本机选定真实 PCM 文件同样核验 4096 帧，个人报告不发布。

[Mac 原生 DSP](validation/lan-native-codecs.dsp.json)验证 −6 dB 增益；[移动增益组件原生 DSP](validation/lan-native-codecs.mobile-dsp.json)使用 iOS 直接引用的 PCMLevelControl 三级增益组件，经真实 AVAudioEngine 离线渲染，验证 −180／−96／−6／0／6／30／72 dB、双声道与 50% 音量，误差在相对 0.3% 内。此测试在 Mac 渲染共享组件，不代表实体 iOS／DAC 波形测量。

复现（源码工程，FFmpeg 仅生成原创信号）：

```sh
python3 scripts/generate-fixtures.py /tmp/NegiPlayer-fixtures
zsh scripts/build-app.sh
# 可由 debug 原生应用的开发验证菜单生成 codec、DSP、mobile-DSP 报告。
# 非受限环境可直接运行原生解码／DSP；受限环境使用本次实际报告。
NEGI_FIXTURES=/tmp/NegiPlayer-fixtures \
NEGI_NATIVE_REPORT=/tmp/NegiPlayer-native-codecs.json \
NEGI_NATIVE_DSP_REPORT=/tmp/NegiPlayer-native-codecs.dsp.json \
NEGI_NATIVE_MOBILE_DSP_REPORT=/tmp/NegiPlayer-native-codecs.mobile-dsp.json \
zsh scripts/swift.sh test
xcodebuild -project iOS/NegiPlayeriOS.xcodeproj -scheme NegiPlayeriOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

## Mac USB 实测

参考本机 Audirvana 3.5.50 的 DAC 配置后，独立实现设备能力与源采样率策略。[USB 回读记录](validation/usb-output.json)：E.S.combo 驱动支持 44.1／48／96 kHz，立体声物理 16-bit PCM；客户端为 32-bit Float，分别显示而不混淆。开启跟随源采样率，停止输出、请求并回读，三档均确认后开始播放；88.2 kHz 源保留当前 96 kHz 并明确显示采样率转换。低电平原创信号、软件音量约 1.4%，完成 EQ 开启／旁路、播放／暂停，结束恢复 48 kHz。

更换 DAC 后，[JadeAudio JA11 回读记录](validation/usb-ja11-output.json)确认 USB 设备列出的 44.1／48／88.2／96／176.4／192／352.8／384 kHz 八档均实际播放，源／客户端／设备采样率一致。原创 WAV 的 PCM16 峰值 600，软件音量 10%；384 kHz 下完成 EQ 开启／旁路和暂停／恢复。设备当前回报立体声 16-bit PCM，客户端 32 位格式；主音量显示固定／未提供。结束保持暂停，恢复原 352.8 kHz。

这些是驱动／客户端状态验证，没有声学或硬件环回捕获。当前仍经系统混音和软件音量；独占、整数 HAL、逐比特、硬件音量、DoP、实际拔插／休眠及实体 iOS USB 未验收。

## iPhone Duo 模拟器与界面

Device Hub 内可用的 iPhone Duo iOS 27.1 模拟器完成 Bonjour 发现、完整指纹与一次性配对码连接、Keychain 配对恢复、只读分页曲库、原创 FLAC／WAV／ALAC PCM 播放、封面、混合语言 LRC、高亮与点击定位。人声 EQ 预设与开启状态保存，Mac 终端页回报 Speaker／44,100 Hz／EQ 开启／暂停。

Day／Night／Negi 与英／日／中文界面已检查；标签和原歌词保持原文，切换后当前页面及暂停曲目保留。Duo 展开使用封面／控制与歌词双栏；闭合无 LRC 时居中封面，控制可滚动。修复迷你播放器遮住侧边设置入口的问题。模拟器窗口切换不代表实体折叠或后台验收。

[专辑双模式记录](validation/album-display-ui.json)：Mac 与 Duo 原生界面显示原创 FLAC／MP3／ALAC 内嵌封面、WAV 文件夹图及无封面占位；封面网格与缩略图列表可切换，同一专辑进入对应曲目。Mac 重启保留列表选择，Duo 横向宽窗口显示专辑／曲目双栏。界面文案提供中／日／英翻译。重新搜索 Bonjour 等待浏览器停止后再启动，避免连续搜索时丢失搜索请求。

原创 640×360 H.264 测试 MV 故意含 AAC 音轨；应用组成的播放项只插入视频轨道，并持续强制 mute／volume 0。屏幕可见视频帧、歌词叠加和歌曲进度；歌词定位 12.2 秒后视频帧时间 12.167 秒。默认仍是封面和歌词，只有同目录唯一同名视频才提供 MV 开关；损坏／不可加载时保留封面并提示。未对全部视频容器和实体 iOS 输出作验证。

## 本轮外置盘只读复核

[汇总](validation/lan-readonly-summary.json)：77,521 个非隐藏文件无增删，全部大小／修改时间未变；14,217 个音频扩展名文件的大小／修改时间／inode 均未变。两个空 TXT 的 inode 不同，原因未确定，因此完整目录 inode 比较不标记通过。不是全库逐字节哈希。私人路径、书签、歌词／音乐／封面、配对码／token、证书与个人界面截图均未发布。

## 发布范围与待验收

macOS arm64 ad-hoc 开发预览与 iOS Xcode 源码工程。实体 iOS 需用户开发签名后安装，USB、后台／锁屏、网络切换、硬件折叠和长时播放仍需实测；最低 OS、Intel、正式签名／公证、App Sandbox 全流程、独占／DSD／ISO 音频仍未完成。LAN 是本项目协议，没有实现 RAAT；Mac 管理源文件和本机 SQLite，iOS 只读 API 且不保存音乐副本或可写数据库。

---

# NegiPlayer 0.3.0 验证记录

2026-10-11，macOS 27.2（26B5101f）、Apple Silicon arm64、Xcode 27.1 beta（27A9269）、SDK 27.0、Swift 6.4，语言模式 5。最低部署目标 macOS 14；尚未做低版本或 Intel 真机验收。

## 构建与核心测试

Release 构建和 ad-hoc 签名检查通过。[构建日志](validation/public-build.log)已移除本机路径。运行包没有开发验证请求、开发数据库、音乐或 FFmpeg。缓存和签名 staging 放在临时目录；预览构建省略 dSYM，可用 `NEGI_DEBUG_SYMBOLS=1` 恢复正式调试符号。

**33 项 XCTest 全部通过，0 失败、0 跳过**：[完整测试日志](validation/public-core-tests.log)。其中 Audio 3、Lyrics 8、Store 3、File Operations 1、Probe 2、Metadata 1、Browse 2、Listening 4、Presentation 8、Selected Library 1。

0.2 新增测试覆盖 ReplayGain 专辑回退、无效标签、数字余量、峰值与 EQ 增益预算、设置重启与未来版本保护，以及真实 PCM 增益节点的渲染。原有测试继续覆盖纳秒／Unicode／Negi 工程往返、SQLite 一致备份、扫描取消、符号链接导出保护、载荷身份、FLAC 多值标签、队列及 DoP 纯字节封装。

受限 shell 不能连接部分系统压缩解码和 Audio Unit 服务。直接运行的原生应用先生成解码与 DSP 报告，XCTest 再核验真实结果。早期 shell Audio Unit 初始化失败的诊断记录保留在本机；最终通过的运行使用实际原生报告，没有用模拟解码或模拟 DSP 替代。

可复现命令（FFmpeg 只生成原创测试音）：

```sh
python3 scripts/generate-fixtures.py /tmp/NegiPlayer-fixtures
zsh scripts/build-app.sh
open -n dist/NegiPlayer.app --args \
  --verify-fixtures /tmp/NegiPlayer-fixtures \
  --report /tmp/NegiPlayer-native-codecs.json
# 等待原生应用写出上述 JSON 和同名 .dsp.json，再执行：
# 可选本机集成样本：NEGI_PRESENTATION_REAL_INPUT=/path/to/local-selection.json
NEGI_FIXTURES=/tmp/NegiPlayer-fixtures \
NEGI_NATIVE_REPORT=/tmp/NegiPlayer-native-codecs.json \
NEGI_NATIVE_DSP_REPORT=/tmp/NegiPlayer-native-codecs.dsp.json \
zsh scripts/swift.sh test
```

## 原生音频与设置验收

[0.3 解码报告](validation/presentation-native-codecs.json)：原创 WAV／MP3／FLAC／AAC／ALAC 各实际解码 4096 帧；生成 DSF／raw DFF 的 DSD64 参数读取成功，解码状态为 `not-connected`。读取前后源文件大小和修改时间相同。

[0.3 真实 PCM 渲染](validation/presentation-native-codecs.dsp.json)：48 kHz 双声道、输入幅度 0.25；旁路输出平均幅度 0.25，−6 dB 增益节点输出 0.1253019，比例约 0.501208，符合 10^(−6/20) 的预期。该离线测量没有 DAC 输出，不能据此宣称 bit-perfect。

[0.2 原生聆听设置界面检查](validation/listening-ui.json)使用独立生成的 FLAC 和隔离开发数据库：

- 逐曲标签 −6 dB、专辑标签 −3.25 dB 切换后读数正确；增加 3 dB 数字余量后实际预增益 −6.25 dB。
- 将软件音量上限降至 20%，当前音量同步降至 20%；静音保留滑杆值。
- 选择人声轻调预设、启用 EQ、选择内置扬声器；关闭并重启后，响度、余量、音量上限、EQ 曲线／前级／启用状态和设备 UID 恢复。
- 输出回读 48 kHz、2 声道、32 位客户端格式，显示 SRC、EQ、真实增益和系统混音。客户端位深不是硬件 DAC 位深。
- MediaPlayer 的 Now Playing 和公开远程命令已接入并编译通过；系统控件界面访问超时，未宣称媒体键、控制中心或远程定位交互验收通过。

## 0.3 封面、播放页与 ISO 验证

8 项新增 Presentation 测试覆盖 FLAC 正面封面优先、ID3v2.2／2.3／2.4（UTF-16 描述）、WAV ID3／DSF 元数据／M4A covr、损坏与超限标签、非方形图片比例、同发行其他曲目回退、目录封面与多碟父目录、缓存失效和只读边界、LRC 名称优先／编码／排序／offset，以及 SACD／ISO 9660／无效头部独立扫描。缓存目录配置到音乐根目录中时拒绝写入；根目录外符号链接被忽略。

本机选择的集成样本额外验证了真实 FLAC／MP3 内嵌封面、同名 LRC、SACD 镜像头，以及源大小／修改时间／inode 不变；路径由 `NEGI_PRESENTATION_REAL_INPUT` 指向的本机 JSON 提供，未随源码或预览包分发。没有把真实音乐或图片复制进测试目录。音乐／图片／LRC／ISO 的 16,341 个非隐藏文件在本轮前后未增删，大小、修改时间和 inode 均相同；这不是逐字节全库哈希。所选外置盘的 WAV 目录没有相邻封面，WAV 的目录封面分支使用原创 WAV／PNG 验证。

[播放页界面记录](validation/presentation-ui.json)使用隔离开发数据库与原创低电平音频／图片／歌词：专辑格显示 FLAC／MP3／ALAC 内嵌图和 WAV 目录图；重启恢复缓存。底栏封面可展开正在播放；无 LRC 居中，有匹配 LRC 为左右布局。点击 12 秒歌词、加上 200 ms offset 后播放器读数为 12.2 秒，对应行高亮且居中；手动滚动切换为恢复跟随按钮，恢复后回到当前行。切到无 LRC 曲目后歌词列消失，封面和曲名更新。ISO 专区独立显示三种头部状态，没有播放按钮。

iCloud 工作目录中的原创验证样本曾停留在原生探测阶段，诊断保留本机；同一批原创字节放到本地临时目录后，原生报告和 33 项测试全部完成。没有以旧报告、模拟解码或模拟 DSP 代替本轮结果。未宣称全部图片／ID3 变体、所有 LRC 编码、译文或逐字高亮已验收。

## 大型只读曲库与歌词首轮

0.1 阶段通过原生选择器引用外置盘 Music：13,848 个音频文件、约 791 GB、1,688 个保守发行分组，重启恢复目录与索引；8 个未识别文件保留错误状态。只读抽样 FLAC／ALAC／WAV／MP3／AIFF 各实际解码 4096 帧，含 44.1／96 kHz；DSF DSD64 与 raw DFF DSD256 仅探测。不是全库完整解码。

全部 13,848 个音频文件的大小、修改时间和 inode 未变，未增删。更宽的非隐藏文件快照中 3 个非音频文件 inode 不同而大小／修改时间相同，完整范围未判定通过，也未归因；没有对约 791 GB 全库逐字节重哈希。包含个人路径、曲名、书签和实际曲库截图的报告仅保留本机，不发布。

实际界面完成搜索、组合格式／采样率筛选、PCM 播放／暂停／seek、队列编辑；三行原创歌词含组合字符和日文，完成 T 打点、撤销／重做、输入焦点保护、音乐目录外导出 LRC／完整工程、草稿恢复。纳秒与 Unicode 边界另有自动化测试。原生 Liquid Glass 在 macOS 27 实际运行；减少透明度分支只做源码检查。

## 尚未验收或接通

没有 USB DAC、独占、PCM bit-perfect、DoP 接收端、DSD／DST 解码、SACD／CD 镜像播放、硬件音量或断连／休眠的通过记录。DoP 只有纯数据测试。尚未验证全部格式变体、十万曲目、崩溃注入、Intel 或低版本 macOS。应用为未公证的 ad-hoc 开发预览，App Sandbox 配置未全流程验收。高级 DSP、无缝、标签管理与网络播放见 [ROADMAP.md](ROADMAP.md) 和 [MODERN_HIFI.md](MODERN_HIFI.md)。
