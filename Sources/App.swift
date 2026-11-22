import AppKit
import AVFoundation
import SwiftUI
import IOKit.hid
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

private let appDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Remote Go"

final class Desk: ObservableObject {
    @Published private(set) var library: PresetLibrary {
        didSet { library.save(to: defaults) }
    }

    var rules: [BindingRule] { library.active.rules }
    @Published private(set) var editingAppID = ""
    @Published var selection: ButtonID?
    @Published var lastButton: ButtonID?
    @Published var pressedButtons: Set<ButtonID> = []
    @Published var hoveredButton: ButtonID?
    @Published var learning = false
    @Published var recordingShortcut = false
    @Published private(set) var recordingDoubleTapShortcut = false
    @Published private(set) var active = false
    @Published private(set) var mappingRequested: Bool
    @Published private(set) var pointerModeActive = false
    @Published var outputAllowed = false
    @Published var capturing = false
    @Published private(set) var connected = 0
    @Published var voiceStatus: InterfaceMessage = "语音已关闭"
    @Published private(set) var voiceAudioStatus: InterfaceMessage?
    @Published private(set) var dictationProfile = DictationProfile.defaults
    @Published private(set) var loopbackDevices = MicrophoneDevices.loopbacks()
    @Published private(set) var dictationDeviceAvailable = MicrophoneDevices.loopback != nil
    @Published private(set) var openingMicSetup = false
    @Published private(set) var checkingForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates: Bool
    @Published private(set) var availableUpdate: GitHubRelease?
    @Published var status: InterfaceMessage = "按一下遥控器，查看 Mac 收到的按键"
    @Published var pendingPresetFile: PresetFile?
    @Published var interfaceLanguage: InterfaceLanguage = .simplifiedChinese {
        didSet {
            InterfaceLanguage.current = interfaceLanguage
            defaults.set(interfaceLanguage.rawValue, forKey: "interfaceLanguage")
            if pointerModeActive { pointerMode.begin() }
            onLanguageChange?()
        }
    }
    var onLanguageChange: (() -> Void)?
    var onUpdateCheckStateChange: (() -> Void)?
    private static let isPreview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
    private let defaults: UserDefaults
    private var updateTimer: Timer?
    private var showingUpdateAlert = false

    init(defaults: UserDefaults? = nil) {
        let store = defaults ?? (Self.isPreview ? UserDefaults(suiteName: "me.tianrun.remotedesk.preview")! : .standard)
        self.defaults = store
        automaticallyChecksForUpdates = store.bool(forKey: "automaticallyChecksForUpdates")
        mappingRequested = store.bool(forKey: "mappingRequested")
        pausedForRemoteIdle = store.bool(forKey: "pausedForRemoteIdle")
        lastRemoteActivity = store.object(forKey: "lastRemoteActivity") as? Date
        reservesPowerButton = store.object(forKey: "mappingRequested") != nil
        library = PresetLibrary.load(from: store)
        library.save(to: store)
        if let data = store.data(forKey: "availableGitHubRelease"),
           let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
           release.isNewer(than: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
            availableUpdate = release
        }
    }
    private let hid = RemoteHID()
    private let voice = RemoteVoice()
    private let microphoneBridge = MicrophoneBridge()
    private var shortcutMonitor: Any?
    private var initialized = false
    private var reservesPowerButton = false
    private static let remoteIdleInterval: TimeInterval = 30 * 60
    private var pausedForRemoteIdle = false
    private var lastRemoteActivity: Date?
    private var remoteIdleTimer: Timer?
    private var fnButtons: Set<ButtonID> = []
    private var heldOutputs: [ButtonID: HeldOutput] = [:]
    private struct HeldOutput {
        let timer: Timer?
        let onRelease: (() -> Void)?
    }
    private var homePress = TapHoldPress()
    private var homeTimer: Timer?
    private var homeOriginPID: pid_t?
    private var sourcePress = TapHoldPress(delay: 1)
    private var sourceTimer: Timer?
    private var usagePress = TapHoldPress(delay: 1)
    private var usageTimer: Timer?
    private var usageOriginPID: pid_t?
    private var usageLoading = false
    private let pointerMode = PointerMode()
    private var presetBanner: NSPanel?
    private let appSwitcher = AppSwitcher()
    private var activationObserver: NSObjectProtocol?
    private var sessionObserver: Timer?
    private static let center = ButtonID(page: 12, usage: 0x41)
    private static let sessionKeys: [ButtonID: UInt16] = [
        ButtonID(page: 12, usage: 0x42): UInt16(kVK_UpArrow),
        ButtonID(page: 12, usage: 0x43): UInt16(kVK_DownArrow),
        center: UInt16(kVK_Return),
    ]
    private enum VoiceMode { case off, keys, audio }
    private var voiceMode = VoiceMode.off
    private var voicePressStarted: TimeInterval?
    private var previousVoiceTap: TimeInterval?
    private var voiceAudioTimeout: Timer?
    private static let remoteVoiceSessionLimit: TimeInterval = 30 * 60
    private var voiceAudioLatched = false
    private var remoteVoiceAudioActive: Bool {
        voicePressStarted != nil || voiceAudioLatched || voiceAudioTimeout != nil
    }
    private var voiceAudioKeyMonitors: [Any] = []
    private let dictationAudio = DictationAudioMonitor()
    private var dictationReading = false
    private var remoteShortcutHeld: DictationShortcut?
    private var toggleShortcut: DictationShortcut?
    private var togglePressStarted: TimeInterval?
    private var remoteVoiceDownAt: TimeInterval?
    private var remoteVoiceReleasedAt: TimeInterval?
    private var remoteVoiceHoldTimer: Timer?

