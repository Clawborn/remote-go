import AppKit
import IOKit.hid
import IOKit.hidsystem
import Carbon
import SwiftUI

struct ButtonID: Hashable, Codable {
    let page: UInt32
    let usage: UInt32

    static let assistant = ButtonID(page: 0xFF00, usage: 1)
    static let home = ButtonID(page: 12, usage: 0x223)
    static let source = ButtonID(page: 12, usage: 0x89)
    static let back = ButtonID(page: 12, usage: 0x224)
    static let volumeUp = ButtonID(page: 12, usage: 0xE9)

    var label: String {
        switch (page, usage) {
        case (0xFF00, 1): return "语音键"
        case (12, 0x41): return "确定"
        case (12, 0x42): return "↑"
        case (12, 0x43): return "↓"
        case (12, 0x44): return "←"
        case (12, 0x45): return "→"
        case (12, 0x223): return "主页"
        case (12, 0x224): return "返回"
        case (12, 0xE9): return "音量 +"
        case (12, 0xEA): return "音量 −"
        case (12, 0xE2): return "静音"
        case (12, 0x77): return "YouTube"
        case (12, 0x78): return "Netflix"
        case (12, 0x19E): return "电源"
        case (12, 0x89): return "信源"
        default: return String(format: "按键 %02X:%02X", page, usage)
        }
    }
}

struct BindingRule: Codable, Identifiable, Equatable {
    var id: ButtonID
    var name: String
    var action: Action
    var keyCode: UInt16 = 53
    var modifiers: UInt64 = 0
    var codexOnly = true

    var keyboardStroke: (key: UInt16, flags: UInt64)? {
        switch action {
        case .shortcut: return (keyCode, modifiers)
        case .up, .down, .left, .right, .pageUp, .pageDown, .escape:
            return action.keyCode.map { ($0, action.flags) }
        default: return nil
        }
    }

    var isChatReturn: Bool {
        id == ButtonID(page: 12, usage: 0x41) && action == .shortcut && keyCode == UInt16(kVK_Return) && modifiers == 0
    }

    func applies(to appID: String?) -> Bool {
        !codexOnly || action.isGlobal || appID == ChatTarget.codex.rawValue
            || (isChatReturn && appID == ChatTarget.claude.rawValue)
    }
}

enum Action: String, Codable, CaseIterable, Identifiable {
    case unassigned = "未设置动作"
    case fn = "Fn / Codex 听写"
    case shortcut = "键盘快捷键", activate = "打开 Codex", voice = "开始／结束遥控器听写"
    case codexChat = "打开 Codex 对话框", claudeChat = "打开 Claude 对话框"
    case sessions = "选择会话"
    case cycleCodex = "轮换最近 3 个 Codex 会话"
    case nextCodexSession = "下一个 Codex 会话"
    case previousCodexSession = "上一个 Codex 会话"
    case nextGrokBotSession = "下一个 Grok Bot 会话"
    case previousGrokBotSession = "上一个 Grok Bot 会话"
    case cycleAgents = "轮换 Codex 和 Claude"
    case appSwitcher = "切换应用"
    case pointerMode = "切换鼠标模式"
    case volumeUp = "系统音量＋", volumeDown = "系统音量－", mute = "系统静音"
    case preview = "打开／切换内置浏览器", reload = "刷新网页预览"
    case annotate = "切换网页标注模式"
    case up = "向上", down = "向下", left = "向左", right = "向右"
    case pageUp = "向上翻页", pageDown = "向下翻页", escape = "Esc / 返回", suppress = "停用按键"
    var id: Self { self }
    var title: String {
        switch self {
        case .fn: return "Fn"
        case .pointerMode: return "切换飞鼠模式"
        default: return rawValue
        }
    }
    var chatTarget: ChatTarget? {
        switch self {
        case .codexChat: .codex
        case .claudeChat: .claude
        default: nil
        }
    }
    var isGlobal: Bool {
        self == .activate || self == .fn || self == .sessions || self == .cycleCodex || self == .cycleAgents
            || self == .appSwitcher || self == .pointerMode
            || chatTarget != nil || mediaKey != nil
    }

