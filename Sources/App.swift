import AppKit
import SwiftUI
import IOKit.hid
import Carbon
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
    @Published var active = false
    @Published private(set) var pointerModeActive = false
    @Published var outputAllowed = false
    @Published var capturing = false
    @Published var connected = 0
    @Published var voiceEnabled = false
    @Published var voiceStatus = "语音已关闭"
    @Published var status = "按一下遥控器，查看 Mac 收到的按键"
    @Published var transcript = ""
    @Published var locale = "zh-CN" {
        didSet { voice.locale = locale; defaults.set(locale, forKey: "locale") }
    }

    private static let isPreview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let store = defaults ?? (Self.isPreview ? UserDefaults(suiteName: "me.tianrun.remotedesk.preview")! : .standard)
        self.defaults = store
        library = PresetLibrary.load(from: store)
        library.save(to: store)
    }
    private let hid = RemoteHID()
    private let voice = RemoteVoice()
    private var shortcutMonitor: Any?
    private var initialized = false
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
    private enum VoiceMode { case disabled, keys, audio }
    private var voiceMode: VoiceMode = .disabled

    var voiceKeyUsesKeyboard: Bool {
        guard let action = library.active.rule(for: .assistant, appID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.action
        else { return false }
        return action != .voice && action != .suppress
    }

    func start() {
        guard !initialized else { return }
        initialized = true
        selection = .assistant
        locale = defaults.string(forKey: "locale") ?? "zh-CN"
        voice.locale = locale
        hid.onButton = { [weak self] button, down in self?.received(button, down: down) }
        hid.onReset = { [weak self] in self?.releaseFn() }
        hid.onStatus = { [weak self] count, seized, error in
            guard let self else { return }
            self.connected = count
            self.capturing = seized
            if error != 0 {
                self.status = String(format: "无法打开遥控器按键通道（%08X）", UInt32(bitPattern: error))
            }
        }
        voice.status = { [weak self] in self?.voiceStatus = $0 }
        voice.button = { [weak self] down in self?.received(.assistant, down: down) }
        voice.result = { [weak self] text, target in
            guard let self else { return }
            self.transcript = text
            if Output.insert(text, into: target) { self.voiceStatus = "听写已填入当前 Codex 输入框" }
            else { self.voiceStatus = "听写完成 · 可复制文字到 Codex" }
        }
        if Self.isPreview { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cancelUsagePress()
            self?.releaseHeldOutputs()
            self?.appSwitcher.dismiss()
            self?.refreshVoiceMode()
        }
        hid.start()
        if ProcessInfo.processInfo.arguments.contains("--enable-mapping") { setActive(true) }
    }

    func stop() {
        sessionObserver?.invalidate()
        resetPointerMode(showConfirmation: false)
        releaseHeldOutputs()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        appSwitcher.dismiss()
        cancelHomePress()
        finishShortcut()
        voice.disable()
        hid.stop()
    }

    func setActive(_ value: Bool) {
        resetPointerMode()
        releaseHeldOutputs()
        appSwitcher.dismiss()
        cancelHomePress()
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
        hid.setExclusive(value && !learning)
        refreshVoiceMode()
        if value && !capturing && connected > 0 {
            status = "未取得遥控器独占控制；已保留原按键行为"
        } else if value && !Output.canPost {
            status = "发送快捷键需要辅助功能权限"
        } else {
            status = value ? "改键已启用" : "改键已暂停，可继续测试原始按键"
        }
    }

    func learn() {
        resetPointerMode()
        releaseHeldOutputs()
        appSwitcher.dismiss()
        cancelHomePress()
        finishShortcut()
        learning.toggle()
        hid.setExclusive(active && !learning)
        refreshVoiceMode()
        status = learning ? "现在按一下要配置的遥控器按键" : "已退出按键学习"
    }

    func addLast() {
        if let lastButton { selectOrAdd(lastButton) }
    }

    private func received(_ button: ButtonID, down: Bool) {
        if !down {
            pressedButtons.remove(button)
            pointerMode.release(button)
            releaseHeldOutput(button)
            if fnButtons.remove(button) != nil, fnButtons.isEmpty { _ = Output.postFn(down: false) }
            if button == .home { finishHomePress(released: true) }
            if button == .source { finishSourcePress(released: true) }
            if button == .volumeUp { finishUsagePress(released: true) }
            return
        }
        lastButton = button
        pressedButtons.insert(button)
        if ProcessInfo.processInfo.arguments.contains("--diagnostics") {
            NSLog("%@ received HID %@", appDisplayName, button.label)
        }
        if learning {
            learning = false
            selectOrAdd(button)
            hid.setExclusive(active)
            refreshVoiceMode()
            return
        }
        guard active, (capturing || button == .assistant), !recordingShortcut, !IsSecureEventInputEnabled() else { return }
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
        showBanner(["正在读取 Codex 用量…"], duration: 7)
        CodexUsage.fetch { [weak self] windows in
            guard let self else { return }
            self.usageLoading = false
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == originPID,
                  !IsSecureEventInputEnabled() else { return }
            let lines = windows?.map(\.description) ?? ["暂时读不到用量，可在 Codex 设置中查看。"]
            self.showBanner(["Codex 用量"] + lines, duration: 5)
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

    private func resetPointerMode(showConfirmation: Bool = true) {
        cancelUsagePress()
        cancelSourcePress()
        guard pointerModeActive || !showConfirmation else { return }
        pointerMode.end(showConfirmation: showConfirmation)
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
        case .fn:
            if !fnButtons.isEmpty || Output.postFn(down: true) {
                fnButtons.insert(button)
            } else {
                status = "未发送 Fn · 请检查辅助功能权限"
            }
        case .voice: voice.toggle()
        case .suppress, .unassigned: break
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
            showPresetBanner(library.active.name)
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
        showBanner(["已切换到 \(name)"], duration: 1.25)
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
        resetPointerMode()
        releaseHeldOutputs()
        cancelHomePress()
        appSwitcher.dismiss()
        pressedButtons.removeAll()
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
        let rule = editingAppID.isEmpty ? rules.first { $0.id == id }
            : library.active.rule(for: id, appID: editingAppID)
        return rule ?? BindingRule(id: id, name: id.label, action: .unassigned)
    }

    func selectMappingApp(_ id: String) {
        finishShortcut()
        editingAppID = id
    }

    func addMappingApp() {
        guard let window = NSApp.keyWindow else { return }
        let picker = NSOpenPanel()
        picker.title = "选择要单独改键的应用"
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
        let rule = ruleForEditor(id)
        return rule.action == .shortcut ? Self.shortcutLabel(rule) : rule.action.title
    }

    private func selectOrAdd(_ button: ButtonID) {
        selectForEdit(button)
        status = "已识别 \(button.label)，可以编辑动作"
    }

    func remove(_ id: ButtonID) {
        finishShortcut()
        update(id) { $0.action = .unassigned }
    }

    func saveCurrentPreset() {
        library.save(to: defaults)
        status = "已保存预设「\(library.active.name)」"
    }

    func switchPreset(to id: String) {
        guard library.activeID != id, let target = library.presets.first(where: { $0.id == id }) else { return }
        finishPresetSwitch(id, name: target.name)
    }

    @discardableResult
    func createPreset(name: String, copyCurrent: Bool) -> Bool {
        guard let name = availableName(name) else { return false }
        let preset = MappingPreset(id: UUID().uuidString, name: name, isBuiltIn: false,
                                   rules: copyCurrent ? rules : [],
                                   appRules: copyCurrent ? library.active.appRules : nil)
        var edited = library
        edited.presets.append(preset)
        finishPresetSwitch(preset.id, name: name, replacing: edited)
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
        finishPresetSwitch(next.id, name: next.name, replacing: edited)
    }

    private func availableName(_ draft: String, excluding id: String? = nil) -> String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !library.presets.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        return name
    }

    private func finishPresetSwitch(_ id: String, name: String, replacing replacement: PresetLibrary? = nil) {
        finishShortcut()
        if learning { learn() }
        releaseFn()
        Output.resetNavigation()
        var edited = replacement ?? library
        edited.activeID = id
        library = edited
        status = "已切换到 \(name)"
        refreshVoiceMode()
    }

    func promptPresetName(copyCurrent: Bool = true, renaming: Bool = false) {
        guard let window = NSApp.keyWindow else { return }
        let originalName = library.active.name
        let alert = NSAlert()
        alert.messageText = renaming ? "重命名预设" : (copyCurrent ? "另存为预设" : "新建空白预设")
        alert.informativeText = copyCurrent && !renaming ? "复制当前的整套按键配置。" : "输入这套按键配置的名称。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = renaming ? originalName : (copyCurrent ? "\(originalName) 副本" : "")
        input.placeholderString = "预设名称"
        input.setAccessibilityLabel("预设名称")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let ok = renaming ? self.renamePreset(to: input.stringValue)
                : self.createPreset(name: input.stringValue, copyCurrent: copyCurrent)
            if !ok {
                let error = NSAlert()
                error.messageText = "这个名称无法保存"
                error.informativeText = "请输入非空、且与现有预设不重复的名称。"
                error.beginSheetModal(for: window)
            }
        }
    }

    func confirmDeletePreset() {
        guard !library.active.isBuiltIn, let window = NSApp.keyWindow else { return }
        let id = library.activeID
        let alert = NSAlert()
        alert.messageText = "删除「\(library.active.name)」？"
        alert.informativeText = "这套预设的按键配置将被删除。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
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
        if status.hasPrefix("已保存预设") { status = "按键已更新" }
        refreshVoiceMode()
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

    func enableVoice(_ value: Bool) {
        voiceEnabled = value
        refreshVoiceMode()
    }

    private func refreshVoiceMode() {
        let requested: VoiceMode
        if Self.isPreview { requested = .disabled }
        else if learning || (active && voiceKeyUsesKeyboard) { requested = .keys }
        else if active, library.active.rule(for: .assistant, appID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.action == .suppress {
            requested = .disabled
        }
        else { requested = voiceEnabled ? .audio : .disabled }
        guard voiceMode != requested else { return }
        voice.disable()
        voiceMode = requested
        if requested != .disabled { voice.enable(keysOnly: requested == .keys) }
    }

    func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
        voiceStatus = "已复制听写文字"
    }

    static func shortcutLabel(_ rule: BindingRule) -> String {
        let mask = NSEvent.ModifierFlags(rawValue: UInt(rule.modifiers))
        var prefix = ""
        for (flag, symbol) in [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] where mask.contains(flag) {
            prefix += symbol
        }
        let named: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "空格", 51: "Delete", 53: "Esc", 76: "Enter", 117: "Forward Delete",
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
        return prefix + (Int(rule.keyCode) < ansi.count ? ansi[Int(rule.keyCode)] : "键码 \(rule.keyCode)")
    }
}

struct DeskView: View {
    @ObservedObject var desk: Desk
    private let accent = Color(red: 0.26, green: 0.48, blue: 0.92)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            presetBar
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(minWidth: 325, idealWidth: 390, maxWidth: 420)
                Divider()
                details
            }
            Divider()
            footer
        }
        .frame(minWidth: 790, idealWidth: 920, minHeight: 585, idealHeight: 680)
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(appDisplayName).font(.system(size: 25, weight: .semibold))
                HStack(spacing: 6) {
                    Circle().fill(desk.connected > 0 ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(desk.connected > 0 ? "Chromecast Remote 已连接" : "等待 Chromecast Remote 连接")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                GridRow(alignment: .center) {
                    Toggle("启用改键", isOn: Binding(get: { desk.active }, set: desk.setActive))
                        .toggleStyle(.switch)
                        .fixedSize()
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 24)
                    Toggle(isOn: Binding(get: { desk.pointerModeActive }, set: { enabled in
                        if enabled != desk.pointerModeActive { desk.togglePointerMode() }
                    })) {
                        Label("飞鼠模式", systemImage: "cursorarrow")
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(!desk.active || !desk.capturing || !desk.outputAllowed)
                    .help("用遥控器方向键移动指针，按确定点击")
                }
                GridRow {
                    Color.clear.frame(width: 0, height: 0)
                    Color.clear.frame(width: 0, height: 0)
                    Text("信源键长按 1 秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var presetBar: some View {
        HStack(spacing: 11) {
            Picker("当前预设", selection: Binding(get: { desk.library.activeID }, set: desk.switchPreset(to:))) {
                ForEach(desk.library.presets) { preset in Text(preset.name).tag(preset.id) }
            }
            .frame(maxWidth: 260)
            Button("保存", action: desk.saveCurrentPreset)
                .buttonStyle(.borderedProminent)
                .help("保存当前预设的全部按键配置")
            Button("另存为…") { desk.promptPresetName() }
                .help("把当前一整套改键复制到新的预设")
            Menu {
                Button("新建空白预设…") { desk.promptPresetName(copyCurrent: false) }
                Button("重命名…") { desk.promptPresetName(renaming: true) }
                    .disabled(desk.library.active.isBuiltIn)
                Divider()
                Button("删除此预设…", role: .destructive) { desk.confirmDeletePreset() }
                    .disabled(desk.library.active.isBuiltIn)
            } label: {
                Label("管理预设", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Text(desk.status.hasPrefix("已保存预设") ? desk.status : "改键自动保存到当前预设")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 23)
        .padding(.vertical, 10)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chromecast 遥控器").font(.headline)
                    Text(desk.learning ? "按下实体键以定位" : "点选图上的按键进行编辑")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(desk.learning ? "取消" : "学习按键", action: desk.learn)
                    .buttonStyle(.bordered)
            }
            RemotePicture(desk: desk, accent: accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.68))
                }
            HStack {
                Spacer()
                Text("\(PhysicalKey.keys.count) 个按键").font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(17)
        .background(accent.opacity(0.06))
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 10) {
                    Picker("按应用改键", selection: Binding(get: { desk.editingAppID }, set: desk.selectMappingApp)) {
                        Text("默认映射").tag("")
                        ForEach(desk.library.apps) { Text($0.name).tag($0.id) }
                    }
                    Button("添加应用…", action: desk.addMappingApp).fixedSize()
                }
                if let id = desk.selection {
                    let rule = desk.ruleForEditor(id)
                    let physical = PhysicalKey.keys.first { $0.id == id }
                    let scoped = !desk.editingAppID.isEmpty
                    let overridden = scoped && desk.library.active.override(for: id, appID: desk.editingAppID) != nil
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(id.label).font(.system(size: 24, weight: .semibold))
                                Text(scoped && !overridden ? "沿用默认 · \(desk.mappingTitle(id))" : desk.mappingTitle(id))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if overridden {
                                Button("恢复默认") { desk.remove(id) }.buttonStyle(.borderless)
                            } else if scoped && rule.action == .shortcut {
                                Button("自定义快捷键") { desk.update(id) { $0.action = .shortcut } }
                                    .buttonStyle(.borderless)
                            } else if !scoped && rule.action != .unassigned {
                                Button("清除映射") { desk.remove(id) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 15, verticalSpacing: 10) {
                            if rule.action != .unassigned && (!scoped || overridden) {
                                GridRow {
                                    Text("显示名称")
                                    TextField("显示名称", text: Binding(get: { rule.name }, set: { value in
                                        desk.update(id) { $0.name = value }
                                    })).labelsHidden()
                                }
                            }
                            GridRow {
                                Text("按下时")
                                Picker("按下时", selection: Binding(get: { scoped && !overridden ? .unassigned : rule.action }, set: { value in
                                    desk.finishShortcut()
                                    desk.update(id) { $0.action = value }
                                })) {
                                    ForEach(Action.allCases) { action in
                                        Text(scoped && action == .unassigned ? "沿用默认映射" : action.title).tag(action)
                                    }
                                }
                                    .labelsHidden()
                            }
                            if rule.action == .shortcut && (!scoped || overridden) {
                                GridRow {
                                    Text("快捷键")
                                    HStack {
                                        Button(desk.recordingShortcut ? "按下键盘快捷键…" : Desk.shortcutLabel(rule)) {
                                            desk.recordShortcut(id)
                                        }
                                        if desk.recordingShortcut { Button("取消", action: desk.finishShortcut) }
                                    }
                                }
                            }
                            if !scoped && !rule.action.isGlobal && rule.action != .suppress && rule.action != .unassigned {
                                GridRow {
                                    Color.clear.frame(width: 1, height: 1)
                                    Toggle(rule.isChatReturn ? "仅在 Codex 或 Claude 位于前台时执行" : "仅在 Codex 位于前台时执行", isOn: Binding(get: { rule.codexOnly }, set: { value in
                                        desk.update(id) { $0.codexOnly = value }
                                    }))
                                }
                            }
                        }
                        if rule.action == .sessions {
                            Text("在 Codex 或 Claude 中打开会话列表，用 ↑／↓ 选择，按确定进入。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .cycleCodex {
                            Text("短按轮换最近 3 个 Codex 会话，并尝试聚焦输入框。记录不足时使用 Codex 自带的最近会话位。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .nextCodexSession || rule.action == .previousCodexSession {
                            Text("按 Codex 左侧列表顺序移动，到首尾停止。切换后尝试聚焦对话输入框。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .nextGrokBotSession || rule.action == .previousGrokBotSession {
                            Text("按 Grok Bot 左栏顺序切换会话，到首尾停止。切换后聚焦对话输入框。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if id == .volumeUp && rule.action == .previousCodexSession {
                            Text("在 Codex 前台，短按往左栏上一项，按住 1 秒显示 Codex 用量。")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("查看 Codex 用量", action: desk.showCodexUsage)
                        }
                        if rule.action == .cycleAgents {
                            Text("在 Codex 与 Claude 间来回切换，进入各自当前会话的输入框。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .appSwitcher {
                            Text(id == .source
                                ? "短按切换应用，按住 1 秒进入或退出飞鼠模式。应用列表里用方向键选择，按确定打开。"
                                : "列出正在运行的 App。用方向键选择，按确定打开，按返回关闭。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if (id == .source && rule.action == .appSwitcher) || rule.action == .pointerMode {
                            Text("飞鼠模式下，方向键移动指针，确定点按，音量键按住连续滚动，返回退出。也可以在窗口顶部开关。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.keyboardStroke != nil {
                            Text("短按发送一次，长按按 Mac 的键盘设置连发。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .volumeUp || rule.action == .volumeDown {
                            Text("短按调节一次音量，按住连续调节。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action.chatTarget != nil {
                            Button("试开对话框") { desk.openConversation(rule.action) }
                        }
                        if physical?.mayUseInfrared == true {
                            Label("如果这颗键只向电视发红外信号，Mac 收不到。可用「学习按键」确认。", systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if rule.action == .fn {
                            Text("发送 Fn，保留按下与松开的时长。微信语音输入法会按现有设置处理双击和长按。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(15).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                    if id == .home { homeSwitchCard }
                }
                voiceCard
            }.padding(20)
        }
    }

    private var homeSwitchCard: some View {
        let settings = desk.library.homeSwitch
        return VStack(alignment: .leading, spacing: 10) {
            Toggle("长按主页键切换预设", isOn: Binding(get: { settings.enabled }, set: { enabled in
                desk.updateHomeSwitch { $0.enabled = enabled }
            })).toggleStyle(.switch)
            if settings.enabled {
                if desk.ruleForEditor(.home).action == .fn || desk.ruleForEditor(.home).keyboardStroke != nil {
                    Text("主页键映射到键盘时，长按用于发送该键。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker("预设一", selection: Binding(get: { settings.firstID }, set: { id in
                    desk.updateHomeSwitch { $0.firstID = id }
                })) {
                    ForEach(desk.library.presets.filter { $0.id != settings.secondID }) { Text($0.name).tag($0.id) }
                }
                Picker("预设二", selection: Binding(get: { settings.secondID }, set: { id in
                    desk.updateHomeSwitch { $0.secondID = id }
                })) {
                    ForEach(desk.library.presets.filter { $0.id != settings.firstID }) { Text($0.name).tag($0.id) }
                }
            }
        }
        .padding(15).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label(desk.active && desk.voiceKeyUsesKeyboard ? "语音键信号" : "遥控器麦克风", systemImage: "mic")
                    .font(.title3.weight(.semibold))
                Spacer()
                if !desk.active || !desk.voiceKeyUsesKeyboard {
                    Toggle("启用听写", isOn: Binding(get: { desk.voiceEnabled }, set: desk.enableVoice)).toggleStyle(.switch)
                }
            }
            Text(desk.voiceStatus).font(.callout).foregroundStyle(.secondary)
            if desk.active && desk.voiceKeyUsesKeyboard {
                Text("试按大圆环下方第一排右侧的深色语音键。这里会显示收到的按下和松开。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Picker("语言", selection: $desk.locale) {
                        Text("中文（普通话）").tag("zh-CN")
                        Text("English (US)").tag("en-US")
                    }.fixedSize()
                    if desk.voiceEnabled {
                        Button("打开 Codex", action: Output.activate)
                    }
                }
                if !desk.transcript.isEmpty {
                    Text(desk.transcript).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("复制文字", action: desk.copyTranscript)
                } else {
                    Text("按遥控器助理键说话。识别结果可填入已聚焦的 Codex 输入框，由你确认发送。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }.padding(15).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footerStatus: String {
        guard desk.active, desk.capturing, !desk.learning else { return desk.status }
        guard desk.outputAllowed else { return "已接管遥控器 · 发送快捷键需要辅助功能权限" }
        if desk.pointerModeActive { return "飞鼠模式 · 按返回退出" }
        if desk.status.hasPrefix("已聚焦") || desk.status.hasPrefix("已打开") || desk.status.hasPrefix("没有找到")
            || desk.status.hasPrefix("无法打开") || desk.status.contains("会话选择")
            || desk.status.hasPrefix("请先打开") || desk.status.contains("Codex 会话")
            || desk.status.hasPrefix("Codex 最近会话位") { return desk.status }
        return "改键运行中 · 未配置的遥控器按键暂停"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(desk.lastButton.map { "最近按键  " + $0.label } ?? "尚未收到按键")
                    .font(.callout.weight(.medium))
                if desk.lastButton != nil { Button("配置此键", action: desk.addLast).buttonStyle(.link) }
                Spacer()
                Button("输入监控", action: desk.grantInput)
                Button("辅助功能", action: desk.grantOutput)
            }
            Text(footerStatus)
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 19).padding(.vertical, 11)
    }
}

final class DeskDelegate: NSObject, NSApplicationDelegate {
    let desk = Desk()
    private var window: NSWindow?
    private var menuItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        desk.start()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window?.minSize = NSSize(width: 790, height: 585)
        window?.isReleasedWhenClosed = false
        window?.title = appDisplayName
        window?.contentView = NSHostingView(rootView: DeskView(desk: desk))
        window?.center()
        let systemMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "退出 \(appDisplayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        systemMenu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: "编辑")
        editItem.submenu?.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editItem.submenu?.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editItem.submenu?.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu?.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        systemMenu.addItem(editItem)
        NSApp.mainMenu = systemMenu
        let tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        tray.button?.image = NSImage(systemSymbolName: "appletvremote.gen4", accessibilityDescription: appDisplayName)
        let menu = NSMenu()
        let show = NSMenuItem(title: "打开 \(appDisplayName)", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let pause = NSMenuItem(title: "暂停改键", action: #selector(pauseMapping), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 \(appDisplayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        tray.menu = menu
        menuItem = tray
        showWindow()
    }

    @objc func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func pauseMapping() { desk.setActive(false) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) { desk.refreshPermissions() }

    func applicationWillTerminate(_ notification: Notification) { desk.stop() }
}

@main struct RemoteDesk {
    static func main() {
        let flags = ProcessInfo.processInfo.arguments
        if flags.contains("--self-test") {
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
            precondition(initial.presets.first { $0.id == PresetLibrary.videoID }?.rule(for: .home, appID: nil)?.action == .activate)
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
            precondition(editor.ruleForEditor(.home).action == .activate)
            precondition(editor.ruleForEditor(ButtonID(page: 12, usage: 0x41)).keyCode == UInt16(kVK_Space))
            precondition(editor.ruleForEditor(ButtonID(page: 12, usage: 0xE9)).action == .volumeUp)
            precondition(editor.createPreset(name: "独立配置", copyCurrent: false))
            for key in model {
                editor.selectForEdit(key.id)
                precondition(editor.selection == key.id)
                precondition(editor.ruleForEditor(key.id).action == .unassigned)
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
            precondition(editor.status == "已保存预设「自定义视频」")
            precondition(!editor.createPreset(name: "AGENT CODING", copyCurrent: true))
            let reopened = Desk(defaults: testDefaults)
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
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
