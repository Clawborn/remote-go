# Remote Go Agent 安装指南

把这页发给能操作 Mac 的 Agent，并说明要不要用遥控器听写。首次安装默认只装 Remote Go；需要遥控器麦克风时再装 Remote Go Mic。

> 请按 https://github.com/Clawborn/remote-go/blob/main/docs/install-for-agents.md 帮我安装 Remote Go。先装改键功能。需要我配对遥控器或在系统设置授权时，告诉我具体要做哪一步。

## 1. 检查这台 Mac

- 安装目标需要 Apple 芯片和 macOS 15 或更新版本。可用 `sysctl -n hw.optional.arm64` 检查，返回 `1` 表示支持 ARM64。用 `sw_vers -productVersion` 查看系统版本。如果 Agent 在远程沙盒里，只能下载或准备文件，需要对这台 Mac 有操作权限才能完成安装。
- 先检查 `/Applications/Remote Go.app`、`~/Applications/Remote Go.app` 和当前运行实例的位置。已有安装时，用 `Contents/Info.plist` 的 `CFBundleShortVersionString` 与 `CFBundleVersion` 读取版本和构建号，再决定是否需要升级。若 `RemoteGoDevelopmentBuild` 为 `true`，保留现有开发版，除非用户明确要换成正式版。

## 2. 从正式发布下载并校验

打开 [最新正式发布](https://github.com/Clawborn/remote-go/releases/latest)，取同一版本的 `Remote-Go-<版本>-macOS-arm64.zip` 和 `SHA256SUMS.txt`。下载列表中的 **Source code** 是源码归档。命令行 Agent 可以直接查询 [GitHub Releases API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)，公共发布无需登录。

```sh
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/remote-go-install.XXXXXX")
curl --fail --silent --show-error --location --retry 2 \
  https://api.github.com/repos/Clawborn/remote-go/releases/latest \
  -o "$work_dir/release.json"
/usr/bin/plutil -extract assets json -o - "$work_dir/release.json"
```

从输出取 ZIP 的 `name` 和 `browser_download_url`，以及 `SHA256SUMS.txt` 的 `browser_download_url`。在同一个 shell 中把它们设为 `zip_name`、`zip_url` 和 `sums_url`，然后运行下面的命令。校验通过后再解包。

```sh
(
  set -eu
  cd "$work_dir"
  curl -fsSL --retry 2 "$zip_url" -o "$zip_name"
  curl -fsSL --retry 2 "$sums_url" -o SHA256SUMS.txt
  awk -v file="$zip_name" '$2 == file || $2 == "*" file' SHA256SUMS.txt > selected.sha256
  test -s selected.sha256
  /usr/bin/shasum -a 256 -c selected.sha256
  /usr/bin/ditto -x -k "$zip_name" unpacked
  /usr/bin/codesign --verify --strict 'unpacked/Remote Go.app'
  /usr/bin/plutil -extract CFBundleIdentifier raw 'unpacked/Remote Go.app/Contents/Info.plist'
)
```

预期校验显示 `OK`，应用标识为 `me.tianrun.remotedesk`。解包后的 `.app` 与可选的 Remote Go Mic `.pkg` 在同一层。校验失败时，先核对两个下载是否来自同一个发布版本。

## 3. 安装、配对和授权

1. 首次安装时，将 `Remote Go.app` 复制到 `/Applications`，然后打开。可以用 `ditto "$work_dir/unpacked/Remote Go.app" '/Applications/Remote Go.app'`，前提是目标位置还没有同名应用。更新已有版本时，先正常退出旧版并保留一份备份，再用完整的新 `.app` 替换到原位置。保留用户配置和预设。
2. 在 Mac 的「系统设置 → 蓝牙」中配对。用户需要同时按住 Chromecast 遥控器的 **返回键和主页键**，直到指示灯闪烁，再在 Mac 上选择遥控器。[Google 配对说明](https://support.google.com/chromecast/answer/10109990)
3. 打开 Remote Go，选 **Agent Coding** 并开启 **Go**。请用户在「隐私与安全性 → 辅助功能」中允许 Remote Go 发送按键。按键读取失败时再检查「输入监控」。蓝牙访问提示出现时，请用户在系统弹窗确认。
4. 请用户按一下遥控器的方向键，确认 Remote Go 显示的「最近按键」发生变化，再到一个可安全测试的输入框确认方向键能移动光标。

也可以在目标 Mac 运行 `'/Applications/Remote Go.app/Contents/MacOS/RemoteDesk' --self-test` 检查应用内建测试；若应用装在其他位置，替换命令中的路径。实体按键仍通过上面的步骤验证。

正式包的签名和公证状态以发布说明为准。如果 macOS 拦截打开，向用户说明官方下载来源和系统提示，由用户决定是否按 macOS 的流程继续。也可以从仓库的[源码构建步骤](../README.md#从源码构建)开始，构建前先确认系统已有 Xcode 或 Command Line Tools。[Apple 的应用安全说明](https://support.apple.com/zh-cn/102445)

## 4. 按需配置语音听写

1. 只有用户需要遥控器收音时，才打开 ZIP 同包内的 `Remote-Go-Mic-*.pkg`。管理员授权由用户在 macOS 安装器中完成。已有可用的 Remote Go Mic，直接选用现有设备。
2. 在「音频 MIDI 设置」确认出现 **Remote Go Mic**。如果安装器已完成但设备没出现，请用户在方便时重启 Mac 后再检查。
3. 在 Remote Go 的语音键设置和用户的听写软件里都选 **Remote Go Mic**，并匹配听写快捷键。豆包可以用 **Fn** 长按，免按模式可配置 **Fn＋左 Control**，并在 Remote Go 把同一组合录为双击语音键。按使用功能响应蓝牙或麦克风授权提示。
4. 在空白输入框中分别用 Mac 键盘和遥控器试说一句，确认文字出现。系统和其他应用的默认麦克风按用户当前选择使用。

## 5. 汇报结果

告诉用户已核实的应用版本、安装路径、遥控器按键测试结果，以及是否配置并验证了听写。若只能完成下载、校验或安装，把剩余的系统授权、实体按键或语音测试具体列出来。

[完整使用指南](guide.zh-CN.md) · [Remote Go Mic 驱动说明](../Driver/RemoteGoMic/README.md) · [更新记录](../CHANGELOG.md)
