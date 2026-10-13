# Roon 功能参照与 NegiPlayer 0.5

用户提供的 Roon Legacy 文件夹包含 Windows 安装程序，没有可读取的设置手册或源码。本机未运行 Windows Roon；以下参照来自 Roon 官方文档，并区分 NegiPlayer 当前实现与后续工作。安装程序、补丁、RAAT、图形与商业资源均未加入项目。

| 功能方向 | NegiPlayer 0.5 的处理 |
| --- | --- |
| 音乐主机与多个播放设备 | Mac / Windows 提供只读曲库；Mac / Windows / iOS / Android 独立播放，每个端点自行处理 DSP 和音频输出 |
| 输出设备管理 | 主机显示配对端点及其上报的输出、客户端采样率、EQ 和播放状态；可撤销配对 |
| 音频设备设置 | Windows 明确选择 WASAPI 设备；Android 请求系统／USB 首选设备并显示实际路由；Mac / iOS 保留各自原生输出设置 |
| DSP 与响度 | 端点软件音量、10 段 EQ、前级、ReplayGain、数字余量及峰值标签保护；不把主机聆听 DSP 写入文件或 LAN 源流 |
| 信号路径 | 分清源 PCM、端点 DSP 与系统输出；未读取的硬件时钟不当成已经测得的 DAC 采样率 |
| 多分区同步 | 当前为独立端点播放；共用时钟、漂移校正、分区同步和远程播放控制尚未实现 |
| 独占、ASIO、原生 DSD / DoP | 新 Windows / Android 音频链路不宣称实现；需要独立驱动、格式与 DAC 测试 |
| 卷积、参数 EQ、扬声器延迟 | 后续 DSP 工作；当前 10 段 EQ 不标为完整的 Roon DSP 引擎 |

参考 [Roon Audio Setup Basics](https://help.roonlabs.com/portal/en/kb/articles/audio-setup-basics)：输出设备启用、设备配置、音量模式及 Windows event-driven WASAPI。NegiPlayer 据此采用明确设备选择和端点设置；不声称 Roon 兼容或 Roon Ready。

参考 [Roon Signal Path](https://help.roonlabs.com/portal/en/kb/articles/signal-path)：向用户说明可观察的音频处理链。NegiPlayer 据此展示实际客户端格式与输出路线，避免将开启 EQ 或系统混音的链路标为逐比特输出。

参考 [Roon MUSE](https://help.roonlabs.com/portal/en/kb/articles/muse)：DSP 功能组织方式。参数 EQ、卷积和跨分区同步需要另行设计与测试，本次未把它们列为已经交付的功能。

LAN 接入步骤：主机只读导入音乐文件夹，手动开启服务；播放端输入主机局域网 HTTPS 地址，核对完整 SHA-256 指纹，再输入 5 分钟内有效的单次配对码。Windows 主机首版使用手动地址；Mac 主机继续提供 Bonjour 发现。Windows 防火墙首次提示时，在需要使用的家庭／私人网络上允许应用通信。曲库文件管理始终留在主机。
