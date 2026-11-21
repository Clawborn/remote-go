import Carbon
import Foundation

struct MappingApp: Codable, Identifiable {
    let id: String
    let name: String

    static let builtIn = [
        Self(id: ChatTarget.codex.rawValue, name: "Codex"),
        Self(id: ChatTarget.claude.rawValue, name: "Claude"),
        Self(id: ChatTarget.grokBot.rawValue, name: ChatTarget.grokBot.name),
        Self(id: "com.tencent.workbuddy.mac", name: "WorkBuddy"),
        Self(id: "com.work.pc.doubao", name: "豆包工作"),
    ]
}

struct MappingPreset: Identifiable, Codable {
    let id: String
    var name: String
    let isBuiltIn: Bool
    var rules: [BindingRule]
    var appRules: [String: [BindingRule]]? = nil

    func override(for button: ButtonID, appID: String) -> BindingRule? {
        appRules?[appID]?.first { $0.id == button }
    }

    func rule(for button: ButtonID, appID: String?) -> BindingRule? {
        if let appID, let override = override(for: button, appID: appID) { return override }
        guard let rule = rules.first(where: { $0.id == button }), rule.applies(to: appID) else { return nil }
        return rule
    }

    mutating func set(_ rule: BindingRule, for appID: String) {
        var overrides = appRules ?? [:]
        var appBindings = overrides[appID] ?? []
        Self.set(rule, in: &appBindings)
        overrides[appID] = appBindings.isEmpty ? nil : appBindings
        appRules = overrides.isEmpty ? nil : overrides
    }

    mutating func set(_ rule: BindingRule) {
        Self.set(rule, in: &rules)
    }

    private static func set(_ rule: BindingRule, in rules: inout [BindingRule]) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            if rule.action == .unassigned { rules.remove(at: index) }
            else { rules[index] = rule }
        } else if rule.action != .unassigned {
            rules.append(rule)
        }
    }
}

struct PresetLibrary: Codable {
    static let storageKey = "mappingPresetLibrary"
    static let codingID = "vibe-coding"
    static let videoID = "video"

    var activeID: String
    var presets: [MappingPreset]
    var customApps: [MappingApp]? = nil
    private var savedHomeSwitch: HomePresetSwitch? = nil
    private var installedAppSwitcher: Bool? = nil
    private var installedSessionCycle: Bool? = nil
    private var installedSessionSideKeys: Bool? = nil
    private var installedSidebarDirection: Bool? = nil
    private var installedGrokBotSideKeys: Bool? = nil

    var homeSwitch: HomePresetSwitch {
        get { (savedHomeSwitch ?? HomePresetSwitch()).resolved(in: presets) }
        set { savedHomeSwitch = newValue }
    }

    var active: MappingPreset {
        presets.first { $0.id == activeID } ?? presets[0]
    }

    var apps: [MappingApp] {
        let builtIn = MappingApp.builtIn
        return builtIn + (customApps ?? []).filter { app in !builtIn.contains { $0.id == app.id } }
    }

    mutating func editActive(_ change: (inout MappingPreset) -> Void) {
        guard let index = presets.firstIndex(where: { $0.id == activeID }) else { return }
        change(&presets[index])
    }

    static func load(from defaults: UserDefaults) -> Self {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: storageKey),
           var saved = try? decoder.decode(Self.self, from: data),
           !saved.presets.isEmpty, saved.presets.contains(where: { $0.id == saved.activeID }) {
            if saved.savedHomeSwitch == nil {
                if let index = saved.presets.firstIndex(where: { $0.id == videoID && $0.rules == oldVideoRules }) {
                    saved.presets[index].set(rule(0x223, .activate))
                }
                saved.savedHomeSwitch = HomePresetSwitch()
            }
            saved.installAppSwitcher()
            saved.installSessionCycle()
            saved.installSessionSideKeys()
            saved.installSidebarDirection()
            saved.installGrokBotSideKeys()
            return saved
        }