    func start() {
        guard !initialized else { return }
        initialized = true
        interfaceLanguage = defaults.string(forKey: "interfaceLanguage")
            .flatMap(InterfaceLanguage.init(rawValue:)) ?? .simplifiedChinese
        if let data = defaults.data(forKey: "dictationProfile"),
           let saved = try? JSONDecoder().decode(DictationProfile.self, from: data) {
            dictationProfile = saved
        }
        dictationDeviceAvailable = MicrophoneDevices.device(uid: dictationProfile.deviceUID) != nil
        selection = .assistant
        hid.onButton = { [weak self] button, down in self?.received(button, down: down) }
        hid.onReset = { [weak self] in self?.releaseFn() }
        hid.onStatus = { [weak self] count, seized, error in
            guard let self else { return }
            let connectionChanged = (self.connected > 0) != (count > 0)
            self.connected = count
            self.capturing = seized
            if connectionChanged {
                self.pauseRemoteIfIdle()
                self.applyMappingState()
            }
            if error != 0 {
                let code = String(format: "%08X", UInt32(bitPattern: error))
                self.status = "无法打开遥控器按键通道（\(code)）"
            }
        }
        voice.status = { [weak self] in self?.voiceStatus = $0 }
        voice.button = { [weak self] down in self?.received(.assistant, down: down) }
        voice.beginAudioCapture = { [weak self] in
            guard let self else { return false }
            return self.microphoneBridge.isRunning && (self.voicePressStarted != nil || self.voiceAudioLatched)
        }
        voice.isVoiceButtonCapturing = { [weak self] in self?.voicePressStarted != nil }
        voice.audioInterrupted = { [weak self] in self?.handleRemoteVoiceInterruption() }
        voice.audio = { [weak self] samples in
            guard let self, self.remoteVoiceAudioActive else { return }
            self.microphoneBridge.receive(samples)
        }
        microphoneBridge.status = { [weak self] in self?.voiceAudioStatus = $0 }
        if Self.isPreview { return }
        startDictationMonitor()
        scheduleAutomaticUpdates()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cancelUsagePress()
            self?.releaseHeldOutputs()
            self?.appSwitcher.dismiss()
            self?.refreshLoopbackDevices()
        }
        hid.start()
        if ProcessInfo.processInfo.arguments.contains("--enable-mapping") { setActive(true) }
        else {
            if mappingRequested {
                if lastRemoteActivity == nil { noteRemoteActivity() }
                else {
                    pauseRemoteIfIdle()
                    scheduleRemoteIdleCheck()
                }
            }
            applyMappingState()
        }
    }

    func stop() {
        updateTimer?.invalidate()
        updateTimer = nil
        dictationAudio.stop()
        releaseDictationShortcut(closeToggle: true)
        dictationReading = false
        stopVoiceAudio()
        sessionObserver?.invalidate()
        resetPointerMode(showConfirmation: false)
        releaseHeldOutputs()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        appSwitcher.dismiss()
        cancelHomePress()
        finishShortcut()
        voice.disable()
        hid.onStatus = nil
        hid.stop()
        remoteIdleTimer?.invalidate()
        remoteIdleTimer = nil
    }

    func setActive(_ value: Bool, pointerExitMessage: InterfaceMessage = "飞鼠已退出",
                   afterRemoteIdle: Bool = false) {
        mappingRequested = value
        defaults.set(value, forKey: "mappingRequested")
        pausedForRemoteIdle = afterRemoteIdle
        defaults.set(afterRemoteIdle, forKey: "pausedForRemoteIdle")
        if value {
            noteRemoteActivity()
        } else {
            remoteIdleTimer?.invalidate()
            remoteIdleTimer = nil
            lastRemoteActivity = nil
            defaults.removeObject(forKey: "lastRemoteActivity")
        }
        reservesPowerButton = reservesPowerButton || value
        applyMappingState(pointerExitMessage: pointerExitMessage)
    }

    private func noteRemoteActivity(at now: Date = Date()) {
        guard mappingRequested, !Self.isPreview else { return }
        lastRemoteActivity = now
        defaults.set(now, forKey: "lastRemoteActivity")
        scheduleRemoteIdleCheck()
    }

    private func scheduleRemoteIdleCheck() {
        remoteIdleTimer?.invalidate()
        remoteIdleTimer = nil
        guard mappingRequested, let lastRemoteActivity else { return }
        let timer = Timer(fire: lastRemoteActivity.addingTimeInterval(Self.remoteIdleInterval),
                          interval: 0, repeats: false) { [weak self] _ in
            self?.pauseRemoteIfIdle()
        }
        remoteIdleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func pauseRemoteIfIdle(at now: Date = Date()) {
        guard mappingRequested, let lastRemoteActivity,
              now.timeIntervalSince(lastRemoteActivity) >= Self.remoteIdleInterval else { return }
        if voicePressStarted != nil || voiceAudioLatched {
            noteRemoteActivity(at: now)
        } else {
            setActive(false, afterRemoteIdle: true)
        }
    }

    private func applyMappingState(pointerExitMessage: InterfaceMessage = "飞鼠已退出") {
        let value = mappingRequested && connected > 0
        resetPointerMode(exitMessage: pointerExitMessage)
        releaseHeldOutputs()
        appSwitcher.dismiss()
        cancelHomePress()
        if active && !value { releaseMappedFnKeys() }
        if active != value { pressedButtons.remove(.power) }
        active = value
        sessionObserver?.invalidate()
        sessionObserver = nil
        if value && !Self.isPreview {
            let timer = Timer(timeInterval: 1.2, repeats: true) { _ in Output.observeCodexSession() }
            timer.tolerance = 0.25
            sessionObserver = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        outputAllowed = Output.canPost
        hid.setExclusive(reservesPowerButton)
        refreshVoiceMode()
        if connected == 0 {
            status = mappingRequested ? "待机 · 等待遥控器连接" : "遥控器未连接 · 可先配置按键"
        } else if value && !capturing {
            status = "未取得遥控器独占控制；已保留原按键行为"
        } else if value && !Output.canPost {
            status = "发送快捷键需要辅助功能权限"
        } else if pausedForRemoteIdle {
            status = "Remote Go 已暂停 · 遥控器休眠，按电源键恢复"
        } else {
            status = value ? "Remote Go 已启动" : "Remote Go 已暂停 · 按电源键恢复"
        }
    }

    func learn() {
        resetPointerMode()
        releaseHeldOutputs()
        appSwitcher.dismiss()
        cancelHomePress()
        finishShortcut()
        learning.toggle()
        if learning { releaseMappedFnKeys() }
        refreshVoiceMode()
        status = learning ? "现在按一下要配置的遥控器按键" : "已退出按键学习"
    }

    func addLast() {
        if let lastButton { selectOrAdd(lastButton) }
    }

    private func received(_ button: ButtonID, down: Bool) {
        if !down {
            let wasPressed = pressedButtons.remove(button) != nil
            if wasPressed { noteRemoteActivity() }
            pointerMode.release(button)
            releaseHeldOutput(button)
            if fnButtons.remove(button) != nil, fnButtons.isEmpty { _ = Output.postFn(down: false) }
            if button == .assistant { finishRemoteDictation() }
            if button == .home { finishHomePress(released: true) }
            if button == .source { finishSourcePress(released: true) }
            if button == .power, wasPressed, capturing, !learning, !recordingShortcut {
                toggleMappingFromPower()
            }
            if button == .volumeUp { finishUsagePress(released: true) }
            return
        }
        pauseRemoteIfIdle()
        noteRemoteActivity()
        lastButton = button
        pressedButtons.insert(button)
        if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
            NSLog("%@ received HID %@", appDisplayName, button.label)
        }
        if learning {
            learning = false
            selectOrAdd(button)
            refreshVoiceMode()
            return
        }
        guard button != .power, active, (capturing || button == .assistant),
              !recordingShortcut, !IsSecureEventInputEnabled() else { return }
        if button == .assistant {
            beginRemoteDictation()
            return
        }
        if voiceAudioLatched, dictationProfile.doubleTapShortcut == nil || toggleShortcut != dictationProfile.doubleTapShortcut {
            stopVoiceAudio()
        }
        let foreground = NSWorkspace.shared.frontmostApplication
        let appID = foreground?.bundleIdentifier
        let rule = library.active.rule(for: button, appID: appID)
        if button == .source, rule?.action == .appSwitcher {
            beginSourcePress()
            return
        }
        if appSwitcher.consume(button) { return }
        if pointerModeActive {
            if button == .back {
                resetPointerMode()
                return
            }
            if pointerMode.consume(button) { return }
        }
        if button == .volumeUp, appID == ChatTarget.codex.rawValue, rule?.action == .previousCodexSession,
           let pid = foreground?.processIdentifier {
            beginUsagePress(in: pid)
            return
        }
        if button == .home, library.homeSwitch.enabled, !library.homeSwitch.secondID.isEmpty,
           rule?.action != .fn, rule?.keyboardStroke == nil {
            homePress.begin(at: ProcessInfo.processInfo.systemUptime)
            if homeTimer == nil {
                homeOriginPID = foreground?.processIdentifier
                let timer = Timer(timeInterval: homePress.delay, repeats: false) { [weak self] _ in
                    self?.finishHomePress(released: false)
                }
                homeTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return
        }
        let hasOverride = appID.map { library.active.override(for: button, appID: $0) != nil } ?? false
        if !hasOverride, let key = Self.sessionKeys[button], Output.sessionPickerIsFocused() {
            _ = Output.press(key, flags: 0)
            return
        }
        if let rule {
            if let stroke = rule.keyboardStroke, let pid = foreground?.processIdentifier {
                holdKeyboard(button, key: stroke.key, flags: stroke.flags, in: pid)
            } else {
                perform(rule)
            }
        }
    }

    private func beginUsagePress(in pid: pid_t) {
        guard usageTimer == nil else { return }
        usageOriginPID = pid
        usagePress.begin(at: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: usagePress.delay, repeats: false) { [weak self] _ in
            self?.finishUsagePress(released: false)
        }
        usageTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishUsagePress(released: Bool) {
        guard let pid = usageOriginPID, active, capturing, !learning, !recordingShortcut,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, !IsSecureEventInputEnabled() else {
            cancelUsagePress()
            return
        }
        guard let result = usagePress.finish(at: ProcessInfo.processInfo.systemUptime, released: released) else { return }
        cancelUsagePress()
        switch result {
        case .tap:
            if let rule = library.active.rule(for: .volumeUp, appID: ChatTarget.codex.rawValue) { perform(rule) }
        case .hold:
            showCodexUsage()
        }
    }

    private func cancelUsagePress() {
        usageTimer?.invalidate()
        usageTimer = nil
        usageOriginPID = nil
        usagePress.cancel()
    }

    func showCodexUsage() {
        guard !usageLoading else { return }
        usageLoading = true
        let originPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        showBanner([ui("正在读取 Codex 用量…")], duration: 7)
        CodexUsage.fetch { [weak self] windows in
            guard let self else { return }
            self.usageLoading = false
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == originPID,
                  !IsSecureEventInputEnabled() else { return }
            let lines = windows?.map(\.description) ?? [ui("暂时读不到用量，可在 Codex 设置中查看。")]
            self.showBanner([ui("Codex 用量")] + lines, duration: 5)
        }
    }

    private func beginSourcePress() {
        guard sourceTimer == nil else { return }
        sourcePress.begin(at: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: sourcePress.delay, repeats: false) { [weak self] _ in
            self?.finishSourcePress(released: false)
        }
        sourceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func toggleMappingFromPower() {
        let wasPointing = pointerModeActive
        setActive(!active, pointerExitMessage: "飞鼠已退出 · Remote Go 已暂停")
        if !wasPointing {
            let message = active ? (capturing ? ui("Remote Go 已启动") : ui("未能取得遥控器控制")) : ui("Remote Go 已暂停")
            showBanner([message], duration: 1.5)
        }
    }

    private func finishSourcePress(released: Bool) {
        guard active, capturing, !learning, !recordingShortcut, !IsSecureEventInputEnabled() else {
            cancelSourcePress()
            return
        }
        guard let result = sourcePress.finish(at: ProcessInfo.processInfo.systemUptime, released: released) else { return }
        cancelSourcePress()
        switch result {
        case .tap:
            if appSwitcher.consume(.source) { return }
            showAppSwitcher(trigger: .source)
        case .hold:
            togglePointerMode()
        }
    }

    private func cancelSourcePress() {
        sourceTimer?.invalidate()
        sourceTimer = nil
        sourcePress.cancel()
    }

    func togglePointerMode() {
        if pointerModeActive {
            resetPointerMode()
            return
        }
        guard active, capturing, !learning, !recordingShortcut, !IsSecureEventInputEnabled() else { return }
        refreshPermissions()
        guard outputAllowed else { return }
        cancelUsagePress()
        releaseHeldOutputs()
        cancelHomePress()
        appSwitcher.dismiss()
        Output.resetNavigation()
        pointerMode.begin()
        pointerModeActive = true
    }

    private func resetPointerMode(showConfirmation: Bool = true, exitMessage: InterfaceMessage = "飞鼠已退出") {
        cancelUsagePress()
        cancelSourcePress()
        guard pointerModeActive || !showConfirmation else { return }
        pointerMode.end(confirmation: showConfirmation ? exitMessage : nil)
        pointerModeActive = false
    }

    private func showAppSwitcher(trigger: ButtonID) {
        resetPointerMode()
        releaseHeldOutputs()
        Output.resetNavigation()
        appSwitcher.show(trigger: trigger)
    }

    private func holdKeyboard(_ button: ButtonID, key: UInt16, flags: UInt64, in pid: pid_t) {
        guard heldOutputs[button] == nil else { return }
        guard Output.postKeyboard(key, flags: flags, down: true) else {
            status = "未发送快捷键 · 请检查辅助功能权限"
            return
        }
        repeatWhileHeld(button, onRelease: { _ = Output.postKeyboard(key, flags: flags, down: false) }) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && Output.postKeyboard(key, flags: flags, down: true, isRepeat: true)
        }
    }

    private func repeatWhileHeld(_ button: ButtonID, onRelease: (() -> Void)? = nil,
                                 sendAgain: @escaping () -> Bool) {
        let delay = NSEvent.keyRepeatDelay
        let interval = NSEvent.keyRepeatInterval
        var timer: Timer?
        if delay.isFinite, interval.isFinite, delay > 0, interval > 0 {
            timer = Timer(fire: Date().addingTimeInterval(delay), interval: interval, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if !self.pressedButtons.contains(button) || !sendAgain() {
                    self.releaseHeldOutput(button)
                }
            }
        }
        heldOutputs[button] = HeldOutput(timer: timer, onRelease: onRelease)
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func releaseHeldOutput(_ button: ButtonID) {
        guard let held = heldOutputs.removeValue(forKey: button) else { return }
        held.timer?.invalidate()
        held.onRelease?()
    }

    private func releaseHeldOutputs() {
        for button in Array(heldOutputs.keys) { releaseHeldOutput(button) }
    }

    private func perform(_ rule: BindingRule) {
        let button = rule.id
        switch rule.action {
        case .activate: Output.activate()
        case .watchYouTube, .watchNetflix:
            if let url = rule.action.videoURL, !NSWorkspace.shared.open(url) {
                status = "无法用默认浏览器\(rule.action.title)"
            }
        case .videoPlayPause, .videoFullscreen:
            let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if let stroke = rule.action.videoStroke(in: appID), !Output.press(stroke.key, flags: stroke.flags) {
                status = "未发送播放快捷键 · 请检查辅助功能权限"
            }
        case .codexChat, .claudeChat: openConversation(rule.action)
        case .sessions:
            releaseHeldOutputs()
            status = Output.chooseSession()
        case .cycleCodex:
            resetPointerMode()
            releaseHeldOutputs()
            Output.cycleCodexSession(in: .next) { [weak self] message in self?.status = message }
        case .nextCodexSession, .previousCodexSession:
            resetPointerMode()
            releaseHeldOutputs()
            let direction: CodexSessionHistory.Direction = rule.action == .previousCodexSession ? .previous : .next
            Output.moveCodexSidebar(in: direction) { [weak self] message in self?.status = message }
        case .nextGrokBotSession, .previousGrokBotSession:
            resetPointerMode()
            releaseHeldOutputs()
            let direction: CodexSessionHistory.Direction = rule.action == .previousGrokBotSession ? .previous : .next
            Output.moveGrokBotSidebar(in: direction) { [weak self] message in self?.status = message }
        case .cycleAgents:
            resetPointerMode()
            releaseHeldOutputs()
            openConversation(Output.isCodex ? .claudeChat : .codexChat)
        case .appSwitcher: showAppSwitcher(trigger: button)
        case .pointerMode: togglePointerMode()
        case .volumeUp, .volumeDown, .mute:
            guard heldOutputs[button] == nil, let key = rule.action.mediaKey else { return }
            guard Output.pressMedia(key) else {
                status = "未发送媒体键 · 请检查辅助功能权限"
                return
            }
            if rule.action != .mute && pressedButtons.contains(button) {
                repeatWhileHeld(button) { Output.pressMedia(key) }
            }
        case .fn: sendFn(for: button)
        case .voice, .suppress, .unassigned: break
        default:
            if !Output.press(rule.action.keyCode ?? rule.keyCode, flags: rule.action == .shortcut ? rule.modifiers : rule.action.flags) {
                status = "未发送快捷键 · 请检查辅助功能权限"
            }
        }
    }

    private func finishHomePress(released: Bool) {
        guard active, capturing, !learning, !recordingShortcut, !IsSecureEventInputEnabled() else {
            cancelHomePress()
            return
        }
        guard let result = homePress.finish(at: ProcessInfo.processInfo.systemUptime, released: released) else { return }
        let origin = homeOriginPID
        cancelHomePress()
        switch result {
        case .tap:
            let foreground = NSWorkspace.shared.frontmostApplication
            guard foreground?.processIdentifier == origin,
                  let rule = library.active.rule(for: .home, appID: foreground?.bundleIdentifier),
                  rule.action != .fn else { return }
            perform(rule)
        case .hold:
            let nextID = library.homeSwitch.destination(from: library.activeID)
            guard nextID != library.activeID, library.presets.contains(where: { $0.id == nextID }) else { return }
            switchPreset(to: nextID)
            showPresetBanner(library.active.interfaceName)
        }
    }

    private func cancelHomePress() {
        homeTimer?.invalidate()
        homeTimer = nil
        homeOriginPID = nil
        homePress.cancel()
    }

    func updateHomeSwitch(_ change: (inout HomePresetSwitch) -> Void) {
        cancelHomePress()
        var settings = library.homeSwitch
        change(&settings)
        library.homeSwitch = settings.resolved(in: library.presets)
    }

    private func showPresetBanner(_ name: String) {
        showBanner([ui("已切换到 \(name)")], duration: 1.25)
    }

    private func showBanner(_ lines: [String], duration: TimeInterval) {
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else { return }
        presetBanner?.orderOut(nil)
        let labels = lines.enumerated().map { index, line in
            let label = NSTextField(labelWithString: line)
            label.font = index == 0 ? .systemFont(ofSize: 15, weight: .semibold) : .systemFont(ofSize: 13)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.textColor = .labelColor
            return label
        }
        let width = min(max((labels.map { $0.intrinsicContentSize.width }.max() ?? 0) + 40, 180), screen.visibleFrame.width)
        let height = CGFloat(42 + max(labels.count - 1, 0) * 21)
        let frame = NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.maxY - height - 24,
                           width: width, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        for (index, label) in labels.enumerated() {
            let lineHeight = label.intrinsicContentSize.height
            label.frame = NSRect(x: 14, y: height - 21 - CGFloat(index * 21) - lineHeight / 2,
                                 width: width - 28, height: lineHeight)
            background.addSubview(label)
        }
        panel.contentView = background
        presetBanner = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak panel] in
            guard let self, let panel, self.presetBanner === panel else { return }
            panel.orderOut(nil)
            self.presetBanner = nil
        }
    }

    func openConversation(_ action: Action) {
        guard let target = action.chatTarget else { return }
        Output.openChat(target) { [weak self] message in
            self?.status = message
        }
    }

    private func releaseFn() {
        releaseDictationShortcut(closeToggle: true)
        stopVoiceAudio()
        resetPointerMode()
        releaseHeldOutputs()
        cancelHomePress()
        appSwitcher.dismiss()
        pressedButtons.removeAll()
        releaseMappedFnKeys()
    }

    private func releaseMappedFnKeys() {
        guard !fnButtons.isEmpty else { return }
        fnButtons.removeAll()
        _ = Output.postFn(down: false)
    }

    func selectForEdit(_ button: ButtonID) {
        finishShortcut()
        if learning { learn() }
        selection = button
    }

    func ruleForEditor(_ id: ButtonID) -> BindingRule {
        let stored = editingAppID.isEmpty ? rules.first { $0.id == id }
            : library.active.rule(for: id, appID: editingAppID)
        var rule = stored ?? BindingRule(id: id, name: id.label, action: .unassigned, codexOnly: false)
        if rule.action == .voice { rule.action = .suppress }
        return rule
    }

    func selectMappingApp(_ id: String) {
        finishShortcut()
        editingAppID = id
    }

    func addMappingApp() {
        guard let window = NSApp.keyWindow else { return }
        let picker = NSOpenPanel()
        picker.title = ui("选择要单独改键的应用")
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = picker.url,
                  let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            if !self.library.apps.contains(where: { $0.id == id }) {
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                self.library.customApps = (self.library.customApps ?? []) + [MappingApp(id: id, name: name)]
            }
            self.selectMappingApp(id)
        }
    }

    func mappingTitle(_ id: ButtonID) -> String {
        if id == .power { return ui("切换启用改键") }
        if id == .assistant { return dictationProfile.shortcut.label }
        let rule = ruleForEditor(id)
        return rule.action == .shortcut ? Self.shortcutLabel(rule) : rule.action.title
    }

    private func selectOrAdd(_ button: ButtonID) {
        selectForEdit(button)
        status = "已识别 \(button.interfaceLabelMessage)，可以编辑动作"
    }

    func remove(_ id: ButtonID) {
        finishShortcut()
        update(id) { $0.action = .unassigned }
    }

    func saveCurrentPreset() {
        library.save(to: defaults)
        status = "已保存预设「\(library.active.interfaceNameMessage)」"
    }

    func exportPreset() {
        guard let window = NSApp.keyWindow else { return }
        let preset = library.active
        let file = PresetFile(preset: preset, apps: library.apps)
        let panel = NSSavePanel()
        panel.title = ui("导出当前预设")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = preset.interfaceName.replacingOccurrences(of: "/", with: "-") + ".remote-go.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try file.write(to: url)
                self.status = "已导出预设「\(preset.interfaceNameMessage)」"
            } catch {
                self.status = "无法导出预设"
            }
        }
    }

    func importPreset() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.title = ui("从文件导入预设")
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                self.pendingPresetFile = try PresetFile.read(from: url)
            } catch PresetFile.FileError.unsupportedVersion {
                self.status = "此文件的预设格式版本不受支持"
            } catch PresetFile.FileError.tooLarge {
                self.status = "预设文件超过 256 KB"
            } catch {
                self.status = "无法导入，请选择有效的 Remote Go 预设文件"
            }
        }
    }

    func confirmPresetImport(_ file: PresetFile) {
        let name = installPresetFile(file)
        status = "已导入预设「\(name)」· 请从预设列表选择"
        pendingPresetFile = nil
    }

    @discardableResult
    func installPresetFile(_ file: PresetFile) -> String {
        let base = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var index = 2
        var name = base
        while availableName(name) == nil {
            name = "\(base) (\(index))"
            index += 1
        }
        var updated = library
        updated.presets.append(MappingPreset(id: UUID().uuidString, name: name, isBuiltIn: false,
                                             rules: file.rules, appRules: file.appRules))
        let knownApps = Set(updated.apps.map(\.id))
        let importedNames = Dictionary(uniqueKeysWithValues: file.applications.map { ($0.id, $0.name) })
        for appID in file.appRules.keys.sorted() where !knownApps.contains(appID) {
            let app = MappingApp(id: appID, name: importedNames[appID] ?? appID)
            updated.customApps = (updated.customApps ?? []) + [app]
        }
        library = updated
        return name
    }

    func switchPreset(to id: String) {
        guard library.activeID != id, library.presets.contains(where: { $0.id == id }) else { return }
        finishPresetSwitch(id)
    }

    @discardableResult
    func createPreset(name: String, copyCurrent: Bool) -> Bool {
        guard let name = availableName(name) else { return false }
        let preset = MappingPreset(id: UUID().uuidString, name: name, isBuiltIn: false,
                                   rules: copyCurrent ? rules : [],
                                   appRules: copyCurrent ? library.active.appRules : nil)
        var edited = library
        edited.presets.append(preset)
        finishPresetSwitch(preset.id, replacing: edited)
        return true
    }

    @discardableResult
    func renamePreset(to name: String) -> Bool {
        guard !library.active.isBuiltIn, let name = availableName(name, excluding: library.activeID) else { return false }
        library.editActive { $0.name = name }
        return true
    }

    func deleteActivePreset() {
        guard !library.active.isBuiltIn, let next = library.presets.first(where: { $0.id == PresetLibrary.codingID }) else { return }
        var edited = library
        edited.presets.removeAll { $0.id == library.activeID }
        finishPresetSwitch(next.id, replacing: edited)
    }

    private func availableName(_ draft: String, excluding id: String? = nil) -> String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !library.presets.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        return name
    }

    private func finishPresetSwitch(_ id: String, replacing replacement: PresetLibrary? = nil) {
        finishShortcut()
        if learning { learn() }
        releaseFn()
        Output.resetNavigation()
        var edited = replacement ?? library
        edited.activeID = id
        library = edited
        status = "已切换到 \(library.active.interfaceNameMessage)"
    }

    func promptPresetName(copyCurrent: Bool = true, renaming: Bool = false) {
        guard let window = NSApp.keyWindow else { return }
        let originalName = library.active.name
        let alert = NSAlert()
        alert.messageText = renaming ? ui("重命名预设") : (copyCurrent ? ui("复制预设") : ui("新建空白预设"))
        alert.informativeText = copyCurrent && !renaming ? ui("复制当前的整套按键配置。") : ui("输入这套按键配置的名称。")
        alert.addButton(withTitle: ui("保存"))
        alert.addButton(withTitle: ui("取消"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = renaming ? originalName : (copyCurrent ? ui("\(originalName) 副本") : "")
        input.placeholderString = ui("预设名称")
        input.setAccessibilityLabel(ui("预设名称"))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let ok = renaming ? self.renamePreset(to: input.stringValue)
                : self.createPreset(name: input.stringValue, copyCurrent: copyCurrent)
            if !ok {
                let error = NSAlert()
                error.messageText = ui("这个名称无法保存")
                error.informativeText = ui("请输入非空、且与现有预设不重复的名称。")
                error.beginSheetModal(for: window)
            }
        }
    }

    func confirmDeletePreset() {
        guard !library.active.isBuiltIn, let window = NSApp.keyWindow else { return }
        let id = library.activeID
        let alert = NSAlert()
        alert.messageText = ui("删除「\(library.active.name)」？")
        alert.informativeText = ui("这套预设的按键配置将被删除。")
        alert.addButton(withTitle: ui("取消"))
        alert.addButton(withTitle: ui("删除")).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn, self.library.activeID == id else { return }
            self.deleteActivePreset()
        }
    }

    func update(_ id: ButtonID, _ change: (inout BindingRule) -> Void) {
        if id == .volumeUp { cancelUsagePress() }
        if id == .source { cancelSourcePress() }
        releaseHeldOutput(id)
        var edit = ruleForEditor(id)
        change(&edit)
        if fnButtons.contains(id) { releaseFn() }
        if editingAppID.isEmpty {
            library.editActive { $0.set(edit) }
        } else {
            edit.codexOnly = false
            library.editActive { $0.set(edit, for: editingAppID) }
        }
        if status.key.hasPrefix("已保存预设") { status = "按键已更新" }
    }

    func recordShortcut(_ id: ButtonID) {
        resetPointerMode()
        releaseHeldOutputs()
        finishShortcut()
        recordingShortcut = true
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let supported = NSEvent.ModifierFlags([.command, .option, .control, .shift])
            self.update(id) {
                $0.keyCode = event.keyCode
                $0.modifiers = UInt64(event.modifierFlags.intersection(supported).rawValue)
            }
            self.finishShortcut()
            return nil
        }
    }

    func finishShortcut() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        recordingShortcut = false
        recordingDoubleTapShortcut = false
    }

    func grantInput() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        openSettings("Privacy_ListenEvent")
    }

    func refreshPermissions() { outputAllowed = Output.canPost }

    func grantOutput() {
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        } else if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        openSettings("Privacy_Accessibility")
    }

    private func openSettings(_ page: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + page) {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor func showMicrophoneSetup() {
        guard !openingMicSetup else { return }
        openingMicSetup = true
        Task {
            defer { openingMicSetup = false }
            if let package = await RemoteGoMicSetup.package() {
                NSWorkspace.shared.activateFileViewerSelecting([package])
            } else {
                NSWorkspace.shared.open(RemoteGoMicSetup.downloads)
            }
        }
    }

    @MainActor func checkForUpdates() {
        performUpdateCheck(automatic: false)
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        automaticallyChecksForUpdates = enabled
        defaults.set(enabled, forKey: "automaticallyChecksForUpdates")
        scheduleAutomaticUpdates(initialDelay: 0)
        onUpdateCheckStateChange?()
    }

    private func scheduleAutomaticUpdates(initialDelay: TimeInterval = 15) {
        updateTimer?.invalidate()
        updateTimer = nil
        guard automaticallyChecksForUpdates, !Self.isPreview else { return }
        let now = Date()
        let lastCheck = defaults.object(forKey: "lastSuccessfulUpdateCheck") as? Date
        let date = UpdateCheckSchedule.isDue(lastCheck: lastCheck, now: now)
            ? now.addingTimeInterval(initialDelay)
            : lastCheck!.addingTimeInterval(UpdateCheckSchedule.interval)
        let timer = Timer(fire: date, interval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      UpdateCheckSchedule.isDue(lastCheck: self.defaults.object(forKey: "lastSuccessfulUpdateCheck") as? Date)
                else { return }
                self.performUpdateCheck(automatic: true)
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    @MainActor private func performUpdateCheck(automatic: Bool) {
        guard !checkingForUpdates, !showingUpdateAlert else { return }
        checkingForUpdates = true
        onUpdateCheckStateChange?()
        Task {
            defer {
                checkingForUpdates = false
                onUpdateCheckStateChange?()
            }
            do {
                let release = try await GitHubUpdates.check()
                defaults.set(Date(), forKey: "lastSuccessfulUpdateCheck")
                let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                availableUpdate = release.isNewer(than: local) ? release : nil
                if let availableUpdate {
                    defaults.set(try? JSONEncoder().encode(availableUpdate), forKey: "availableGitHubRelease")
                } else {
                    defaults.removeObject(forKey: "availableGitHubRelease")
                }
                scheduleAutomaticUpdates()
                if !automatic { presentUpdate(release) }
            } catch {
                if !automatic { presentUpdateError(error) }
            }
        }
    }

    @MainActor func showAvailableUpdate() {
        guard !showingUpdateAlert, let release = availableUpdate else { return }
        presentUpdate(release)
    }

    func dismissUpdateNotice() {
        availableUpdate = nil
        defaults.removeObject(forKey: "availableGitHubRelease")
        onUpdateCheckStateChange?()
    }

    @MainActor private func presentUpdate(_ release: GitHubRelease) {
        guard let remote = try? release.validated() else { return }
        let localText = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let development = Bundle.main.object(forInfoDictionaryKey: "RemoteGoDevelopmentBuild") as? Bool == true
        let alert = NSAlert()
        alert.alertStyle = .informational
        if let local = ReleaseVersion(localText) {
            if remote.version > local {
                alert.messageText = ui("发现新版本 \(remote.version.display)")
            } else if development {
                alert.messageText = ui("这是本机开发版")
            } else if remote.version == local {
                alert.messageText = ui("已是最新正式版")
            } else {
                alert.messageText = ui("当前版本高于 GitHub 正式版")
            }
        } else {
            alert.messageText = ui("GitHub 最新正式版")
        }
        alert.informativeText = ui("当前版本：\(localText)\nGitHub 正式版：\(remote.version.display)")
        if development {
            alert.informativeText += "\n\n" + ui("本机开发版可能包含尚未发布的改动。下载正式版会替换这些改动。")
        }
        alert.informativeText += "\n\n" + ui("下载后退出 Remote Go，将新版应用替换到原位置。预设保存在本机，会继续保留。")
        let notes = String((release.body ?? "").prefix(8_000))
        if notes.isEmpty {
            alert.informativeText += "\n\n" + ui("完整更新说明见 GitHub 发布页。")
        }
        if !notes.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 170))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.textContainerInset = NSSize(width: 10, height: 10)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.string = notes
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: ui("打开 GitHub 下载页…"))
        alert.addButton(withTitle: ui("关闭"))
        showUpdateAlert(alert, page: remote.page)
    }

    @MainActor private func presentUpdateError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = ui("暂时无法检查更新")
        switch error {
        case UpdateCheckError.noRelease:
            alert.informativeText = ui("GitHub 暂无正式发布版本。")
        case UpdateCheckError.rateLimited:
            alert.informativeText = ui("GitHub 暂时限制了请求，请稍后再试。")
        case UpdateCheckError.invalidRelease:
            alert.informativeText = ui("无法识别 GitHub 发布信息，请到发布页确认。")
        default:
            alert.informativeText = ui("请检查网络连接后重试，也可以直接打开发布页。")
        }
        alert.addButton(withTitle: ui("打开 GitHub 发布页…"))
        alert.addButton(withTitle: ui("关闭"))
        showUpdateAlert(alert, page: GitHubUpdates.releasesPage)
    }

    @MainActor private func showUpdateAlert(_ alert: NSAlert, page: URL) {
        showingUpdateAlert = true
        NSApp.activate()
        if let window = NSApp.mainWindow, window.isVisible {
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.showingUpdateAlert = false
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
            }
        } else {
            let response = alert.runModal()
            showingUpdateAlert = false
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
        }
    }

    func updateDictationProfile(_ update: (inout DictationProfile) -> Void) {
        var profile = dictationProfile
        update(&profile)
        guard profile != dictationProfile else { return }
        releaseDictationShortcut(closeToggle: true)
        dictationReading = false
        stopVoiceAudio()
        voiceAudioStatus = nil
        dictationProfile = profile
        defaults.set(try? JSONEncoder().encode(profile), forKey: "dictationProfile")
        if !Self.isPreview { startDictationMonitor() }
    }

    func refreshLoopbackDevices() {
        let devices = MicrophoneDevices.loopbacks()
        if loopbackDevices != devices { loopbackDevices = devices }
    }

    private func startDictationMonitor() {
        dictationAudio.start(deviceUID: dictationProfile.deviceUID, onAvailabilityChange: { [weak self] available in
            guard let self else { return }
            self.dictationDeviceAvailable = available
            self.refreshLoopbackDevices()
            self.refreshVoiceMode()
        }, onChange: { [weak self] reading in
            self?.updateDictationAudio(reading)
        })
    }

    func recordDictationShortcut(doubleTap: Bool = false) {
        if recordingShortcut, recordingDoubleTapShortcut == doubleTap {
            finishShortcut()
            return
        }
        resetPointerMode()
        releaseHeldOutputs()
        finishShortcut()
        recordingShortcut = true
        recordingDoubleTapShortcut = doubleTap
        var pressedModifiers: Set<UInt16> = []
        var pendingModifier: DictationShortcut?
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(DictationShortcut.supported)
            let shortcut: DictationShortcut
            if event.type == .flagsChanged {
                guard let candidate = DictationShortcut.fromModifier(event.keyCode, flags: event.modifierFlags) else { return event }
                if pressedModifiers.remove(event.keyCode) == nil {
                    guard !flags.isEmpty else { return nil }
                    pressedModifiers.insert(event.keyCode)
                    pendingModifier = candidate
                    return nil
                }
                guard pressedModifiers.isEmpty, let pendingModifier else { return nil }
                shortcut = pendingModifier
            } else {
                shortcut = DictationShortcut(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue))
            }
            self.finishShortcut()
            self.updateDictationProfile {
                if doubleTap { $0.doubleTapShortcut = shortcut }
                else { $0.shortcut = shortcut }
            }
            return nil
        }
    }

    private func beginRemoteDictation() {
        if dictationProfile.mode == .hold, dictationProfile.doubleTapShortcut != nil {
            beginRemoteVoiceGesture()
            return
        }
        let shortcut = dictationProfile.shortcut
        var sent = false
        switch dictationProfile.mode {
        case .hold:
            guard remoteShortcutHeld == nil else { return }
            sent = shortcut.post(down: true)
            if sent { remoteShortcutHeld = shortcut }
        case .toggle:
            if toggleShortcut != nil {
                releaseDictationShortcut(closeToggle: true)
                stopVoiceAudio()
                return
            }
            sent = shortcut.tap()
            if sent {
                toggleShortcut = shortcut
                togglePressStarted = ProcessInfo.processInfo.systemUptime
            }
        }
        guard sent else {
            status = "未发送语音快捷键 · 请检查辅助功能权限"
            return
        }
        if voiceMode == .audio { startVoiceAudioPress() }
    }

    private func finishRemoteDictation() {
        if let started = remoteVoiceDownAt, let shortcut = dictationProfile.doubleTapShortcut {
            finishRemoteVoiceGesture(started: started, shortcut: shortcut)
            return
        }
        if let shortcut = remoteShortcutHeld {
            _ = shortcut.post(down: false)
            remoteShortcutHeld = nil
            finishVoiceAudioPress()
            return
        }
        guard let started = togglePressStarted, toggleShortcut != nil else { return }
        togglePressStarted = nil
        let wasCapturing = remoteVoiceAudioActive
        voicePressStarted = nil
        if ProcessInfo.processInfo.systemUptime - started >= 0.28 {
            releaseDictationShortcut(closeToggle: true)
            if wasCapturing { scheduleVoiceAudioStop(after: 0.15) }
        } else if wasCapturing {
            startSustainedVoiceAudio()
        }
    }

    private func beginRemoteVoiceGesture() {
        if toggleShortcut != nil {
            releaseDictationShortcut(closeToggle: true)
            stopVoiceAudio()
            return
        }
        guard remoteVoiceDownAt == nil else { return }
        remoteVoiceDownAt = ProcessInfo.processInfo.systemUptime
        if voiceMode == .audio { startVoiceAudioPress() }
        let timer = Timer(timeInterval: 0.28, repeats: false) { [weak self] _ in
            guard let self, self.remoteVoiceDownAt != nil else { return }
            let shortcut = self.dictationProfile.shortcut
            if shortcut.post(down: true) {
                self.remoteShortcutHeld = shortcut
            } else {
                self.status = "未发送语音快捷键 · 请检查辅助功能权限"
            }
        }
        remoteVoiceHoldTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishRemoteVoiceGesture(started: TimeInterval, shortcut: DictationShortcut) {
        remoteVoiceHoldTimer?.invalidate()
        remoteVoiceHoldTimer = nil
        remoteVoiceDownAt = nil
        let now = ProcessInfo.processInfo.systemUptime
        let wasTap = remoteShortcutHeld == nil && now - started < 0.28
        let doubleTap = wasTap && remoteVoiceReleasedAt.map { started - $0 < 0.42 } == true
        remoteVoiceReleasedAt = wasTap && !doubleTap ? now : nil
        let wasCapturing = remoteVoiceAudioActive
        voicePressStarted = nil
        if let held = remoteShortcutHeld {
            _ = held.post(down: false)
            remoteShortcutHeld = nil
            if wasCapturing { scheduleVoiceAudioStop(after: 0.15) }
        } else if doubleTap && shortcut.tap() {
            toggleShortcut = shortcut
            if wasCapturing { startSustainedVoiceAudio() }
        } else {
            stopVoiceAudio()
        }
    }

    private func releaseDictationShortcut(closeToggle: Bool) {
        remoteVoiceHoldTimer?.invalidate()
        remoteVoiceHoldTimer = nil
        remoteVoiceDownAt = nil
        remoteVoiceReleasedAt = nil
        if let shortcut = remoteShortcutHeld { _ = shortcut.post(down: false) }
        if closeToggle, let shortcut = toggleShortcut { _ = shortcut.tap() }
        remoteShortcutHeld = nil
        toggleShortcut = nil
        togglePressStarted = nil
    }

    private func handleRemoteVoiceInterruption() {
        guard remoteVoiceAudioActive || remoteVoiceDownAt != nil
                || remoteShortcutHeld != nil || toggleShortcut != nil else { return }
        releaseDictationShortcut(closeToggle: true)
        stopVoiceAudio()
    }

    private func refreshVoiceMode() {
        let mode: VoiceMode
        if Self.isPreview || connected == 0 || !(active || learning) { mode = .off }
        else if learning || !dictationDeviceAvailable { mode = .keys }
        else { mode = .audio }
        guard mode != voiceMode else { return }
        if voiceMode != .off {
            stopVoiceAudio()
            voice.disable()
            releaseDictationShortcut(closeToggle: true)
        }
        voiceMode = mode
        if !dictationReading {
            voiceAudioStatus = nil
        }
        if mode != .off { voice.enable(keysOnly: mode == .keys) }
    }

    private func updateDictationAudio(_ reading: Bool) {
        dictationReading = reading
        NSLog("Remote Go dictation audio %@", reading ? "started" : "stopped")
        if !reading {
            guard remoteShortcutHeld == nil, togglePressStarted == nil, remoteVoiceDownAt == nil else { return }
            releaseDictationShortcut(closeToggle: false)
            stopVoiceAudio()
            return
        }
        guard remoteShortcutHeld == nil, toggleShortcut == nil, !remoteVoiceAudioActive else { return }
        guard makeVoiceAudioOutputReady() else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startDictationComputerAudio()
        case .notDetermined:
            voiceAudioStatus = "等待麦克风权限"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.dictationReading, !self.remoteVoiceAudioActive,
                          self.remoteShortcutHeld == nil, self.toggleShortcut == nil else { return }
                    if allowed { self.startDictationComputerAudio() }
                    else { self.voiceAudioStatus = "请在隐私与安全性中允许使用麦克风" }
                }
            }
        default:
            voiceAudioStatus = "请在隐私与安全性中允许使用麦克风"
        }
    }

    private func startDictationComputerAudio() {
        do { try microphoneBridge.startComputerAudio() }
        catch {
            voiceAudioStatus = "无法启动电脑麦克风"
            NSLog("Remote Go Mac microphone failed: %@", error.localizedDescription)
        }
    }

    private func makeVoiceAudioOutputReady() -> Bool {
        if microphoneBridge.isRunning { return true }
        do {
            try microphoneBridge.start(deviceUID: dictationProfile.deviceUID)
            return true
        } catch {
            voiceAudioStatus = "无法连接所选虚拟麦克风"
            return false
        }
    }

    private func startVoiceAudioPress() {
        guard voicePressStarted == nil else { return }
        if voiceAudioLatched { stopVoiceAudio(); return }
        if microphoneBridge.isCapturingComputer { microphoneBridge.stop() }
        guard makeVoiceAudioOutputReady() else { return }
        voicePressStarted = ProcessInfo.processInfo.systemUptime
        scheduleVoiceAudioStop(after: Self.remoteVoiceSessionLimit, atSessionLimit: true)
    }

    private func finishVoiceAudioPress() {
        guard let started = voicePressStarted else { return }
        voicePressStarted = nil
        let now = ProcessInfo.processInfo.systemUptime
        let tap = now - started < 0.28
        let doubleTap = dictationProfile.shortcut == .fn
            && tap && previousVoiceTap.map { started - $0 < 0.42 } == true
        previousVoiceTap = tap && !doubleTap ? now : nil
        if doubleTap {
            startSustainedVoiceAudio()
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
                self?.stopVoiceAudio()
            }) { voiceAudioKeyMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                self?.stopVoiceAudio()
                return event
            }) { voiceAudioKeyMonitors.append(local) }
        } else {
            scheduleVoiceAudioStop(after: tap ? 0.45 : 0.15)
        }
    }

    private func startSustainedVoiceAudio() {
        voiceAudioLatched = true
        scheduleVoiceAudioStop(after: Self.remoteVoiceSessionLimit, atSessionLimit: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.voiceAudioLatched else { return }
            if !self.voice.requestAudio() { self.handleRemoteVoiceInterruption() }
        }
    }

    private func scheduleVoiceAudioStop(after interval: TimeInterval, atSessionLimit: Bool = false) {
        voiceAudioTimeout?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            if atSessionLimit || self.toggleShortcut != nil { self.releaseDictationShortcut(closeToggle: true) }
            self.stopVoiceAudio()
            if atSessionLimit { self.voiceAudioStatus = "已达 30 分钟听写上限" }
        }
        voiceAudioTimeout = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopVoiceAudio() {
        let wasRecording = voicePressStarted != nil || voiceAudioLatched
        voiceAudioTimeout?.invalidate()
        voiceAudioTimeout = nil
        voicePressStarted = nil
        previousVoiceTap = nil
        voiceAudioLatched = false
        voiceAudioKeyMonitors.forEach { NSEvent.removeMonitor($0) }
        voiceAudioKeyMonitors.removeAll()
        voice.stopAudio()
        if !dictationReading || !microphoneBridge.isCapturingComputer { microphoneBridge.stop() }
        if wasRecording { noteRemoteActivity() }
    }

    private func sendFn(for button: ButtonID) {
        if !fnButtons.isEmpty || Output.postFn(down: true) {
            fnButtons.insert(button)
        } else {
            status = "未发送 Fn · 请检查辅助功能权限"
        }
    }

    static func shortcutLabel(_ rule: BindingRule) -> String {
        let mask = NSEvent.ModifierFlags(rawValue: UInt(rule.modifiers))
        var prefix = ""
        for (flag, symbol) in [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] where mask.contains(flag) {
            prefix += symbol
        }
        let named: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: ui("空格"), 51: "Delete", 53: "Esc", 76: "Enter", 117: "Forward Delete",
            115: "Home", 116: "Page Up", 119: "End", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3",
            118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        if let name = named[rule.keyCode] { return prefix + name }
        let ansi = ["A","S","D","F","H","G","Z","X","C","V","§","B","Q","W","E","R","Y","T",
                    "1","2","3","4","6","5","=","9","7","-","8","0","]","O","U","[",
                    "I","P","Return","L","J","'","K",";","\\",",","/","N","M","."]
        return prefix + (Int(rule.keyCode) < ansi.count ? ansi[Int(rule.keyCode)] : ui("键码 \(rule.keyCode)"))
    }
}