    var mediaKey: Int? {
        switch self {
        case .volumeUp: Int(NX_KEYTYPE_SOUND_UP)
        case .volumeDown: Int(NX_KEYTYPE_SOUND_DOWN)
        case .mute: Int(NX_KEYTYPE_MUTE)
        default: nil
        }
    }

    var keyCode: UInt16? {
        switch self {
        case .up: 126
        case .down: 125
        case .left: 123
        case .right: 124
        case .pageUp: 116
        case .pageDown: 121
        case .escape: 53
        case .preview: 11
        case .reload: 15
        case .annotate: 47
        default: nil
        }
    }

    var flags: UInt64 {
        switch self {
        case .preview, .annotate: CGEventFlags([.maskCommand, .maskShift]).rawValue
        case .reload: CGEventFlags.maskCommand.rawValue
        default: 0
        }
    }
}

final class RemoteHID {
    static let match = ["VendorID": 0x18d1, "ProductID": 0x9450]
    var onButton: ((ButtonID, Bool) -> Void)?
    var onReset: (() -> Void)?
    var onStatus: ((Int, Bool, IOReturn) -> Void)?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var devices: [IOHIDDevice] = []
    private var exclusive: Set<IOHIDDevice> = []
    private var held: [IOHIDDevice: Set<ButtonID>] = [:]
    private var buffers: [IOHIDDevice: UnsafeMutablePointer<UInt8>] = [:]
    private var capture = false
    private var started = false
    private var lastError: IOReturn = 0

    func start() {
        guard !started else { return }
        started = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(manager, Self.match as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { pointer, _, _, device in
            guard let pointer else { return }
            Unmanaged<RemoteHID>.fromOpaque(pointer).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { pointer, _, _, device in
            guard let pointer else { return }
            Unmanaged<RemoteHID>.fromOpaque(pointer).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    func setExclusive(_ enabled: Bool) {
        capture = enabled
        lastError = 0
        for device in devices { reopen(device) }
        publish()
    }

    func stop() {
        guard started else { return }
        for device in devices { detach(device) }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        started = false
    }

    private func attach(_ device: IOHIDDevice) {
        guard !devices.contains(device) else { return }
        devices.append(device)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        buffers[device] = buffer
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { pointer, result, sender, type, reportID, bytes, length in
            guard let pointer, let sender, result == kIOReturnSuccess, type == kIOHIDReportTypeInput,
                  reportID == 1, length == 2 || length == 3 else { return }
            let remote = Unmanaged<RemoteHID>.fromOpaque(pointer).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            remote.receive(Array(UnsafeBufferPointer(start: bytes, count: length)), from: device)
        }, Unmanaged.passUnretained(self).toOpaque())
        lastError = 0
        reopen(device)
        publish()
    }

    private func detach(_ device: IOHIDDevice) {
        onReset?()
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, 0)
        devices.removeAll { $0 == device }
        exclusive.remove(device)
        held.removeValue(forKey: device)
        buffers.removeValue(forKey: device)?.deallocate()
        publish()
    }

    private func reopen(_ device: IOHIDDevice) {
        onReset?()
        IOHIDDeviceClose(device, 0)
        exclusive.remove(device)
        held[device] = []
        let result = IOHIDDeviceOpen(device, capture ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : 0)
        if result == kIOReturnSuccess {
            if capture { exclusive.insert(device) }
        } else {
            lastError = result
            if capture { IOHIDDeviceOpen(device, 0) }
        }
    }

    private func publish() {
        onStatus?(devices.count, capture && !devices.isEmpty && exclusive.count == devices.count, lastError)
    }

    // Report 1 has two 8-bit array selectors. The indexes follow the
    // Consumer Page usage list in this device's HID report descriptor.
    static func decode(_ report: [UInt8]) -> [ButtonID] {
        let usages: [UInt32] = [0, 0x19E, 0xCD, 0x42, 0x43, 0x44, 0x45, 0x41, 0xE2,
                                0x221, 0x223, 0x224, 0xE9, 0xEA, 0x77, 0x78, 0x79, 0x89]
        guard report.count == 2 || (report.count == 3 && report.first == 1) else { return [] }
        return report.suffix(2).compactMap { selector in
            let index = Int(selector)
            guard index > 0, index < usages.count else { return nil }
            return ButtonID(page: 12, usage: usages[index])
        }
    }

    private func receive(_ report: [UInt8], from device: IOHIDDevice) {
        guard let before = held[device] else { return }
        let buttons = Self.decode(report)
        let current = Set(buttons)
        held[device] = current
        for button in before.subtracting(current) { onButton?(button, false) }
        var emitted = before
        for button in buttons where emitted.insert(button).inserted { onButton?(button, true) }
    }

}

enum ChatTarget: String {
    case codex = "com.openai.codex"
    case claude = "com.anthropic.claudefordesktop"
    case grokBot = "com.anysphere.sand"

    var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .grokBot: "Grok Bot"
        }
    }

