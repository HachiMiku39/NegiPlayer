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
