# DoP 输出（macOS 0.7.0）

在「输出与均衡器」明确选择支持 DoP 的 USB DAC，然后直接播放双声道 DSF／未压缩 DFF。DSD64 使用 176.4 kHz、DSD128 使用 352.8 kHz 的 24 位 DoP 载波。当前仅接入单音频流、交错双声道、24 位打包小端、非混音整数格式；不满足时停止并报错，不自动转 PCM。

DoP 跳过软件音量、音量上限、响度、EQ 和 SRC。请先调低 DAC 本机音量。播放页与输出页禁用软件增益控制；静音会暂停曲目并发送有效 DSD 静音，取消静音后需手动恢复播放。暂停与欠载期间保持 0x05／0xFA 标记连续；欠载不推进曲目位置。定位时先停止 IOProc，重新定位到 16 个 DSD 采样边界，预缓冲后恢复。队列切换暂不支持无缝播放。

源码使用只读 FileHandle 和有界 DSD 解析器，不调用 PCM 解码器。DSF 支持 4096 字节声道块、1／8 两种位序；DFF 要求 raw DSD、SLFT／SRGT 双声道。DST 压缩、SACD ISO、DSD256 和多声道暂不支持。其他平台的播放通路仍为 PCM，本次 DoP 功能只在 macOS。

HAL 初始化先获得所选设备独占权，再建立 IOProc，切换并等待所需的非混音整数物理格式。物理格式会确定客户端格式；再次设置 mixable virtual format 会使系统切回 Float32，因此不这样处理。启动前分别回读物理／客户端格式、采样率与独占权；运行中监测格式变化、独占权和断开，异常停止。关闭时尝试恢复原设备格式和采样率，再释放独占权，不修改系统默认输出设备。

## 2026-10-22 实测

- 真实曲库 DSF／DSD128 音乐，Sony WM1A USB DAC。
- 20 秒输出测试含暂停、定位到 30 秒后恢复：物理／客户端均为 352800 Hz、24-bit、2 ch、6 bytes/frame、flags 76，独占确认，无欠载、无格式故障。
- 用户现场确认 WM1A 屏幕显示 DSD 5.6 MHz／DSD128，耳机声音正常。
- NegiPlayer 原生界面中直接选择另一首 DSD128／DSF，播放、暂停、进度定位和恢复通过，软件音量／响度／EQ 控件旁路状态正确。
- 停止 DoP 并在界面重新选择 WALKMAN 后，设备回读恢复到 44.1 kHz。
- 源音乐文件大小与修改时间保持不变。公开报告不包含曲目、路径、设备 UID 或序列号。

当前没有自动读取 DAC 的 DSD 锁定状态；应用中的待确认提示不能证明 DAC 接收结果。此处 WM1A 的锁定结论来自用户现场观察。DSD64 的实体接收端、DFF 真机音乐、长时间播放及其他 DAC 仍待验证。

## 规范

- [DoP open standard 1.1](https://dsd-guide.com/sites/default/files/white-papers/DoP_openStandard_1v1.pdf)：每声道先发生的 DSD 位放在低 16 位字段的最高位；USB LPCM 字节为小端，因此一对按时间排列的 MSB-first DSD 字节写为「第二字节、第一字节、标记」。
- [Sony DSF 1.01](https://dsd-guide.com/sites/default/files/white-papers/DSFFileFormatSpec_E.pdf)：按 bits-per-sample 字段规范化位序。
- [Philips DSDIFF 1.5](https://dsd-guide.com/sites/default/files/white-papers/DSDIFF_1.5_Spec.pdf)：只接入未压缩交错双声道。
- 使用 Apple CoreAudio 系统 API，无第三方解码库或 FFmpeg 运行时依赖。