    func identifiesComposer(_ descriptors: [String]) -> Bool {
        let names = descriptors.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        if self == .grokBot {
            return names.contains { $0 == "prompt" || $0 == "提示词" || $0 == "提示詞" }
        }
        let phrases = self == .claude
            ? ["write your prompt to claude", "write a message", "reply to claude", "向 claude", "写一条消息", "输入消息"]
            : ["ask codex", "work with codex", "describe your task", "describe your goal",
               "prompt-textarea", "add a follow-up", "type a message", "message input", "steer the response",
               "询问 codex", "问问 codex", "与 codex", "让 codex", "描述你的任务", "描述你的目标",
               "输入消息", "发送消息", "追加指令", "追加请求"]
        return names.contains { name in phrases.contains { name.contains($0) } }
    }
}

enum Output {
    static let appID = ChatTarget.codex.rawValue
    private static var requestedChat = UUID()
    private static var sessionSearchPID: pid_t?
    private static let sessionHistoryKey = "recentlyOpenedCodexSessionIDs"
    private static var codexHistory = CodexSessionHistory(
        recent: (UserDefaults.standard.stringArray(forKey: sessionHistoryKey) ?? []).filter { UUID(uuidString: $0) != nil }
    )
    private static var accessibilityPID: pid_t?
    static var isCodex: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == appID }
    static var canPost: Bool { CGPreflightPostEventAccess() && AXIsProcessTrusted() }

    static func activate() {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    static func openChat(_ target: ChatTarget, report: @escaping (String) -> Void) {
        let request = UUID()
        requestedChat = request
        sessionSearchPID = nil
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.rawValue) else {
            report("没有找到 \(target.name) 桌面版")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                guard requestedChat == request else { return }
                guard let app, error == nil else {
                    report("无法打开 \(target.name)")
                    return
                }
                Self.focusChat(target, pid: app.processIdentifier, request: request, report: report)
            }
        }
    }

    static func resetNavigation() {
        requestedChat = UUID()
        sessionSearchPID = nil
        codexHistory.cancelSelection()
    }

    static func observeCodexSession() {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == appID,
              AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let thread = codexSessionID(pid: front.processIdentifier) else { return }
        let before = codexHistory.recent
        codexHistory.observe(thread)
        if before != codexHistory.recent { UserDefaults.standard.set(codexHistory.recent, forKey: sessionHistoryKey) }
    }

    static func moveCodexSidebar(in direction: CodexSessionHistory.Direction, report: @escaping (String) -> Void) {
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == appID else {
            report("请先打开 Codex")
            return
        }
        guard canPost, !IsSecureEventInputEnabled() else {
            report("切换会话需要辅助功能权限")
            return
        }
        resetNavigation()
        let request = requestedChat
        let pid = front.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.10)
        let names: Set<String> = direction == .previous
            ? ["previous sidebar item", "上一个侧边栏项目", "上一個側邊欄項目"]
            : ["next sidebar item", "下一个侧边栏项目", "下一個側邊欄項目"]
        let entry = accessibilityElement(attribute(app, kAXMenuBarAttribute)).flatMap {
            findElement(in: $0, role: kAXMenuItemRole) { item in
                names.contains((attribute(item, kAXTitleAttribute) as? String ?? "").lowercased())
            }
        }
        guard frontIs(pid) else { return }
        let sent: Bool
        if let entry, attribute(entry, kAXEnabledAttribute) as? Bool != false,
           AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success {
            sent = true
        } else {
            let key = direction == .previous ? kVK_ANSI_LeftBracket : kVK_ANSI_RightBracket
            let flags = CGEventFlags([.maskCommand, .maskAlternate]).rawValue
            sent = press(UInt16(key), flags: flags)
        }
        guard sent else { report("无法发送 Codex 左栏快捷键"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            guard requestedChat == request, frontIs(pid) else { return }
            observeCodexSession()
            focusChat(.codex, pid: pid, request: request, switchCodexSurface: false, report: report)
        }
    }

    static func moveGrokBotSidebar(in direction: CodexSessionHistory.Direction, report: @escaping (String) -> Void) {
        let target = ChatTarget.grokBot
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == target.rawValue else {
            report("请先打开 Grok Bot")
            return
        }
        guard canPost, !IsSecureEventInputEnabled() else {
            report("切换会话需要辅助功能权限")
            return
        }
        resetNavigation()
        let request = requestedChat
        let pid = front.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = accessibilityElement(attribute(app, kAXFocusedWindowAttribute)),
              let list = findElement(in: window, role: kAXGroupRole, matches: {
                  hasLabel($0, among: ["bot list", "bot 列表", "bot 清單", "bot 清单"])
              }),
              let content = findElement(in: list, role: kAXListRole, matches: { _ in true }),
              let children = attribute(content, kAXChildrenAttribute) as? [AXUIElement] else {
            report("当前窗口未找到 Grok Bot 左栏")
            return
        }
        let rows = children.compactMap { child in
            findElement(in: child, role: kAXButtonRole, matches: { _ in true })
        }
        guard let current = currentGrokBotRow(in: window, rows: rows) else {
            report("请先在 Grok Bot 左栏打开一个会话")
            return
        }
        let next = current + direction.rawValue
        guard rows.indices.contains(next) else {
            report(direction == .previous ? "已到 Grok Bot 左栏第一项" : "已到 Grok Bot 左栏最后一项")
            return
        }
        guard frontIs(pid) else { return }
        let expectedTitle = grokBotRowTitle(rows[next])
        let canConfirmByTitle = expectedTitle != nil && rows.filter { grokBotRowTitle($0) == expectedTitle }.count == 1
        guard AXUIElementPerformAction(rows[next], kAXPressAction as CFString) == .success else {
            report("无法打开 Grok Bot 左栏会话")
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        func confirm() {
            guard requestedChat == request, frontIs(pid) else { return }
            if isCurrentGrokBotRow(rows[next]) || (canConfirmByTitle && grokBotChatTitle(window) == expectedTitle) {
                focusChat(target, pid: pid, request: request, report: report)
            } else if ProcessInfo.processInfo.systemUptime < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { confirm() }
            } else {
                report("未能确认 Grok Bot 已切换会话")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { confirm() }
    }

    private static func isCurrentGrokBotRow(_ row: AXUIElement) -> Bool {
        let current = attribute(row, "AXARIACurrent")
        return (current as? String).map { ["true", "page", "location"].contains($0.lowercased()) }
            ?? (current as? Bool == true)
    }

    private static func currentGrokBotRow(in window: AXUIElement, rows: [AXUIElement]) -> Int? {
        if let active = rows.firstIndex(where: isCurrentGrokBotRow) { return active }
        guard let title = grokBotChatTitle(window) else { return nil }
        let matches = rows.indices.filter { grokBotRowTitle(rows[$0]) == title || hasLabel(rows[$0], among: [title.lowercased()]) }
        return matches.count == 1 ? matches.first : nil
    }

    private static func grokBotChatTitle(_ window: AXUIElement) -> String? {
        let details = findElement(in: window, role: kAXButtonRole) {
            hasLabel($0, among: ["view chat details", "view conversation details", "查看对话详情", "查看對話詳情"])
        }
        guard let details,
              let heading = accessibilityElement(attribute(details, kAXParentAttribute)),
              attribute(heading, kAXRoleAttribute) as? String == kAXHeadingRole else { return nil }
        return labels(heading).first
    }

    private static func grokBotRowTitle(_ row: AXUIElement) -> String? {
        guard let children = attribute(row, kAXChildrenAttribute) as? [AXUIElement],
              let title = children.first(where: { attribute($0, kAXRoleAttribute) as? String == kAXStaticTextRole })
        else { return nil }
        return attribute(title, kAXValueAttribute) as? String ?? labels(title).first
    }

    static func cycleCodexSession(in direction: CodexSessionHistory.Direction, report: @escaping (String) -> Void) {
        guard canPost, !IsSecureEventInputEnabled() else {
            report("切换会话需要辅助功能权限")
            return
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID) else {
            report("没有找到 Codex 桌面版")
            return
        }
        observeCodexSession()
        let destination = codexHistory.next(in: direction)
        let request = UUID()
        requestedChat = request
        sessionSearchPID = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        report("正在切换 Codex 会话…")
        let onOpen: (NSRunningApplication?, Error?) -> Void = { app, error in
            DispatchQueue.main.async {
                guard requestedChat == request else { return }
                guard let app, error == nil else {
                    codexHistory.cancelSelection()
                    report("无法打开 Codex 会话")
                    return
                }
                switch destination {
                case .thread(let expected):
                    focusChat(.codex, pid: app.processIdentifier, request: request, expectedCodexSession: expected, report: report)
                case .slot(let slot):
                    openRecentCodexSlot(slot, pid: app.processIdentifier, request: request, report: report)
                }
            }
        }
        switch destination {
        case .thread(let id):
            guard let url = URL(string: "codex://threads/\(id)") else { return }
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration, completionHandler: onOpen)
        case .slot:
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: onOpen)
        }
    }

    private static func openRecentCodexSlot(_ slot: Int, pid: pid_t, request: UUID,
                                           report: @escaping (String) -> Void) {
        let keys = [UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3)]
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        func attempt() {
            guard requestedChat == request else { return }
            if frontIs(pid) {
                // The documented recent slots belong to the Codex surface.
                _ = press(UInt16(kVK_ANSI_3), flags: CGEventFlags.maskControl.rawValue)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                    guard requestedChat == request, frontIs(pid) else { return }
                    let modifiers = CGEventFlags([.maskCommand, .maskAlternate]).rawValue
                    guard press(keys[slot - 1], flags: modifiers) else {
                        report("无法发送 Codex 最近会话快捷键")
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        focusChat(.codex, pid: pid, request: request) { message in
                            report(message.hasPrefix("已聚焦") ? "Codex 最近会话位 \(slot) · \(message)" : message)
                        }
                    }
                }
            } else if ProcessInfo.processInfo.systemUptime < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { attempt() }
            } else {
                report("无法将 Codex 切到前台")
            }
        }
        attempt()
    }

    static func codexSessionID(in url: URL) -> String? {
        guard (url.scheme == "app" && url.host == "-") || url.scheme == "file"
                || (url.scheme == "codex" && url.host == "threads") else { return nil }
        var routes = [url.path]
        if let fragment = url.fragment, fragment.hasPrefix("/") {
            routes.append(String(fragment.split(separator: "?", maxSplits: 1).first ?? ""))
        }
        if url.scheme == "codex", url.host == "threads" {
            routes.append("/local" + url.path)
        }
        for route in routes {
            let components = route.split(separator: "/")
            if components.count == 2, components[0] == "local", let id = UUID(uuidString: String(components[1])) {
                return id.uuidString.lowercased()
            }
        }
        return nil
    }

    private static func codexSessionID(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        if accessibilityPID != pid {
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            accessibilityPID = pid
        }
        guard let window = accessibilityElement(attribute(app, kAXFocusedWindowAttribute))
                ?? accessibilityElement(attribute(app, kAXMainWindowAttribute)) else { return nil }
        return codexSessionID(in: window)
    }

    private static func codexSessionID(in window: AXUIElement) -> String? {
        func session(from value: CFTypeRef?) -> String? {
            if let url = value as? URL { return codexSessionID(in: url) }
            if let address = value as? String, let url = URL(string: address) { return codexSessionID(in: url) }
            return nil
        }
        if let id = session(from: attribute(window, kAXDocumentAttribute)) { return id }
        var queue = [window]
        var index = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.11
        // Read only the active document URL or the selected sidebar link, with no message or title data.
        while index < queue.count, index < 350, ProcessInfo.processInfo.systemUptime < deadline {
            let item = queue[index]
            index += 1
            guard let role = attribute(item, kAXRoleAttribute) as? String else { continue }
            if role == "AXWebArea", let id = session(from: attribute(item, kAXURLAttribute)) { return id }
            if role == "AXLink" {
                let current = attribute(item, "AXARIACurrent") as? String
                if current == "page" || current == "true" || attribute(item, kAXSelectedAttribute) as? Bool == true,
                   let id = session(from: attribute(item, kAXURLAttribute)) { return id }
                continue
            }
            if ![kAXTextAreaRole, kAXTextFieldRole, "AXStaticText", "AXImage"].contains(role),
               let children = attribute(item, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(350))
            }
        }
        return nil
    }

    static func chooseSession() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier,
              let target = ChatTarget(rawValue: id), target != .grokBot else { return "请先打开 Codex 或 Claude" }
        guard canPost, !IsSecureEventInputEnabled() else { return "选择会话需要辅助功能权限" }
        if sessionPickerIsFocused() {
            _ = press(UInt16(kVK_Escape), flags: 0)
            sessionSearchPID = nil
            return "已收起会话选择"
        }

        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let root = target == .codex ? accessibilityElement(attribute(app, kAXMenuBarAttribute))
            : accessibilityElement(attribute(app, kAXFocusedWindowAttribute))
        let role = target == .codex ? kAXMenuItemRole : kAXButtonRole
        let matches: Set<String> = target == .codex
            ? ["search chats", "搜索聊天", "搜索对话", "搜尋對話"]
            : ["search", "search chats", "搜索", "搜索聊天", "搜尋"]
        let entry = root.flatMap { root in
            findElement(in: root, role: role) { element in
                labels(element).contains { label in
                    matches.contains(label.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".… ")))
                }
            }
        }
        let opened: Bool
        if let entry {
            opened = AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success
        } else if target == .codex {
            // The desktop build also exposes the recent-chat Spotlight picker.
            opened = press(UInt16(kVK_ANSI_K), flags: CGEventFlags.maskAlternate.rawValue)
        } else {
            opened = false
        }
        sessionSearchPID = opened ? front.processIdentifier : nil
        return opened ? "已打开 \(target.name) 会话选择" : "当前窗口未找到 \(target.name) 会话选择"
    }

    static func sessionPickerIsFocused() -> Bool {
        guard let pid = sessionSearchPID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let field = accessibilityElement(attribute(app, kAXFocusedUIElementAttribute)),
              let role = attribute(field, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, "AXSearchField", "AXComboBox"].contains(role) else { return false }
        let cues = ["search", "switch chat", "spotlight", "搜索", "搜尋", "切换聊天", "切换对话"]
        return labels(field).contains { label in
            cues.contains { label.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func labels(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXIdentifierAttribute,
         "AXDOMIdentifier"].compactMap { attribute(element, $0) as? String }
    }

    private static func hasLabel(_ element: AXUIElement, among names: Set<String>) -> Bool {
        labels(element).contains { names.contains($0.lowercased()) }
    }

    private static func findElement(in root: AXUIElement, role targetRole: String,
                                    matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var stack = [root]
        var visited = Set<AXUIElement>()
        while let item = stack.popLast(), visited.count < 480 {
            guard visited.insert(item).inserted, let role = attribute(item, kAXRoleAttribute) as? String else { continue }
            if role == targetRole, matches(item) { return item }
            if ["AXStaticText", "AXImage", "AXLink", "AXHeading"].contains(role) { continue }
            if let children = attribute(item, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
        return nil
    }

    private static func focusChat(_ target: ChatTarget, pid: pid_t, request: UUID, expectedCodexSession: String? = nil,
                                  switchCodexSurface: Bool = true,
                                  report: @escaping (String) -> Void) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        var startedAt: TimeInterval?
        var triedFocusCommand = false
        var switchedAt: TimeInterval?
        var retriedAfterSwitch = false

        func attempt() {
            guard requestedChat == request else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            if !foreground && startedAt != nil { return }
            if now >= deadline {
                if expectedCodexSession != nil, codexSessionID(pid: pid) != expectedCodexSession {
                    codexHistory.cancelSelection()
                    report("无法确认已打开目标 Codex 会话")
                    return
                }
                report("已打开 \(target.name) · 当前窗口未找到对话输入框")
                return
            }
            if foreground {
                guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
                    report("已打开 \(target.name) · 聚焦输入框需要辅助功能权限")
                    return
                }
                let elapsed = now - (startedAt ?? now)
                if startedAt == nil {
                    startedAt = now
                    // Request the web accessibility tree from Electron.
                    _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                }
                if let expectedCodexSession, codexSessionID(pid: pid) != expectedCodexSession {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) { attempt() }
                    return
                }
                if focusComposer(of: app, target: target, pid: pid, allowUnlabeled: retriedAfterSwitch) {
                    report("已聚焦 \(target.name) 对话框")
                    return
                }
                if elapsed >= 0.65, !triedFocusCommand, frontIs(pid) {
                    triedFocusCommand = true
                    focusUsingAppCommand(target, app: app, pid: pid)
                } else if elapsed >= 1.35, target == .codex, switchCodexSurface, switchedAt == nil, frontIs(pid) {
                    switchedAt = ProcessInfo.processInfo.systemUptime
                    _ = press(UInt16(kVK_ANSI_3), flags: CGEventFlags.maskControl.rawValue)
                } else if let switchedAt, now - switchedAt >= 0.65, !retriedAfterSwitch, frontIs(pid) {
                    retriedAfterSwitch = true
                    focusUsingAppCommand(target, app: app, pid: pid)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) { attempt() }
        }

        attempt()
    }

    private static func frontIs(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && !IsSecureEventInputEnabled()
    }

    private static func focusUsingAppCommand(_ target: ChatTarget, app: AXUIElement, pid: pid_t) {
        if target == .claude {
            if frontIs(pid) { _ = press(UInt16(kVK_F6), flags: 0) }
            return
        }
        guard target == .codex else { return }
        let names: Set<String> = ["focus main chat", "聚焦主聊天", "聚焦主对话", "聚焦主要聊天",
                                  "将焦点移到主聊天", "聚焦主要對話"]
        guard let menu = accessibilityElement(attribute(app, kAXMenuBarAttribute)),
              let item = findElement(in: menu, role: kAXMenuItemRole, matches: { element in
                  labels(element).contains { names.contains($0.lowercased()) }
              }), frontIs(pid) else { return }
        _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
    }

    private static func focusComposer(of app: AXUIElement, target: ChatTarget, pid: pid_t,
                                      allowUnlabeled: Bool) -> Bool {
        let editors = [kAXTextAreaRole, kAXTextFieldRole, "AXEditableText"]
        if let focused = accessibilityElement(attribute(app, kAXFocusedUIElementAttribute)),
           let role = attribute(focused, kAXRoleAttribute) as? String, editors.contains(role),
           target.identifiesComposer(labels(focused)), frontIs(pid) { return true }

        guard let window = accessibilityElement(attribute(app, kAXFocusedWindowAttribute))
                ?? accessibilityElement(attribute(app, kAXMainWindowAttribute)) else { return false }
        var stack = [window]
        var visited = Set<AXUIElement>()
        var fallback: [AXUIElement] = []
        let excluded: Set<String> = ["AXStaticText", "AXImage", "AXButton", "AXLink", "AXHeading"]
        let scanDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        while let item = stack.popLast(), visited.count < 720, ProcessInfo.processInfo.systemUptime < scanDeadline {
            guard visited.insert(item).inserted, let role = attribute(item, kAXRoleAttribute) as? String else { continue }
            if editors.contains(role), attribute(item, kAXEnabledAttribute) as? Bool != false {
                let descriptors = labels(item)
                if target.identifiesComposer(descriptors), frontIs(pid), focus(item, within: app) { return true }
                if allowUnlabeled && role == kAXTextAreaRole && descriptors.allSatisfy({ $0.isEmpty })
                    && attribute(item, kAXSelectedTextRangeAttribute) != nil {
                    fallback.append(item)
                }
            } else if !excluded.contains(role), let children = attribute(item, kAXChildrenAttribute) as? [AXUIElement] {
                // The composer is usually below the history and navigation.
                stack.append(contentsOf: children)
            }
        }
        return target == .codex && stack.isEmpty && fallback.count == 1 && frontIs(pid) && focus(fallback[0], within: app)
    }

    private static func focus(_ element: AXUIElement, within app: AXUIElement) -> Bool {
        if attribute(element, kAXFocusedAttribute) as? Bool != true {
            _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        guard var focused = accessibilityElement(attribute(app, kAXFocusedUIElementAttribute)) else {
            return attribute(element, kAXFocusedAttribute) as? Bool == true
        }
        // A Chromium text area can report a focused descendant.
        for _ in 0..<5 {
            if CFEqual(focused, element) { return true }
            guard let parent = accessibilityElement(attribute(focused, kAXParentAttribute)) else { break }
            focused = parent
        }
        return false
    }

    private static func accessibilityElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    static func fnEvent(down: Bool) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Function), keyDown: down)
        else { return nil }
        event.type = .flagsChanged
        event.flags = down ? .maskSecondaryFn : []
        return event
    }

    static func postFn(down: Bool) -> Bool {
        guard canPost, !down || !IsSecureEventInputEnabled(), let event = fnEvent(down: down) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    static func mediaEvent(_ key: Int, down: Bool) -> CGEvent? {
        let state = Int(down ? NX_KEYDOWN : NX_KEYUP)
        return NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                  modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                                  timestamp: 0, windowNumber: 0, context: nil,
                                  subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                                  data1: (key << 16) | (state << 8), data2: -1)?.cgEvent
    }

    static func pressMedia(_ key: Int) -> Bool {
        guard canPost, !IsSecureEventInputEnabled(),
              let down = mediaEvent(key, down: true), let up = mediaEvent(key, down: false) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    static func keyboardEvent(_ key: UInt16, flags: UInt64, down: Bool, isRepeat: Bool = false) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return nil }
        event.flags = .init(rawValue: flags)
        if down && isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return event
    }

    static func postKeyboard(_ key: UInt16, flags: UInt64, down: Bool, isRepeat: Bool = false) -> Bool {
        guard canPost, !down || !IsSecureEventInputEnabled(),
              let event = keyboardEvent(key, flags: flags, down: down, isRepeat: isRepeat) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    static func press(_ key: UInt16, flags: UInt64) -> Bool {
        guard canPost, !IsSecureEventInputEnabled(),
              let down = keyboardEvent(key, flags: flags, down: true),
              let up = keyboardEvent(key, flags: flags, down: false) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    static func focusedInput() -> AXUIElement? {
        guard canPost, !IsSecureEventInputEnabled(), isCodex,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let focused = accessibilityElement(attribute(app, kAXFocusedUIElementAttribute)),
              let role = attribute(focused, kAXRoleAttribute) as? String,
              [kAXTextAreaRole, kAXTextFieldRole, "AXEditableText"].contains(role) else { return nil }
        return focused
    }

    static func insert(_ text: String, into target: AXUIElement?) -> Bool {
        guard let target, let current = focusedInput(), CFEqual(target, current) else { return false }
        return AXUIElementSetAttributeValue(current, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}