        var coding = MappingPreset(id: codingID, name: "Agent Coding", isBuiltIn: true, rules: codingRules)
        if let data = defaults.data(forKey: "rules"),
           let legacy = try? decoder.decode([BindingRule].self, from: data) {
            coding.rules = legacy
            if !defaults.bool(forKey: "installedAssistantFnMapping") {
                coding.rules.removeAll { $0.id == button(0x41) && $0.action == .fn }
                if !coding.rules.contains(where: { $0.id == .assistant }) { coding.set(fnRule) }
            }
            if !defaults.bool(forKey: "installedChatLaunchers") {
                coding.set(rule(0x77, .codexChat))
                coding.set(rule(0x78, .claudeChat))
            }
            if !defaults.bool(forKey: "installedSessionPicker") { coding.set(rule(0x224, .sessions)) }
            for arrow in arrowRules {
                var normalized = coding.rules.first(where: { $0.id == arrow.id }) ?? arrow
                normalized.action = arrow.action
                normalized.codexOnly = false
                coding.set(normalized)
            }
        }

        let video = MappingPreset(id: videoID, name: "看视频", isBuiltIn: true, rules: videoRules)
        var library = Self(activeID: codingID, presets: [coding, video], savedHomeSwitch: HomePresetSwitch())
        library.installAppSwitcher()
        library.installSessionCycle()
        library.installSessionSideKeys()
        library.installSidebarDirection()
        library.installGrokBotSideKeys()
        return library
    }

    private mutating func installAppSwitcher() {
        guard installedAppSwitcher != true else { return }
        for index in presets.indices where [Self.codingID, Self.videoID].contains(presets[index].id) {
            presets[index].set(Self.rule(0x89, .appSwitcher))
        }
        installedAppSwitcher = true
    }

    private mutating func installSessionCycle() {
        guard installedSessionCycle != true else { return }
        if let index = presets.firstIndex(where: { $0.id == Self.codingID }),
           var home = presets[index].rules.first(where: { $0.id == .home }), home.action == .activate {
            home.action = .cycleCodex
            presets[index].set(home)
        }
        installedSessionCycle = true
    }

    private mutating func installSessionSideKeys() {
        guard installedSessionSideKeys != true else { return }
        if let index = presets.firstIndex(where: { $0.id == Self.codingID }) {
            var preset = presets[index]
            preset.name = "Agent Coding"
            let codex = ChatTarget.codex.rawValue
            for (usage, previous, action) in [(UInt32(0xE9), Action.preview, Action.nextCodexSession),
                                               (0xEA, .reload, .previousCodexSession)] {
                let mapping = Self.rule(usage, action, codexOnly: true)
                let base = preset.rules.first { $0.id == mapping.id }
                let hasOverride = preset.override(for: mapping.id, appID: codex) != nil
                if base == nil || (base?.action == previous && base?.codexOnly == true) {
                    preset.set(mapping)
                }
                if hasOverride || preset.rules.first(where: { $0.id == mapping.id })?.action != action {
                    preset.set(Self.rule(usage, action), for: codex)
                }
            }
            presets[index] = preset
        }
        installedSessionSideKeys = true
    }

    private mutating func installSidebarDirection() {
        guard installedSidebarDirection != true else { return }
        if let index = presets.firstIndex(where: { $0.id == Self.codingID }) {
            var preset = presets[index]
            let codex = ChatTarget.codex.rawValue
            for (usage, old, new) in [(UInt32(0xE9), Action.nextCodexSession, Action.previousCodexSession),
                                      (0xEA, .previousCodexSession, .nextCodexSession)] {
                let id = Self.button(usage)
                if var mapping = preset.rules.first(where: { $0.id == id && $0.action == old }) {
                    mapping.action = new
                    preset.set(mapping)
                }
                if var mapping = preset.override(for: id, appID: codex), mapping.action == old {
                    mapping.action = new
                    preset.set(mapping, for: codex)
                }
            }
            presets[index] = preset
        }
        installedSidebarDirection = true
    }

    private mutating func installGrokBotSideKeys() {
        guard installedGrokBotSideKeys != true else { return }
        if let index = presets.firstIndex(where: { $0.id == Self.codingID }) {
            let appID = ChatTarget.grokBot.rawValue
            let defaults = [
                Self.rule(0xE9, .previousGrokBotSession),
                Self.rule(0xEA, .nextGrokBotSession),
            ]
            for rule in defaults where presets[index].override(for: rule.id, appID: appID) == nil {
                presets[index].set(rule, for: appID)
            }
        }
        installedGrokBotSideKeys = true
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }

    private static func button(_ usage: UInt32) -> ButtonID { ButtonID(page: 12, usage: usage) }

    private static func rule(_ usage: UInt32, _ action: Action, codexOnly: Bool = false) -> BindingRule {
        let id = button(usage)
        return BindingRule(id: id, name: id.label, action: action, codexOnly: codexOnly)
    }

    private static let fnRule = BindingRule(id: .assistant, name: "语音键", action: .fn, codexOnly: false)
    private static let arrowRules = [rule(0x42, .up), rule(0x43, .down), rule(0x44, .left), rule(0x45, .right)]
    private static let codingRules = [fnRule] + arrowRules + [
        BindingRule(id: button(0x41), name: "确定", action: .shortcut, keyCode: UInt16(kVK_Return)),
        rule(0x223, .activate), rule(0x224, .sessions), rule(0x77, .codexChat), rule(0x78, .claudeChat),
        rule(0xE9, .preview, codexOnly: true), rule(0xEA, .reload, codexOnly: true),
        rule(0xE2, .annotate, codexOnly: true),
    ]

    private static let oldVideoRules = arrowRules + [
        BindingRule(id: button(0x41), name: "确定", action: .shortcut, keyCode: UInt16(kVK_Space), codexOnly: false),
        rule(0x224, .escape), rule(0xE9, .volumeUp), rule(0xEA, .volumeDown), rule(0xE2, .mute),
    ]

    private static let videoRules = oldVideoRules + [rule(0x223, .activate)]
}

