# Remote Go Mic

Remote Go Mic 是一个独立的 macOS 双声道音频回环驱动，使用 Remote Go 的蓝色图标。macOS 将它列为名为 **Remote Go Mic** 的音频输入和输出设备。驱动在 CoreAudio 中以 USB 传输类型报告设备。听写软件可以像选择其他麦克风一样手动选择它。

## 本机试用

适用于 Apple 芯片 Mac 和 macOS 15 或更新版本。运行 `Remote-Go-Mic-0.1.0.pkg`，按照 macOS 安装器提示授权。安装会新增 `/Library/Audio/Plug-Ins/HAL/RemoteGoMic.driver`。如果「音频 MIDI 设置」里还没有出现新设备，重启 Mac 后再检查。

在 Remote Go 的语音键页面和听写工具的麦克风设置里都选择 **Remote Go Mic**，并将语音快捷键设成一致。这个驱动可以与 BlackHole 并存，Mac 默认输入和输出可继续使用原设备。试用版使用本机临时签名，尚未经过 Apple 公证。

## 源码与许可

构建时运行 `./build.sh`。驱动基于 [BlackHole v0.7.1 源码](https://github.com/ExistentialAudio/BlackHole/tree/v0.7.1)，保留其 [GPL-3.0 许可及版权声明](LICENSE.txt)。`RemoteGoMicConfig.h` 配置了独立的设备身份、图标和传输类型。
