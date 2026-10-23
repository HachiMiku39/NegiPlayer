# 本机全曲库 SensMe 分析

本机全库原版引擎参照任务已经完成，生成了缓存及对照结果。产品方向已改为原生 SensMe，不依赖 Wine / 虚拟机。独立原生断点队列和应用 8 路队列均已实现。原生全库已完成 13,839 首分析、11 项输入失败，用时 1,128.6 秒，结果已导入应用并通过正式 Swift 缓存校验。状态见 [NATIVE_SENSME.md](NATIVE_SENSME.md)。下文原版引擎基准与命令仅供历史研究复现。

## 原生任务

在项目目录构建 `SensMePCMStream`，并将 C 动态库、构建缓存和私有检查点放在外置盘上的工作目录。以下路径为示例，`/path/to/external-work` 应替换为实际外置工作目录。

```sh
zsh scripts/swift.sh build --product SensMePCMStream
clang -dynamiclib -O3 -DNEGI_SENSME_SCALAR \
  -I Sources/CSensMeCore/include Sources/CSensMeCore/*.c \
  -o /path/to/external-work/libSensMeCore.dylib
python3 scripts/sensme-native.py \
  --database "$HOME/Library/Application Support/NegiPlayer/Library.sqlite" \
  --library /path/to/external-work/libSensMeCore.dylib \
  --pcm-decoder /path/to/built/SensMePCMStream \
  --state /path/to/external-work/private-sensme-state --workers 8
```

`SensMePCMStream` 的实际路径由 Swift 构建输出确定。使用同一命令续跑；`--retry-failures` 重新尝试失败项。检查点位于 `current.json` 指向的配置子目录，其中 `analysis.sqlite` 保存逐曲状态，`Records` 保存结果，`FailedDiagnostics` 保存错误，`analysis-complete.json` 明确区分全库与样本完成。配置改变会创建新目录，保留旧证据。应用缓存导入需显式运行下述 `sensme-cache.py`，该步骤重新验证源摘要并保留旧分析与已采用的标签／封面。

M3 Max 上对同一批 20 首多格式歌曲交替测量三轮，包含源摘要、解码、C 分析和检查点写入，使用已预热的文件缓存：4 路中位数 7.494 秒，8 路 5.019 秒，吞吐约提高 1.49 倍；不含约 0.53 秒的清单／配置初始化。120 个结果均与原版一致。本轮选择 8 路及编译器自动向量化 C 路径；这不是全曲库持续速度或 GPU／ANE 加速的结论。

```sh
python3 scripts/test-sensme-native.py
```

13 项原生队列检查中的两项真实 C 管道测试需要设置 `NEGI_NATIVE_LIBRARY` 为已构建的库路径，其余检查使用明确的假内核验证任务管理。

## 导入应用缓存

先确认 `analysis-complete.json` 的范围和失败记录，再传入 `current.json` 指向的实际配置子目录：

```sh
python3 scripts/sensme-cache.py \
  --state /path/to/external-work/private-sensme-state/PROFILE \
  --records "$HOME/Library/Application Support/NegiPlayer/Enrichment/Records"
```

导入会核对源文件完整 SHA-256、检查点中的结果摘要及 SMFMF 结构。旧分析进入历史字段，源未改变时保留 Gracenote 候选和已采用的标签／封面。失败项写入单独的 `SensMeFailures`，不会阻断成功记录。应用重新启动后加载缓存；应用内队列可验证并复用已有原生结果，也可重新选择失败曲目重试。

## 原生全库验收（2026-10-24）

最终原生分析为 13,839 成功、11 失败、0 待处理，用时 1,128.6 秒，默认 8 路。13,839 条已导入，过期和导入失败为 0，正式 Swift 缓存解析与摘要校验全部通过，旧结果历史与补全字段均保留。源音频从未修改，原生任务不生成整曲 PCM 文件。167 条有效记录没有 GBPM，继续保留其其他分析内容。

全库与历史原版缓存完整相同的有 13,786 条；32 条与重新运行的未修改原版相同；21 条与明确零尾部的受控参照相同。最后一组涉及原版描述器的越界读取，不能称作与其任意堆内存内容逐字节相同。完整限定见 NATIVE_SENSME.md。

28 首真实多格式和边界样本通过应用的 Debug／Release 8 路队列，完整结果与全库记录相同。Release 项目测试共 140 项，133 通过、7 项可选集成跳过、0 失败；原生队列 Python 检查 13 项通过。

下文保留原版参照的历史测量，与当前原生实现区分。

## 原版引擎历史参照

在现有 0.7.2 的 Sony 原引擎适配上增加离线批处理工具。读取已导入的可用曲目，完整解码每首音频，不使用试听片段。音乐文件和曲库 SQLite 数据库保持只读；临时 PCM 在完成或失败后删除，结果单独存入本机缓存。

## M3 Max 实测（2026-10-23）

主机：Apple M3 Max，16 核 CPU（12 性能核、4 能效核）、40 核 GPU、64 GB 内存，连接交流电。引擎为用户本机提供的 Sony MMLib11 1.1.2.640，经 x86 Wine / Rosetta 运行。专有 DLL、兼容运行环境及个人曲库不随源码分发。

同一首约 234.54 秒 FLAC 的完整原生解码约 0.53 秒；独立 SHA-256 读取约 0.03 秒；单进程 Sony 分析约 25.3 秒。传输缓冲从 16 KiB 增大到 256 KiB、复用 Windows Python 进程后，同曲 SMFMF 二进制结果一致；缓冲调整对单曲算法耗时影响很小。

| 分析进程数 | 完成一批的秒数 | 折算首／小时 |
| --- | ---: | ---: |
| 4 | 31.81 | 453 |
| 8 | 28.37 | 1,015 |
| 12 | 34.20 | 1,263 |
| 16 | 51.61 | 1,116 |