struct CodexSessionHistory {
    enum Destination: Equatable { case thread(String), slot(Int) }
    enum Direction: Int { case next = 1, previous = -1 }
    private(set) var recent: [String]
    private var ring = [String]()
    private var observed: String?
    private var requested: String?
    private var slotIndex = 0

    init(recent: [String] = []) {
        self.recent = Array(recent.prefix(3))
    }

    mutating func observe(_ thread: String) {
        guard thread != observed else { return }
        observed = thread
        if thread == requested {
            requested = nil
        } else {
            cancelSelection()
        }
        recent.removeAll { $0 == thread }
        recent.insert(thread, at: 0)
        if recent.count > 3 { recent.removeLast() }
    }

    mutating func next(in direction: Direction = .next) -> Destination {
        guard recent.count == 3 else {
            // Start at slot one. Both directions share the same position.
            slotIndex = (slotIndex + direction.rawValue + 3) % 3
            return .slot(slotIndex + 1)
        }
        if ring.isEmpty { ring = recent }
        let index = (requested ?? observed).flatMap { ring.firstIndex(of: $0) }
        let thread = ring[index.map { ($0 + direction.rawValue + ring.count) % ring.count }
            ?? (direction == .next ? 0 : ring.count - 1)]
        requested = thread
        return .thread(thread)
    }

    mutating func cancelSelection() {
        ring = []
        requested = nil
    }
}

struct HomePresetSwitch: Codable {
    var enabled = true
    var firstID = PresetLibrary.codingID
    var secondID = PresetLibrary.videoID

    func resolved(in presets: [MappingPreset]) -> Self {
        let ids = presets.map(\.id)
        var settings = self
        if !ids.contains(firstID) { settings.firstID = ids.contains(PresetLibrary.codingID) ? PresetLibrary.codingID : ids.first ?? "" }
        if !ids.contains(secondID) || secondID == settings.firstID {
            settings.secondID = ids.contains(PresetLibrary.videoID) && settings.firstID != PresetLibrary.videoID
                ? PresetLibrary.videoID : ids.first { $0 != settings.firstID } ?? ""
        }
        return settings
    }

    func destination(from activeID: String) -> String {
        activeID == firstID ? secondID : firstID
    }
}

struct TapHoldPress {
    enum Result: Equatable { case tap, hold }
    let delay: TimeInterval
    private var startedAt: TimeInterval?

    init(delay: TimeInterval = 0.55) {
        self.delay = delay
    }

    mutating func begin(at time: TimeInterval) {
        if startedAt == nil { startedAt = time }
    }

    mutating func cancel() { startedAt = nil }

    mutating func finish(at time: TimeInterval, released: Bool) -> Result? {
        guard let startedAt else { return nil }
        if time >= startedAt + delay {
            cancel()
            return .hold
        }
        guard released else { return nil }
        cancel()
        return .tap
    }
}
