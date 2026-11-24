# Remote Go for Windows

Windows 版沿用原来的遥控器按键图、**Agent Coding** 和 **看视频**预设，以及 `.remote-go.json` 预设格式。当前为 Windows 11 预览版，程序启动、蓝牙配对、实体按键和听写还没有在 Windows 实机上验收。[下载预览版](https://github.com/Clawborn/remote-go/releases/tag/windows-preview-1)

## 给第一次使用的人

1. 选择与电脑匹配的 ZIP，Intel／AMD 电脑选 x64，Windows on ARM 选 ARM64。将整包解压到自己有权限的目录，双击 `RemoteGo.exe`。两个版本都自带 .NET 运行时。
2. 在「设置 → 蓝牙和设备 → 添加设备」中配对。按住 Chromecast 遥控器的返回和主页键，直到指示灯开始闪烁，然后在 Windows 上选择遥控器。[Google 配对说明](https://support.google.com/chromecast/answer/10109990)
3. 在 Remote Go 里打开 **Go**。按方向键或确定键，先查看「最近按键」有没有更新，再在记事本等空白输入区测试方向键和 Enter。
4. 短按信源键打开 Windows 的任务视图。长按信源键 1 秒进入或退出飞鼠，方向键移动指针、确定键点击、音量键滚动、返回键退出。主页长按切换两个内置预设。
5. 单击遥控器图上的按钮修改映射。按应用改键支持内置 Agent 及通过 `.exe` 选择自定义应用。使用「保存副本」「导入」「导出」交换预设。macOS 快捷键中的 Command 会映射到 Ctrl，Windows 独有的快捷键可以在 Windows 版里重新录入。

YouTube 和 Netflix 键仍分别关联 Codex 与 Claude。应用已打开时优先切换到已有窗口。对话框聚焦、会话列表和 Grok 侧栏导航依赖 Windows 客户端公开的无障碍元素，表现可能随客户端版本变化。Codex 用量需要 `codex.exe` 位于 `PATH` 且已有登录。

## 听写

- 默认语音快捷键为 **Win + H**，识别由 Windows 或用户自选的听写软件完成。默认使用电脑麦克风。Windows 自带听写可以在界面中点麦克风或说「停止听写」结束。[Microsoft Windows 语音键入](https://support.microsoft.com/en-us/accessibility/windows/use-voice-typing-to-talk-instead-of-type-on-your-pc)
- 如果听写软件支持按住快捷键说话，可将 Remote Go 和听写软件设成同一个快捷键，并启用「按住快捷键说话」。免按模式也可另设双击快捷键。
- 遥控器本体的音频走蓝牙 ATVV。要把它送进第三方听写，电脑上需要已有音频回环设备。在 Remote Go 选回环设备的播放端，在听写软件选对应的录音端。请先在空白输入框分别测试电脑麦克风和遥控器麦克风。用电脑麦克风时，键盘 `Win + H` 可由 Windows 直接处理。

### 平台边界

Windows 版用 Raw Input 按设备识别遥控器。带原生 Windows 动作的 HID 键仍可能触发系统动作，尤其是音量和电源键；电视红外专用信号也取决于遥控器的配置。建议先验证方向、确定和信源，再测试这些键。Windows 要求目标窗口与 Remote Go 处于相同或更低的权限级别才能收取合成按键。[Microsoft Raw Input](https://learn.microsoft.com/en-us/windows/win32/inputdev/about-raw-input) · [Microsoft SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)

同款 Chromecast G9N9N 的 Windows 11 实机记录显示，一些普通键可能收不到 Raw Input 报告。如果遥控器已配对，语音键有反应，但「最近按键」在按方向键或确定键时不更新，这台设备可能遇到了这个限制。[Windows 11 实机记录](https://github.com/zfdang/remote-buddy-windows/blob/main/docs/windows-remote-input.md)

## 构建和自检

在 Windows 安装 .NET 10 SDK，从仓库根目录运行。下面生成可整体复制的自包含目录，x64 构建运行时无需另装 .NET。Windows on ARM 可将 `win-x64` 改成 `win-arm64`。

```powershell
dotnet run --project Windows/Tests/RemoteGo.Tests.csproj -c Release
dotnet publish Windows/RemoteGo/RemoteGo.csproj -c Release -r win-x64 --self-contained true -o dist/Remote-Go-win-x64
```

自检覆盖 HID 报告、按钮默认映射、macOS 预设导入、快捷键转换及 ATVV 音频解码。Windows 的蓝牙配对、全局按键、应用聚焦和收音另用实机验收。音频输出使用 [NAudio](https://github.com/naudio/NAudio)。遥控器图随包附带原始 MIT 许可。