每批每个进程分析同一个完整样本一次，所有并发结果与单进程结果逐字节相同。此表是 Wine 短时单曲基准，包含启动开销；不能当作长时间、多格式曲库的保证速度。12 进程是本次 Wine 所测配置中吞吐最高的一项，16 进程发生竞争而变慢。

随后使用本机已有的 Windows 11 ARM 虚拟机（8 vCPU、16 GB 内存）测试同一 DLL 和 PCM。三次单独启动的结果与 Wine 逐字节一致。复用 Windows 分析进程后，避开 Wine 的开销，空载单曲分析约 1.50 秒：

| 持久 Windows 进程数 | 完成一批的秒数 | 折算首／小时 |
| --- | ---: | ---: |
| 1 | 1.56 | 2,306 |
| 4 | 1.63 | 8,856 |
| 6 | 4.76 | 4,536 |
| 8 | 7.26 | 3,968 |

此表排除进程初始化，所有结果仍逐字节一致；Windows 虚拟机内的 4 进程配置在本次测试中最快。历史原版全库参照曾使用此配置，Mac 负责读取、解码、源摘要校验和缓存管理。虚拟机只读取生成的 PCM、返回分析数据，不接收曲库数据库和源音乐路径。该研究任务已经结束，虚拟机目前关机；原生队列不调用它。

DSF、未压缩 DFF 和 5.1 FLAC 已通过本机 FFmpeg arm64 完整解码测试。普通单／双声道文件先走 AVAudioFile / AVAudioConverter；系统不能解码的文件使用本机 FFmpeg，只在分析副本中转换到 44.1 kHz、16-bit、双声道。多声道仅为分析而下混，不更改播放或源文件。无有效 PCM、损坏／丢失文件及未配置逐轨解码器的 ISO 分别保留失败记录。

本轮修复两个旧限制：有效 STMM 分析可以不含 GBPM，此时 BPM 为“未确定”；4 秒、7.5 秒与 9.9 秒的真实短音频均返回了有效分析，因此移除了任意的 10 秒门槛。仍只输入原始完整时长，不补零、不循环延长、不推测节奏。

## 加速范围

该历史参照的加速来自原生 arm64 解码、本机 ARM 虚拟化、Windows 的 x86 兼容层，以及持久分析进程和合适的 CPU 并发量。Windows 11 ARM 通过其 [Prism / WOW64 兼容层](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation) 执行原版 x86 DLL。Sony DLL 的适配接口接受 PCM 并返回 SMFMF，未提供 Metal、Core ML 或 GPU 执行选项；不能通过开关将现有 x86 DLL 算法搬到 GPU／ANE。

未来若另行实现可维护的音频特征算法，可用 [Accelerate / vDSP](https://developer.apple.com/documentation/accelerate) 加速 CPU 向量与 FFT；若采用可转换的情绪／音乐嵌入模型，可用 [Core ML compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits) 让系统在 CPU、GPU、神经引擎之间调度。需要单独验证模型算子支持、精度和实际设备分配，不能将这类新模型结果冒充 Sony SMFMF。

## 历史参照工具

`sensme-library.py`、`sensme-vm.py` 和 Windows 探针只保留作本机研究复现，不进入原生 SensMe 应用运行链。应用包不包含 Sony SensMe 适配脚本、DLL 或兼容运行时。历史结果保留原版版本标识，不能替代原生检查点。

## 本机曲库完成记录（2026-10-23）

逐曲分析已结束：13,839 成功，11 失败，无待处理或运行中的曲目；覆盖 760.561 小时音频。13,839 条缓存通过原生 Swift 解析及摘要校验，全部导入应用缓存；源 SHA-256 再校验后，过期与导入失败均为 0。所有任务的源大小／mtime 与初始记录比较，变化为 0。当前曲库 ID 与任务集合一致，没有新增或漏掉的索引曲目。

11 项失败为 5 个原本缺失的文件、2 个尚无音轨抽取通路的 ISO、2 个 AppleDouble 元数据文件、1 个损坏 FLAC、1 个没有 audio data 块的 WAVE。错误及检查证据保留在私有任务目录，未删除或修改这些文件。167 条有效分析没有 GBPM，仍保留其 STMM 数据。

成功格式：FLAC 12,693、MP3 410、WAV 216、DSF 308、M4A 171、DFF 39、AIFF 2。应用缓存的 SensMe 内容与逐曲任务记录全部相同。重新打开 NegiPlayer 后加载这些缓存。

本次全库结果来自本机原版引擎参照任务；不能当作原生分析器已经接管应用的证据。原生开发继续见 NATIVE_SENSME.md。私人逐曲记录、音乐路径和数据库不会发布。

## 验证

```sh
python3 scripts/test-sensme-batch.py
```

12 项 Python 自动检查覆盖断点跳过、源变化、损坏缓存、引擎更新、显式失败重试、路径越界、SMFMF 边界、无 BPM 分析、缓存合并、虚拟机路径与响应标识，以及伪音频输入和失败日志保留。AppleDouble 元数据、没有音频 data 块的 WAVE 保留明确的输入失败原因；解码日志尾部在清理临时 PCM 前保存到私有 FailedDiagnostics，每份日志最多 64 KiB。Swift EnrichmentTests 共 17 项：14 通过、3 项可选集成跳过、0 失败；与新增的原生子模块测试合跑共 68 项，65 通过、3 跳过、0 失败。原生进度见 NATIVE_SENSME.md。另有真实 Sony 引擎的跨后端／并发结果一致性验证、额外格式完整解码和实际短曲验证。全库完成数量以本机任务最终报告为准。