struct DeskView: View {
    @ObservedObject var desk: Desk
    private let accent = Color.accentColor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let release = desk.availableUpdate {
                HStack(spacing: 10) {
                    Label(ui("有新版本：\(release.tagName)"), systemImage: "arrow.down.circle")
                    Spacer()
                    Button(ui("查看更新…"), action: desk.showAvailableUpdate)
                    Button(ui("稍后"), action: desk.dismissUpdateNotice).buttonStyle(.borderless)
                }
                .font(.callout).padding(.horizontal, 24).padding(.vertical, 10)
                .background(accent.opacity(0.06))
                Divider()
            }
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    sidebar.frame(width: min(400, max(300, geometry.size.width * 0.40)))
                    Divider()
                    details.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 960, minHeight: 640, idealHeight: 760)
        .tint(accent)
        .sheet(item: $desk.pendingPresetFile) { presetImportPreview($0) }
    }

    private var microphoneSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(ui("设置遥控器麦克风"), systemImage: "mic.badge.plus")
                .font(.callout.weight(.medium))
            Text(ui("安装 Remote Go Mic 后，在这里和听写软件中选择同一个麦克风。"))
                .font(.callout).foregroundStyle(.secondary)
            Button(ui(desk.openingMicSetup ? "正在查找安装包…" : "获取 Remote Go Mic…"),
                   action: desk.showMicrophoneSetup)
                .disabled(desk.openingMicSetup)
            Text(ui("仅使用按键时，无需安装。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(InspectorCard())
    }

    private var dictationControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(ui("语音快捷键"))
                Spacer()
                Button(desk.recordingShortcut && !desk.recordingDoubleTapShortcut ? ui("请按快捷键…") : desk.dictationProfile.shortcut.label) {
                    desk.recordDictationShortcut()
                }
            }
            Picker(ui("快捷键模式"), selection: Binding(
                get: { desk.dictationProfile.mode },
                set: { mode in desk.updateDictationProfile { $0.mode = mode } }
            )) {
                ForEach(DictationMode.allCases, id: \.self) { mode in Text(ui(mode.title)).tag(mode) }
            }
            .id(desk.interfaceLanguage)
            if desk.dictationProfile.mode == .hold {
                HStack {
                    Toggle(ui("双击语音键"), isOn: Binding(
                        get: { desk.dictationProfile.doubleTapShortcut != nil },
                        set: { enabled in
                            if desk.recordingDoubleTapShortcut { desk.finishShortcut() }
                            desk.updateDictationProfile { $0.doubleTapShortcut = enabled ? .fnLeftControl : nil }
                        }
                    )).toggleStyle(.checkbox)
                    Spacer()
                    if let shortcut = desk.dictationProfile.doubleTapShortcut {
                        Button(desk.recordingDoubleTapShortcut ? ui("请按快捷键…") : shortcut.label) {
                            desk.recordDictationShortcut(doubleTap: true)
                        }
                    }
                }
            }
            Picker(ui("虚拟麦克风"), selection: Binding(
                get: { desk.dictationProfile.deviceUID },
                set: { device in desk.updateDictationProfile { $0.deviceUID = device } }
            )) {
                if !desk.loopbackDevices.contains(where: { $0.id == desk.dictationProfile.deviceUID }) {
                    Text(desk.dictationProfile.deviceUID == MicrophoneDevices.remoteGoMicUID
                         ? ui("Remote Go Mic（未连接）")
                         : desk.dictationProfile.deviceUID == MicrophoneDevices.blackHoleUID
                            ? ui("BlackHole 2ch（未连接）") : ui("所选设备未连接"))
                        .tag(desk.dictationProfile.deviceUID)
                }
                ForEach(desk.loopbackDevices) { device in Text(device.name).tag(device.id) }
            }
            .id(desk.interfaceLanguage)
            Text(ui("在听写软件里设成相同的快捷键和麦克风。"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func presetImportPreview(_ file: PresetFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ui("预览导入的预设")).font(.title2.weight(.semibold))
            Text(file.name).font(.headline).lineLimit(2)
            List {
                Section(ui("默认映射")) {
                    if file.rules.isEmpty { Text(ui("没有默认按键映射")).foregroundStyle(.secondary) }
                    ForEach(file.rules, content: presetImportRow)
                }
                ForEach(file.appRules.keys.sorted(), id: \.self) { appID in
                    Section(desk.library.apps.first { $0.id == appID }?.interfaceName
                            ?? file.applications.first { $0.id == appID }?.name ?? appID) {
                        ForEach(file.appRules[appID] ?? [], content: presetImportRow)
                    }
                }
            }
            Text(ui("导入后可在预设列表中选择使用。")).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(ui("取消")) { desk.pendingPresetFile = nil }
                    .keyboardShortcut(.cancelAction)
                Button(ui("导入预设")) { desk.confirmPresetImport(file) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 410)
    }

    private func presetImportRow(_ rule: BindingRule) -> some View {
        HStack {
            Text(rule.id.interfaceLabel)
            Spacer()
            Text(rule.id == .power ? ui("切换启用改键") : (
                rule.action == .shortcut ? Desk.shortcutLabel(rule) : rule.action.title
            )).foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        let language = desk.interfaceLanguage.alternate
        return HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().scaledToFit()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            Text(appDisplayName).font(.system(size: 19, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(desk.connected > 0 ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(desk.connected > 0 ? ui("已连接") : ui("未连接"))
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: Capsule())
            Toggle(ui("启用改键"), isOn: Binding(get: { desk.mappingRequested }, set: { desk.setActive($0) }))
                .toggleStyle(.switch).fixedSize()
                .padding(.leading, 8)
            Divider().frame(height: 22).padding(.horizontal, 4)
            Toggle(isOn: Binding(get: { desk.pointerModeActive }, set: { enabled in
                if enabled != desk.pointerModeActive { desk.togglePointerMode() }
            })) {
                Label(ui("飞鼠模式"), systemImage: "cursorarrow")
            }
            .toggleStyle(.switch).fixedSize()
            .disabled(!desk.active || !desk.capturing || !desk.outputAllowed)
            .help(ui("信源键长按 1 秒"))
            Button { desk.interfaceLanguage = language } label: {
                Image(systemName: "globe")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.system(size: 16))
            .accessibilityLabel(language.title)
            .help(ui("切换界面语言"))
            .padding(.leading, 8)
            Menu {
                Button(ui(desk.checkingForUpdates ? "正在检查更新…" : "检查更新…"), action: desk.checkForUpdates)
                    .disabled(desk.checkingForUpdates)
                if desk.availableUpdate != nil {
                    Button(ui("查看更新…"), action: desk.showAvailableUpdate)
                }
                Toggle(ui("自动检查更新"), isOn: Binding(get: { desk.automaticallyChecksForUpdates },
                                                       set: desk.setAutomaticUpdates))
                Divider()
                Button(ui("输入监控"), action: desk.grantInput)
                Button(ui("辅助功能"), action: desk.grantOutput)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .accessibilityLabel(ui("权限设置"))
            .help(ui("权限设置"))
        }
        .padding(.horizontal, 24).padding(.vertical, 15)
        .background(.bar)
    }

    private var presetBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(ui("当前预设")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Picker(ui("当前预设"), selection: Binding(get: { desk.library.activeID }, set: desk.switchPreset(to:))) {
                    ForEach(desk.library.presets) { preset in Text(preset.interfaceName).tag(preset.id) }
                }
                .labelsHidden().controlSize(.large)
                .id(desk.interfaceLanguage)
                Menu {
                    Button(ui("复制为新预设…")) { desk.promptPresetName() }
                    Button(ui("新建空白预设…")) { desk.promptPresetName(copyCurrent: false) }
                    Button(ui("重命名…")) { desk.promptPresetName(renaming: true) }
                        .disabled(desk.library.active.isBuiltIn)
                    Divider()
                    Button(ui("导入预设…"), action: desk.importPreset)
                    Button(ui("导出当前预设…"), action: desk.exportPreset)
                    Divider()
                    Button(ui("删除此预设…"), role: .destructive) { desk.confirmDeletePreset() }
                        .disabled(desk.library.active.isBuiltIn)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 19))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(ui("管理预设"))
                .help(ui("管理预设"))
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(ui("Chromecast 遥控器"))
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: desk.learn) {
                    Image(systemName: desk.learning ? "xmark" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .accessibilityLabel(desk.learning ? ui("取消") : ui("学习按键"))
                .help(desk.learning ? ui("取消") : ui("学习按键"))
            }
            Text(desk.learning ? ui("按下实体键以定位") : ui("点选图上的按键进行编辑"))
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, 4)
            RemotePicture(desk: desk, accent: accent)
                .frame(maxWidth: .infinity, maxHeight: 520)
                .padding(.vertical, 24)
                .frame(maxHeight: .infinity)
            Divider().padding(.bottom, 16)
            HStack(spacing: 11) {
                Image(systemName: desk.selection == .assistant ? "mic.fill" : "appletvremote.gen4")
                    .font(.system(size: 16))
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(desk.selection?.interfaceLabel ?? ui("选择一个按键"))
                        .font(.callout.weight(.semibold))
                    Text(desk.selection.map { desk.mappingTitle($0) } ?? ui("点选图上的按键进行编辑"))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .background(.regularMaterial)
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ui("按键设置")).font(.title2.weight(.semibold))
                    Spacer()
                    Label(ui("自动保存"), systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                presetBar
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(ui("按应用改键")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: desk.addMappingApp) { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(ui("添加应用…"))
                            .help(ui("添加应用…"))
                    }
                    Picker(ui("按应用改键"), selection: Binding(get: { desk.editingAppID }, set: desk.selectMappingApp)) {
                        Text(ui("默认映射")).tag("")
                        ForEach(desk.library.apps) { Text($0.interfaceName).tag($0.id) }
                    }
                    .labelsHidden().controlSize(.large)
                    .id(desk.interfaceLanguage)
                }
                if desk.selection == .power {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(ButtonID.power.interfaceLabel).font(.system(size: 20, weight: .semibold))
                        Text(ui("按一下暂停改键，再按一下恢复。暂停期间只有电源键可用。"))
                        Label(ui("如果电源键只发红外信号，Mac 收不到。可用「学习按键」确认。"), systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(InspectorCard())
                } else if desk.selection == .assistant {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(ButtonID.assistant.interfaceLabel).font(.system(size: 20, weight: .semibold))
                        dictationControls
                        if desk.active {
                            Text(ui(desk.voiceStatus)).font(.callout).foregroundStyle(.secondary)
                        }
                        if let audioStatus = desk.voiceAudioStatus {
                            Text(ui(audioStatus)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(InspectorCard())
                    if !desk.dictationDeviceAvailable { microphoneSetup }
                } else if let id = desk.selection {
                    let rule = desk.ruleForEditor(id)
                    let physical = PhysicalKey.keys.first { $0.id == id }
                    let scoped = !desk.editingAppID.isEmpty
                    let overridden = scoped && desk.library.active.override(for: id, appID: desk.editingAppID) != nil
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(id.interfaceLabel).font(.system(size: 20, weight: .semibold))
                                Text(scoped && !overridden ? ui("沿用默认 · \(desk.mappingTitle(id))") : desk.mappingTitle(id))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if overridden {
                                Button(ui("恢复默认")) { desk.remove(id) }.buttonStyle(.borderless)
                            } else if scoped && rule.action == .shortcut {
                                Button(ui("自定义快捷键")) { desk.update(id) { $0.action = .shortcut } }
                                    .buttonStyle(.borderless)
                            } else if !scoped && rule.action != .unassigned {
                                Button(ui("清除映射")) { desk.remove(id) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 15, verticalSpacing: 10) {
                            if rule.action != .unassigned && (!scoped || overridden) {
                                GridRow {
                                    Text(ui("显示名称"))
                                    TextField(ui("显示名称"), text: Binding(get: {
                                        rule.name == id.label ? id.interfaceLabel : rule.name
                                    }, set: { value in
                                        desk.update(id) { $0.name = value }
                                    })).labelsHidden()
                                }
                            }
                            GridRow {
                                Text(ui("按下时"))
                                actionMenu(id: id, selected: scoped && !overridden ? .unassigned : rule.action,
                                           scoped: scoped)
                            }
                            if rule.action == .shortcut && (!scoped || overridden) {
                                GridRow {
                                    Text(ui("快捷键"))
                                    HStack {
                                        Button(desk.recordingShortcut ? ui("按下键盘快捷键…") : Desk.shortcutLabel(rule)) {
                                            desk.recordShortcut(id)
                                        }
                                        if desk.recordingShortcut { Button(ui("取消"), action: desk.finishShortcut) }
                                    }
                                }
                            }
                        }
                        if rule.action == .sessions {
                            Text(ui("在 Codex 或 Claude 中打开会话列表，用 ↑／↓ 选择，按确定进入。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .cycleCodex {
                            Text(ui("短按轮换最近 3 个 Codex 会话，并尝试聚焦输入框。记录不足时使用 Codex 自带的最近会话位。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .nextCodexSession || rule.action == .previousCodexSession {
                            Text(ui("按 Codex 左侧列表顺序移动，到首尾停止。切换后尝试聚焦对话输入框。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .nextGrokBotSession || rule.action == .previousGrokBotSession {
                            Text(ui("按 Grok Bot 左栏顺序切换会话，到首尾停止。切换后聚焦对话输入框。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if id == .volumeUp && rule.action == .previousCodexSession {
                            Text(ui("在 Codex 前台，短按往左栏上一项，按住 1 秒显示 Codex 用量。"))
                                .font(.callout).foregroundStyle(.secondary)
                            Button(ui("查看 Codex 用量"), action: desk.showCodexUsage)
                        }
                        if rule.action == .cycleAgents {
                            Text(ui("在 Codex 与 Claude 间来回切换，进入各自当前会话的输入框。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .appSwitcher {
                            Text(id == .source
                                ? ui("短按切换应用，按住 1 秒进入或退出飞鼠模式。应用列表里用方向键选择，按确定打开。")
                                : ui("列出正在运行的 App。用方向键选择，按确定打开，按返回关闭。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .videoPlayPause || rule.action == .videoFullscreen
                            || rule.action == .youtubePlayPause || rule.action == .youtubeCaptions {
                            Text(ui("先把视频播放器切到前台。使用网页播放器时，点一下视频区域，让快捷键发送给播放器。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if (id == .source && rule.action == .appSwitcher) || rule.action == .pointerMode {
                            Text(ui("飞鼠模式下，方向键移动指针，确定点按，音量键按住连续滚动，返回退出。也可以在窗口顶部开关。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.keyboardStroke != nil {
                            Text(ui("短按发送一次，长按按 Mac 的键盘设置连发。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .volumeUp || rule.action == .volumeDown {
                            Text(ui("短按调节一次音量，按住连续调节。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action.chatTarget != nil {
                            Button(ui("试开对话框")) { desk.openConversation(rule.action) }
                        }
                        if physical?.mayUseInfrared == true {
                            Label(ui("如果这颗键只向电视发红外信号，Mac 收不到。可用「学习按键」确认。"), systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .fn {
                            Text(ui("发送 Fn，保留按下与松开的时长。微信语音输入法会按现有设置处理双击和长按。"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.modifier(InspectorCard())
                    if id == .home { homeSwitchCard }
                }
            }
            .frame(maxWidth: 600)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func actionMenu(id: ButtonID, selected: Action, scoped: Bool) -> some View {
        Menu {
            actionOption(.unassigned, id: id, selected: selected,
                         title: scoped ? ui("沿用默认映射") : Action.unassigned.title)
            Divider()
            ForEach(Action.menuGroups.indices, id: \.self) { index in
                let group = Action.menuGroups[index]
                Menu(ui(group.title)) {
                    ForEach(group.actions) { action in
                        actionOption(action, id: id, selected: selected, title: action.title)
                    }
                }
            }
            Divider()
            actionOption(.suppress, id: id, selected: selected, title: Action.suppress.title)
        } label: {
            Text(scoped && selected == .unassigned ? ui("沿用默认映射") : selected.title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(ui("按下时"))
        .accessibilityValue(scoped && selected == .unassigned ? ui("沿用默认映射") : selected.title)
        .id(desk.interfaceLanguage)
    }

    private func actionOption(_ action: Action, id: ButtonID, selected: Action, title: String) -> some View {
        Button {
            desk.finishShortcut()
            desk.update(id) { $0.action = action }
        } label: {
            if action == selected { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }

    private var homeSwitchCard: some View {
        let settings = desk.library.homeSwitch
        return VStack(alignment: .leading, spacing: 10) {
            Toggle(ui("长按主页键切换预设"), isOn: Binding(get: { settings.enabled }, set: { enabled in
                desk.updateHomeSwitch { $0.enabled = enabled }
            })).toggleStyle(.switch)
            if settings.enabled {
                if desk.ruleForEditor(.home).action == .fn || desk.ruleForEditor(.home).keyboardStroke != nil {
                    Text(ui("主页键映射到键盘时，长按用于发送该键。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker(ui("预设一"), selection: Binding(get: { settings.firstID }, set: { id in
                    desk.updateHomeSwitch { $0.firstID = id }
                })) {
                    ForEach(desk.library.presets.filter { $0.id != settings.secondID }) { Text($0.interfaceName).tag($0.id) }
                }
                Picker(ui("预设二"), selection: Binding(get: { settings.secondID }, set: { id in
                    desk.updateHomeSwitch { $0.secondID = id }
                })) {
                    ForEach(desk.library.presets.filter { $0.id != settings.firstID }) { Text($0.interfaceName).tag($0.id) }
                }
            }
        }
        .modifier(InspectorCard())
    }

    private var footerStatus: String {
        let key = desk.status.key
        if ["已导入预设", "已导出预设", "无法导入", "无法导出", "此文件的预设格式", "预设文件超过", "无法打开遥控器"]
            .contains(where: key.hasPrefix) { return ui(desk.status) }
        if desk.connected == 0 && !desk.learning && !desk.recordingShortcut {
            return desk.mappingRequested ? ui("待机 · 等待遥控器连接") : ui("遥控器未连接 · 可先配置按键")
        }
        guard desk.active, desk.capturing, !desk.learning else { return ui(desk.status) }
        guard desk.outputAllowed else { return ui("已接管遥控器 · 发送快捷键需要辅助功能权限") }
        if desk.pointerModeActive { return ui("飞鼠模式 · 按返回退出") }
        if key.hasPrefix("已聚焦") || key.hasPrefix("已打开") || key.hasPrefix("没有找到")
            || key.hasPrefix("无法打开") || key.contains("会话选择")
            || key.hasPrefix("请先打开") || key.contains("Codex 会话")
            || key.hasPrefix("Codex 最近会话位") { return ui(desk.status) }
        return ui("Remote Go 已启动 · 未配置的遥控器按键暂停")
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(footerStatus).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).help(footerStatus)
            Spacer(minLength: 12)
            if let last = desk.lastButton {
                Button(action: desk.addLast) {
                    Label(ui("最近按键  ") + last.interfaceLabel, systemImage: "waveform.path")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            } else {
                Text(ui("尚未收到按键")).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.bar)
    }
}

private struct InspectorCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

final class DeskDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let desk = Desk()
    private var window: NSWindow?
    private var menuItem: NSStatusItem?
    private let loginService = SMAppService.mainApp
    private var startsInMenuBar: Bool {
        loginService.status == .enabled && !ProcessInfo.processInfo.arguments.contains("--ui-preview")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        desk.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window?.minSize = NSSize(width: 820, height: 640)
        window?.isReleasedWhenClosed = false
        window?.delegate = self
        window?.title = appDisplayName
        window?.contentView = NSHostingView(rootView: DeskView(desk: desk))
        window?.center()
        let tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        tray.button?.image = NSImage(systemSymbolName: "appletvremote.gen4", accessibilityDescription: appDisplayName)
        menuItem = tray
        desk.onLanguageChange = { [weak self] in self?.updateMenus() }
        desk.onUpdateCheckStateChange = { [weak self] in self?.updateMenus() }
        updateMenus()
        if startsInMenuBar {
            NSApp.setActivationPolicy(.accessory)
        } else {
            showWindow()
        }
    }

    private func updateMenus() {
        let systemMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        addUpdateItems(to: appItem.submenu!)
        appItem.submenu?.addItem(.separator())
        appItem.submenu?.addItem(withTitle: ui("退出 \(appDisplayName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        systemMenu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: ui("编辑"))
        editItem.submenu?.addItem(withTitle: ui("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editItem.submenu?.addItem(withTitle: ui("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editItem.submenu?.addItem(withTitle: ui("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu?.addItem(withTitle: ui("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        systemMenu.addItem(editItem)
        NSApp.mainMenu = systemMenu
        let menu = NSMenu()
        let show = NSMenuItem(title: ui("打开 \(appDisplayName)"), action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let pause = NSMenuItem(title: ui("暂停改键"), action: #selector(pauseMapping), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let login = NSMenuItem(title: ui("登录时在菜单栏启动"),
                               action: #selector(toggleLoginStartup), keyEquivalent: "")
        login.target = self
        if loginService.status == .enabled { login.state = .on }
        if loginService.status == .requiresApproval { login.state = .mixed }
        menu.addItem(login)
        menu.addItem(.separator())
        addUpdateItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: ui("退出 \(appDisplayName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menuItem?.menu = menu
        menuItem?.button?.toolTip = desk.availableUpdate.map { ui("有新版本：\($0.tagName)") } ?? appDisplayName
    }

    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func pauseMapping() { desk.setActive(false) }

    private func addUpdateItems(to menu: NSMenu) {
        if let release = desk.availableUpdate {
            let notice = NSMenuItem(title: ui("有新版本：\(release.tagName)"),
                                    action: #selector(showAvailableUpdate), keyEquivalent: "")
            notice.target = self
            menu.addItem(notice)
        }
        let check = NSMenuItem(title: ui(desk.checkingForUpdates ? "正在检查更新…" : "检查更新…"),
                               action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let automatic = NSMenuItem(title: ui("自动检查更新"), action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
        automatic.target = self
        automatic.state = desk.automaticallyChecksForUpdates ? .on : .off
        menu.addItem(automatic)
    }

    @MainActor @objc private func checkForUpdates() { desk.checkForUpdates() }
    @MainActor @objc private func showAvailableUpdate() { desk.showAvailableUpdate() }
    @objc private func toggleAutomaticUpdates() { desk.setAutomaticUpdates(!desk.automaticallyChecksForUpdates) }

    @objc private func toggleLoginStartup() {
        do {
            switch loginService.status {
            case .enabled:
                try loginService.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try loginService.register()
                if loginService.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            desk.status = "无法更改登录启动 · \(error.localizedDescription)"
            showWindow()
        }
        updateMenus()
    }

    func windowWillClose(_ notification: Notification) {
        if startsInMenuBar { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        desk.refreshPermissions()
        updateMenus()
    }

    func applicationWillTerminate(_ notification: Notification) { desk.stop() }
}

@main struct RemoteDesk {
    static func main() {
        let flags = ProcessInfo.processInfo.arguments
        if flags.contains("--self-test") {
            let menuActions = Action.menuGroups.flatMap(\.actions) + [.unassigned, .suppress]
            precondition(Set(menuActions) == Set(Action.allCases.filter { $0 != .voice }))
            precondition(menuActions.count == Set(menuActions).count)
            let dictation = DictationProfile.defaults
            precondition(dictation.shortcut == .fn && dictation.mode == .hold)
            let shortcut = DictationShortcut(keyCode: UInt16(kVK_Space), modifiers: CGEventFlags.maskAlternate.rawValue)
            precondition(shortcut.event(down: true)?.type == .keyDown)
            precondition(shortcut.event(down: true)?.flags.contains(.maskAlternate) == true)
            precondition(shortcut.event(down: false)?.type == .keyUp)
            let rightControl = DictationShortcut(keyCode: UInt16(kVK_RightControl), modifiers: 0)
            precondition(rightControl.event(down: true)?.type == .flagsChanged)
            precondition(rightControl.event(down: true)?.flags.rawValue == CGEventFlags.maskControl.rawValue | 0x2000)
            precondition(rightControl.event(down: false)?.flags.contains(.maskControl) == false)
            let customDictation = DictationProfile(shortcut: shortcut, mode: .toggle, deviceUID: "vRemoteDr2ch_UID")
            let profileData = try! JSONEncoder().encode(customDictation)
            precondition((try? JSONDecoder().decode(DictationProfile.self, from: profileData)) == customDictation)
            precondition(customDictation.doubleTapShortcut == nil)
            let handsFree = DictationShortcut.fnLeftControl
            let chord = handsFree.events(down: true)! + handsFree.events(down: false)!
            precondition(chord.allSatisfy { $0.type == .flagsChanged })
            precondition(chord.map { $0.getIntegerValueField(.keyboardEventKeycode) }
                == [kVK_Function, kVK_Control, kVK_Control, kVK_Function].map(Int64.init))
            precondition(chord.map(\.flags) == [.maskSecondaryFn,
                [.maskSecondaryFn, .maskControl, CGEventFlags(rawValue: 0x01)], .maskSecondaryFn, []])
            precondition(DictationShortcut.fromModifier(UInt16(kVK_Control), flags: [.control, .function]) == handsFree)
            precondition(DictationShortcut.fromModifier(UInt16(kVK_Function), flags: [.control, .function]) == handsFree)
            precondition(InterfaceLanguage.english.translate("启用改键") == "Enable Remapping")
            let localizedStatus: InterfaceMessage = "已切换到 \(InterfaceMessage(stringLiteral: "看视频"))"
            precondition(localizedStatus.render(.english) == "Switched to Watch Video")
            precondition(localizedStatus.render(.simplifiedChinese) == "已切换到 看视频")
            for action in Action.allCases where action != .fn && action != .pointerMode {
                precondition(InterfaceLanguage.english.translate(action.rawValue) != action.rawValue)
            }
            var history = CodexSessionHistory()
            precondition(history.next() == .slot(2) && history.next() == .slot(3) && history.next() == .slot(1))
            precondition(history.next(in: .previous) == .slot(3) && history.next() == .slot(1))
            for id in ["a", "b", "c"] { history.observe(id) }
            precondition(history.next() == .thread("b"))
            history.observe("b")
            precondition(history.next() == .thread("a"))
            precondition(history.next(in: .previous) == .thread("b"))
            precondition(history.next() == .thread("a"))
            history.observe("a")
            precondition(history.next() == .thread("c"))
            history.observe("d")
            precondition(history.recent == ["d", "a", "b"])
            precondition(history.next() == .thread("a"))
            let threadID = "019a5e41-1234-7234-8234-123456789012"
            precondition(Output.codexSessionID(in: URL(string: "app://-/local/\(threadID)")!) == threadID)
            precondition(Output.codexSessionID(in: URL(string: "app://-/index.html#/local/\(threadID)?mode=codex")!) == threadID)
            precondition(Output.codexSessionID(in: URL(string: "codex://threads/\(threadID)")!) == threadID)
            precondition(Output.codexSessionID(in: URL(string: "app://-/local/foo")!) == nil)
            let defaults = UserDefaults(suiteName: "me.tianrun.remotedesk.session-migration-test")!
            defaults.removePersistentDomain(forName: "me.tianrun.remotedesk.session-migration-test")
            let initial = PresetLibrary.load(from: defaults)
            let volumePlus = ButtonID(page: 12, usage: 0xE9)
            let volumeMinus = ButtonID(page: 12, usage: 0xEA)
            precondition(initial.active.name == "Agent Coding")
            precondition(initial.active.rule(for: .mute, appID: nil)?.action == .escape)
            precondition(initial.presets.first { $0.id == PresetLibrary.videoID }?
                .rule(for: .mute, appID: nil)?.action == .mute)
            precondition(initial.active.rule(for: volumePlus, appID: ChatTarget.codex.rawValue)?.action == .previousCodexSession)
            precondition(initial.active.rule(for: volumeMinus, appID: ChatTarget.codex.rawValue)?.action == .nextCodexSession)
            precondition(initial.active.rule(for: volumePlus, appID: ChatTarget.claude.rawValue) == nil)
            let grokBotID = ChatTarget.grokBot.rawValue
            precondition(initial.apps.filter { $0.id == grokBotID }.count == 1)
            precondition(initial.active.rule(for: volumePlus, appID: grokBotID)?.action == .previousGrokBotSession)
            precondition(initial.active.rule(for: volumeMinus, appID: grokBotID)?.action == .nextGrokBotSession)
            precondition(initial.presets.first { $0.id == PresetLibrary.videoID }?
                .rule(for: volumePlus, appID: grokBotID)?.action == .volumeUp)
            precondition(ChatTarget.grokBot.identifiesComposer(["提示词", "给某个 Bot 发消息"]))
            precondition(initial.active.rule(for: .home, appID: nil)?.action == .cycleCodex)
            let video = initial.presets.first { $0.id == PresetLibrary.videoID }!
            precondition(video.rule(for: .home, appID: nil)?.action == .videoFullscreen)
            precondition(video.rule(for: ButtonID(page: 12, usage: 0x77), appID: nil)?.action == .watchYouTube)
            precondition(video.rule(for: ButtonID(page: 12, usage: 0x78), appID: nil)?.action == .youtubeCaptions)
            precondition(video.rule(for: ButtonID(page: 12, usage: 0x44), appID: nil)?.keyboardStroke?.key == UInt16(kVK_ANSI_J))
            precondition(video.rule(for: ButtonID(page: 12, usage: 0x45), appID: nil)?.keyboardStroke?.key == UInt16(kVK_ANSI_L))
            precondition(Action.watchYouTube.videoURL?.host == "www.youtube.com")
            precondition(Action.watchNetflix.videoURL?.host == "www.netflix.com")
            precondition(Action.videoFullscreen.videoStroke(in: "com.apple.QuickTimePlayerX")?.flags == CGEventFlags.maskCommand.rawValue)
            precondition(Action.videoFullscreen.videoStroke(in: nil)?.flags == 0)
            precondition(Action.cycleAgents.isGlobal)
            let mainDisplay = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let rightDisplay = CGRect(x: 1000, y: -200, width: 700, height: 900)
            let screens = [mainDisplay, rightDisplay]
            precondition(PointerMode.position(from: CGPoint(x: 997, y: 300), offset: CGVector(dx: 7, dy: 0),
                                              on: screens) == CGPoint(x: 1004, y: 300))
            precondition(PointerMode.position(from: CGPoint(x: 997, y: 780), offset: CGVector(dx: 7, dy: 0),
                                              on: screens) == CGPoint(x: 999, y: 780))
            precondition(PointerMode.speed(heldFor: 0.2) < PointerMode.speed(heldFor: 0.7))
            precondition(PointerMode.speed(heldFor: 1) == PointerMode.speed(heldFor: 3))
            precondition(Action.pointerMode.isGlobal)
            let scrollUp = ButtonID(page: 12, usage: 0xE9)
            let scrollDown = ButtonID(page: 12, usage: 0xEA)
            precondition(PointerMode.repeatedScroll(held: [scrollUp: 1], at: 1.20) == 0)
            precondition(PointerMode.repeatedScroll(held: [scrollUp: 1], at: 1.30) > 0)
            precondition(PointerMode.repeatedScroll(held: [scrollDown: 1], at: 1.30) < 0)
            precondition(PointerMode.repeatedScroll(held: [scrollUp: 1, scrollDown: 1], at: 1.30) == 0)
            precondition(PointerMode.repeatedScroll(held: [:], at: 1.30) == 0)
            var binding = BindingRule(id: ButtonID(page: 12, usage: 0x224), name: "返回",
                                      action: .shortcut, keyCode: UInt16(kVK_Delete))
            precondition(binding.keyboardStroke?.key == UInt16(kVK_Delete))
            binding.keyCode = UInt16(kVK_Return)
            binding.modifiers = CGEventFlags.maskCommand.rawValue
            precondition(binding.keyboardStroke?.key == UInt16(kVK_Return))
            precondition(binding.keyboardStroke?.flags == binding.modifiers)
            binding.action = .left
            precondition(binding.keyboardStroke?.key == UInt16(kVK_LeftArrow))
            precondition(binding.keyboardStroke?.flags == 0)
            for action in [Action.fn, .appSwitcher, .preview] {
                binding.action = action
                precondition(binding.keyboardStroke == nil)
            }
            let down = Output.keyboardEvent(UInt16(kVK_Delete), flags: 0, down: true)
            let repeated = Output.keyboardEvent(UInt16(kVK_Delete), flags: 0, down: true, isRepeat: true)
            let up = Output.keyboardEvent(UInt16(kVK_Delete), flags: 0, down: false)
            precondition(down?.type == .keyDown && up?.type == .keyUp)
            precondition(down?.getIntegerValueField(.keyboardEventAutorepeat) == 0)
            precondition(repeated?.type == .keyDown && repeated?.getIntegerValueField(.keyboardEventAutorepeat) == 1)
            let model = PhysicalKey.keys
            precondition(model.count == 15 && Set(model.map(\.id)).count == 15)
            let selectors: [UInt8] = [1, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 17]
            precondition(Set(selectors.flatMap { RemoteHID.decode([$0, 0]) }) == Set(model.map(\.id)).subtracting([.assistant]))
            let resource = Bundle.main.url(forResource: "chromecast-voice-remote", withExtension: "png")
            precondition(resource.flatMap(NSImage.init(contentsOf:)) != nil)
            let suite = "me.tianrun.remotedesk.tests.\(UUID().uuidString)"
            let testDefaults = UserDefaults(suiteName: suite)!
            let legacy: [BindingRule] = [
                BindingRule(id: ButtonID(page: 12, usage: 0x42), name: "向上", action: .pageUp),
                BindingRule(id: ButtonID(page: 12, usage: 0x19E), name: "电源", action: .escape),
            ]
            testDefaults.set(try! JSONEncoder().encode(legacy), forKey: "rules")
            let editor = Desk(defaults: testDefaults)
            let transferURL = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".remote-go.json")
            try! PresetFile(preset: editor.library.active, apps: editor.library.apps).write(to: transferURL)
            let presetFile = try! PresetFile.read(from: transferURL)
            let packaged = try! Data(contentsOf: transferURL)
            try! FileManager.default.removeItem(at: transferURL)
            precondition(presetFile.rules == editor.library.active.rules)
            precondition(!presetFile.appRules.isEmpty && presetFile.appRules == editor.library.active.appRules)
            var unsupported = try! JSONSerialization.jsonObject(with: packaged) as! [String: Any]
            unsupported["version"] = PresetFile.version + 1
            let futureFile = try! JSONSerialization.data(withJSONObject: unsupported)
            precondition((try? PresetFile.decode(futureFile)) == nil)
            let transferSuite = suite + ".transfer"
            let transferDefaults = UserDefaults(suiteName: transferSuite)!
            let receiver = Desk(defaults: transferDefaults)
            precondition(receiver.installPresetFile(presetFile) == "Agent Coding (2)")
            precondition(receiver.library.activeID == PresetLibrary.codingID)
            let imported = Desk(defaults: transferDefaults).library.presets.last!
            precondition(!imported.isBuiltIn && imported.rules == presetFile.rules && imported.appRules == presetFile.appRules)
            transferDefaults.removePersistentDomain(forName: transferSuite)
            precondition(editor.ruleForEditor(.source).action == .appSwitcher)
            let workBuddy = MappingApp.builtIn.first { $0.name == "WorkBuddy" }!.id
            let claude = ChatTarget.claude.rawValue
            let arrow = legacy[0].id
            editor.selectMappingApp(workBuddy)
            precondition(editor.ruleForEditor(arrow).action == .up)
            editor.update(arrow) { $0.action = .escape }
            precondition(editor.library.active.rule(for: arrow, appID: workBuddy)?.action == .escape)
            precondition(editor.library.active.rule(for: arrow, appID: claude)?.action == .up)
            precondition(editor.library.active.rule(for: arrow, appID: nil)?.action == .up)
            precondition(Desk(defaults: testDefaults).library.active.override(for: arrow, appID: workBuddy)?.action == .escape)
            precondition(editor.createPreset(name: "应用映射副本", copyCurrent: true))
            precondition(editor.library.active.override(for: arrow, appID: workBuddy)?.action == .escape)
            editor.remove(arrow)
            precondition(editor.library.active.override(for: arrow, appID: workBuddy) == nil)
            precondition(editor.ruleForEditor(arrow).action == .up)
            editor.deleteActivePreset()
            precondition(editor.library.active.override(for: arrow, appID: workBuddy)?.action == .escape)
            editor.remove(arrow)
            editor.selectMappingApp("")
            precondition(editor.ruleForEditor(legacy[0].id).action == .up)
            precondition(!editor.ruleForEditor(legacy[0].id).codexOnly)
            precondition(editor.ruleForEditor(legacy[1].id).action == .escape)
            editor.switchPreset(to: PresetLibrary.videoID)
            precondition(editor.ruleForEditor(.source).action == .appSwitcher)
            editor.remove(.source)
            precondition(Desk(defaults: testDefaults).ruleForEditor(.source).action == .unassigned)
            precondition(editor.ruleForEditor(.home).action == .videoFullscreen)
            let play = editor.ruleForEditor(ButtonID(page: 12, usage: 0x41))
            precondition(play.action == .youtubePlayPause && play.keyboardStroke == nil)
            precondition(play.action.keyCode == UInt16(kVK_ANSI_K))
            precondition(Action.youtubeCaptions.keyCode == UInt16(kVK_ANSI_C))
            precondition(editor.ruleForEditor(ButtonID(page: 12, usage: 0xE9)).action == .volumeUp)
            precondition(editor.createPreset(name: "独立配置", copyCurrent: false))
            for key in model {
                editor.selectForEdit(key.id)
                precondition(editor.selection == key.id)
                precondition(editor.ruleForEditor(key.id).action == .unassigned)
                precondition(!editor.ruleForEditor(key.id).codexOnly)
                editor.update(key.id) {
                    $0.action = .shortcut
                    $0.keyCode = 36
                }
            }
            let stored = PresetLibrary.load(from: testDefaults)
            precondition(stored.active.rules.count == 15 && stored.active.rules.allSatisfy { $0.action == .shortcut && $0.keyCode == 36 })
            let first = stored.activeID
            editor.updateHomeSwitch {
                $0.enabled = false
                $0.secondID = first
            }
            let homeSettings = PresetLibrary.load(from: testDefaults).homeSwitch
            precondition(!homeSettings.enabled && homeSettings.destination(from: PresetLibrary.codingID) == first)
            precondition(homeSettings.destination(from: first) == PresetLibrary.codingID)
            precondition(editor.createPreset(name: "副本", copyCurrent: true))
            let second = editor.library.activeID
            editor.remove(.assistant)
            precondition(editor.rules.count == 14 && editor.ruleForEditor(.assistant).action == .unassigned)
            precondition(editor.renamePreset(to: "自定义视频"))
            editor.saveCurrentPreset()
            precondition(editor.status.render(.simplifiedChinese) == "已保存预设「自定义视频」")
            precondition(!editor.createPreset(name: "AGENT CODING", copyCurrent: true))
            let reopened = Desk(defaults: testDefaults)
            reopened.setActive(true)
            precondition(reopened.mappingRequested && !reopened.active)
            let waiting = Desk(defaults: testDefaults)
            precondition(waiting.mappingRequested && !waiting.active)
            precondition(reopened.status.key == "待机 · 等待遥控器连接")
            let lastUse = testDefaults.object(forKey: "lastRemoteActivity") as! Date
            waiting.pauseRemoteIfIdle(at: lastUse.addingTimeInterval(1_799))
            precondition(waiting.mappingRequested)
            waiting.pauseRemoteIfIdle(at: lastUse.addingTimeInterval(1_800))
            precondition(!waiting.mappingRequested && testDefaults.bool(forKey: "pausedForRemoteIdle"))
            precondition(!Desk(defaults: testDefaults).mappingRequested)
            waiting.setActive(true)
            precondition(waiting.mappingRequested && !testDefaults.bool(forKey: "pausedForRemoteIdle"))
            waiting.setActive(false)
            precondition(!Desk(defaults: testDefaults).mappingRequested)
            precondition(waiting.status.key == "遥控器未连接 · 可先配置按键")
            precondition(reopened.library.activeID == second && reopened.library.active.name == "自定义视频")
            reopened.switchPreset(to: first)
            precondition(reopened.rules.count == 15)
            reopened.switchPreset(to: second)
            reopened.deleteActivePreset()
            precondition(reopened.library.activeID == PresetLibrary.codingID)
            precondition(reopened.library.presets.allSatisfy { $0.id != second })
            precondition(reopened.ruleForEditor(legacy[1].id).action == .escape)
            reopened.switchPreset(to: first)
            reopened.deleteActivePreset()
            precondition(reopened.library.homeSwitch.secondID == PresetLibrary.videoID)
            var gesture = TapHoldPress()
            gesture.begin(at: 1)
            precondition(gesture.finish(at: 1.2, released: true) == .tap)
            gesture.begin(at: 2)
            precondition(gesture.finish(at: 2.2, released: false) == nil)
            precondition(gesture.finish(at: 2.6, released: false) == .hold)
            precondition(gesture.finish(at: 2.9, released: true) == nil)
            gesture.begin(at: 3)
            precondition(gesture.finish(at: 3.6, released: true) == .hold)
            gesture.begin(at: 4)
            gesture.cancel()
            precondition(gesture.finish(at: 4.7, released: true) == nil)
            var sourceGesture = TapHoldPress(delay: 1)
            sourceGesture.begin(at: 10)
            precondition(sourceGesture.finish(at: 10.99, released: false) == nil)
            precondition(sourceGesture.finish(at: 10.99, released: true) == .tap)
            sourceGesture.begin(at: 12)
            precondition(sourceGesture.finish(at: 13, released: false) == .hold)
            precondition(sourceGesture.finish(at: 13.2, released: true) == nil)
            precondition(RemoteHID.decode([10, 0]) == [.home])
            precondition(RemoteHID.decode([1, 0]) == [.power])
            testDefaults.removePersistentDomain(forName: suite)
            precondition(RemoteHID.decode([1, 7, 12]).map(\.usage) == [0x41, 0xE9])
            precondition(RemoteHID.decode([11, 0]).map(\.usage) == [0x224])
            precondition(RemoteHID.decode([0, 0]).isEmpty)
            precondition(RemoteHID.decode([2, 7, 12]).isEmpty)
            precondition(RemoteHID.decode([19, 255]).isEmpty)
            precondition(VoiceCapabilities([11, 1, 0, 3, 2, 0, 128])?.close(3) == [13, 3])
            precondition(VoiceCapabilities([11, 0, 4, 0, 1, 0, 134, 0, 20])?.open == [12, 0, 1])
            precondition(VoiceCapabilities([11, 0, 4, 0, 1, 0, 134]) == nil)
            precondition(VoiceCapabilities([11, 1, 0, 0, 0, 0, 128]) == nil)
            var decoder = ADPCM()
            precondition(decoder.decode([0x71][...]) == [11, 17])
            precondition(RemoteVoice.voiceButtonEdge([4, 3, 2, 22]) == true)
            precondition(RemoteVoice.voiceButtonEdge([0, 2]) == false)
            precondition(!RemoteVoice.shouldReleaseVoiceButton(heldFor: 70, capturing: true))
            precondition(RemoteVoice.shouldReleaseVoiceButton(heldFor: 45, capturing: false))
            precondition(RemoteVoice.voiceButtonEdge([4, 1, 2, 22]) == nil)
            precondition(RemoteVoice.voiceButtonEdge([0, 0]) == nil)
            let fnDown = Output.fnEvent(down: true)
            let fnUp = Output.fnEvent(down: false)
            precondition(fnDown?.type == .flagsChanged && fnUp?.type == .flagsChanged)
            precondition(fnDown?.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Function))
            precondition(fnDown?.flags.contains(.maskSecondaryFn) == true)
            precondition(fnUp?.flags.contains(.maskSecondaryFn) == false)
            precondition(Action.codexChat.isGlobal && Action.codexChat.chatTarget == .codex)
            precondition(Action.claudeChat.isGlobal && Action.claudeChat.chatTarget == .claude)
            precondition(Action.sessions.isGlobal && Action.sessions.keyCode == nil)
            precondition(ChatTarget.claude.identifiesComposer(["Write your prompt to Claude"]))
            precondition(ChatTarget.codex.identifiesComposer(["Ask Codex to do anything"]))
            precondition(!ChatTarget.codex.identifiesComposer(["Search chats", "Browser address"]))
            precondition(Output.mediaEvent(Action.volumeUp.mediaKey!, down: true) != nil)
            print("Pointer and scroll holds, keyboard down/repeat/up, app overrides, preset migration and copy, Switch Apps mapping, Home tap/hold, HID, Fn and ATVV passed")
            return
        }
        let app = NSApplication.shared
        let delegate = DeskDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
