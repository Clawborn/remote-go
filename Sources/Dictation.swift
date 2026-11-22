import AppKit
import Carbon

enum DictationMode: String, Codable, CaseIterable {
    case hold, toggle

    var title: InterfaceMessage {
        self == .hold ? "按住说话" : "点按开始或结束"
    }
}

struct DictationProfile: Codable, Equatable {
    var shortcut: DictationShortcut
    var mode: DictationMode
    var deviceUID: String
    var doubleTapShortcut: DictationShortcut? = nil

    static var defaults: Self {
        let preferred = MicrophoneDevices.remoteGoMicUID
        let device = MicrophoneDevices.device(uid: preferred) == nil
            && MicrophoneDevices.device(uid: MicrophoneDevices.blackHoleUID) != nil
            ? MicrophoneDevices.blackHoleUID : preferred
        return Self(shortcut: .fn, mode: .hold, deviceUID: device)
    }
}

struct DictationShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64

    static let fn = Self(keyCode: UInt16(kVK_Function), modifiers: 0)
    static let fnLeftControl = Self(keyCode: UInt16(kVK_Control), modifiers: CGEventFlags.maskSecondaryFn.rawValue)
    static let supported = NSEvent.ModifierFlags([.command, .option, .control, .shift, .function])
    private static let modifierKeys: [(CGEventFlags, Int)] = [
        (.maskSecondaryFn, kVK_Function), (.maskControl, kVK_Control),
        (.maskAlternate, kVK_Option), (.maskShift, kVK_Shift), (.maskCommand, kVK_Command),
    ]

    static func fromModifier(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Self? {
        guard let modifier = modifier(keyCode) else { return nil }
        let keyFlag = modifier.flags.rawValue & UInt64(supported.rawValue)
        let otherFlags = UInt64(flags.intersection(supported).rawValue) & ~keyFlag
        if keyCode == kVK_Function, otherFlags == CGEventFlags.maskControl.rawValue {
            let rightControl = UInt64(flags.rawValue) & 0x2000 != 0
            return Self(keyCode: UInt16(rightControl ? kVK_RightControl : kVK_Control),
                        modifiers: CGEventFlags.maskSecondaryFn.rawValue)
        }
        return Self(keyCode: keyCode, modifiers: otherFlags)
    }

    static func modifier(_ keyCode: UInt16) -> (label: String, flags: CGEventFlags)? {
        switch Int(keyCode) {
        case kVK_Command: return ("⌘", [.maskCommand, CGEventFlags(rawValue: 0x08)])
        case kVK_RightCommand: return ("Right ⌘", [.maskCommand, CGEventFlags(rawValue: 0x10)])
        case kVK_Option: return ("⌥", [.maskAlternate, CGEventFlags(rawValue: 0x20)])
        case kVK_RightOption: return ("Right ⌥", [.maskAlternate, CGEventFlags(rawValue: 0x40)])
        case kVK_Control: return ("⌃", [.maskControl, CGEventFlags(rawValue: 0x01)])
        case kVK_RightControl: return ("Right ⌃", [.maskControl, CGEventFlags(rawValue: 0x2000)])
        case kVK_Shift: return ("⇧", [.maskShift, CGEventFlags(rawValue: 0x02)])
        case kVK_RightShift: return ("Right ⇧", [.maskShift, CGEventFlags(rawValue: 0x04)])
        case kVK_Function: return ("Fn", .maskSecondaryFn)
        default: return nil
        }
    }

    func event(down: Bool) -> CGEvent? {
        if self == .fn { return Output.fnEvent(down: down) }
        guard let modifier = Self.modifier(keyCode) else {
            return Output.keyboardEvent(keyCode, flags: modifiers, down: down)
        }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return nil }
        event.type = .flagsChanged
        event.flags = down ? modifier.flags : []
        return event
    }

    func post(down: Bool) -> Bool {
        guard Output.canPost, !down || !IsSecureEventInputEnabled(),
              let events = events(down: down) else { return false }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    func tap() -> Bool {
        guard post(down: true) else { return false }
        return post(down: false)
    }

    private var additionalModifierKeys: [UInt16] {
        let flags = CGEventFlags(rawValue: modifiers)
        return Self.modifierKeys.compactMap { flag, key in flags.contains(flag) ? UInt16(key) : nil }
    }

    func events(down: Bool) -> [CGEvent]? {
        guard modifiers != 0, Self.modifier(keyCode) != nil else {
            return event(down: down).map { [$0] }
        }
        let keys = additionalModifierKeys + [keyCode]
        var events: [CGEvent] = []
        var flags: CGEventFlags = down ? [] : keys.reduce(into: CGEventFlags()) {
            $0.formUnion(Self.modifier($1)?.flags ?? [])
        }
        for key in (down ? keys : Array(keys.reversed())) {
            guard let modifier = Self.modifier(key),
                  let event = Self(keyCode: key, modifiers: 0).event(down: down) else { return nil }
            if down { flags.formUnion(modifier.flags) } else { flags.subtract(modifier.flags) }
            event.flags = flags
            events.append(event)
        }
        return events
    }

    var label: String {
        if self == .fnLeftControl { return "Fn + Left ⌃" }
        if let modifier = Self.modifier(keyCode) {
            let labels = additionalModifierKeys.compactMap { Self.modifier($0)?.label }
            return (labels + [modifier.label]).joined(separator: " + ")
        }
        let rule = BindingRule(id: .assistant, name: "", action: .shortcut,
                               keyCode: keyCode, modifiers: modifiers, codexOnly: false)
        return (CGEventFlags(rawValue: modifiers).contains(.maskSecondaryFn) ? "Fn+" : "") + Desk.shortcutLabel(rule)
    }
}
