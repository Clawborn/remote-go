import AppKit
import Carbon
import SwiftUI

final class PointerMode {
    private var held: [ButtonID: TimeInterval] = [:]
    private var timer: Timer?
    private var indicator: NSPanel?
    private var lastTick = 0.0
    private var lastScroll = 0.0
    private static let scrollDelay = 0.28
    private static let scrollInterval = 0.075

    private static let vectors: [ButtonID: CGVector] = [
        ButtonID(page: 12, usage: 0x42): CGVector(dx: 0, dy: -1),
        ButtonID(page: 12, usage: 0x43): CGVector(dx: 0, dy: 1),
        ButtonID(page: 12, usage: 0x44): CGVector(dx: -1, dy: 0),
        ButtonID(page: 12, usage: 0x45): CGVector(dx: 1, dy: 0),
    ]
    private static let wheel: [ButtonID: Int32] = [
        ButtonID(page: 12, usage: 0xE9): 64,
        ButtonID(page: 12, usage: 0xEA): -64,
    ]

    func begin() {
        showIndicator(ui("飞鼠模式 · 按返回退出"))
    }

    private func showIndicator(_ text: String, dissolve: Bool = false) {
        indicator?.orderOut(nil)
        indicator = nil
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        else { return }
        let size = CGSize(width: 286, height: 64)
        let area = screen.visibleFrame
        let frame = CGRect(x: area.midX - size.width / 2, y: area.maxY - 65, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: PointerIndicator(
            text: text, dissolve: dissolve && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ).frame(width: size.width, height: size.height))
        indicator = panel
        panel.orderFrontRegardless()
    }

    func end(confirmation: InterfaceMessage?) {
        held.removeAll()
        stopTimer()
        indicator?.orderOut(nil)
        indicator = nil
        guard let confirmation else { return }
        showIndicator(ui(confirmation), dissolve: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak panel = indicator] in
            guard let self, let panel, self.indicator === panel else { return }
            panel.orderOut(nil)
            self.indicator = nil
        }
    }

    func release(_ button: ButtonID) {
        if held.removeValue(forKey: button) != nil, held.isEmpty { stopTimer() }
    }

    func consume(_ button: ButtonID) -> Bool {
        if button == ButtonID(page: 12, usage: 0x41) {
            Self.click()
            return true
        }
        let vector = Self.vectors[button]
        let pixels = Self.wheel[button]
        guard vector != nil || pixels != nil else { return false }
        guard held[button] == nil else { return true }
        let now = ProcessInfo.processInfo.systemUptime
        held[button] = now
        if let pixels {
            Self.scroll(pixels)
            lastScroll = now
        } else if let vector, held.keys.filter({ Self.vectors[$0] != nil }).count == 1 {
            Self.move(by: CGVector(dx: vector.dx * 7, dy: vector.dy * 7))
        }
        if timer == nil {
            lastTick = now
            let movement = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.tick()
            }
            timer = movement
            RunLoop.main.add(movement, forMode: .common)
        }
        return true
    }

    private func tick() {
        guard CGPreflightPostEventAccess(), !IsSecureEventInputEnabled() else {
            held.removeAll()
            stopTimer()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = min(now - lastTick, 0.035)
        lastTick = now
        if now - lastScroll >= Self.scrollInterval {
            let pixels = Self.repeatedScroll(held: held, at: now)
            if pixels != 0 {
                Self.scroll(pixels)
                lastScroll = now
            }
        }
        var vector = CGVector.zero
        var fastest = 0.0
        for (button, started) in held {
            let duration = now - started
            guard let direction = Self.vectors[button], duration >= 0.16 else { continue }
            fastest = max(fastest, duration)
            vector.dx += direction.dx
            vector.dy += direction.dy
        }
        let magnitude = hypot(vector.dx, vector.dy)
        guard magnitude > 0 else { return }
        let distance = Self.speed(heldFor: fastest) * interval
        Self.move(by: CGVector(dx: vector.dx * distance / magnitude, dy: vector.dy * distance / magnitude))
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    static func speed(heldFor duration: TimeInterval) -> CGFloat {
        let progress = min(max((duration - 0.16) / 0.74, 0), 1)
        return 125 + 975 * progress * progress
    }

    static func repeatedScroll(held: [ButtonID: TimeInterval], at time: TimeInterval) -> Int32 {
        let direction = wheel.reduce(into: Int32(0)) { direction, entry in
            guard let started = held[entry.key], time - started >= scrollDelay else { return }
            direction += entry.value
        }
        return direction
    }

    static func position(from point: CGPoint, offset: CGVector, on screens: [CGRect]) -> CGPoint {
        let target = CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
        if screens.contains(where: { $0.contains(target) }) { return target }
        guard let screen = screens.first(where: { $0.contains(point) }) else { return point }
        return CGPoint(x: min(max(target.x, screen.minX), screen.maxX - 1),
                       y: min(max(target.y, screen.minY), screen.maxY - 1))
    }

    private static func move(by offset: CGVector) {
        guard let origin = CGEvent(source: nil)?.location else { return }
        let screens = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(id.uint32Value)
        }
        let target = position(from: origin, offset: offset, on: screens)
        guard origin != target,
              let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target,
                                  mouseButton: .left) else { return }
        // Warp the visible pointer, then deliver hover and tracking events to the app below it.
        guard CGWarpMouseCursorPosition(target) == .success else { return }
        event.post(tap: .cghidEventTap)
    }

    private static func click() {
        guard CGPreflightPostEventAccess(), !IsSecureEventInputEnabled(),
              let point = CGEvent(source: nil)?.location,
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func scroll(_ pixels: Int32) {
        guard CGPreflightPostEventAccess(), !IsSecureEventInputEnabled(),
              let point = CGEvent(source: nil)?.location,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}

private struct PointerIndicator: View {
    let text: String
    let dissolve: Bool
    private let startedAt = Date()

    var body: some View {
        if dissolve {
            TimelineView(.animation) { timeline in
                transition(elapsed: timeline.date.timeIntervalSince(startedAt))
            }
        } else {
            capsule
        }
    }

    private func transition(elapsed: TimeInterval) -> some View {
        let progress = min(max((elapsed - 0.6) / 0.75, 0), 1)
        return ZStack {
            capsule.opacity(pow(1 - progress, 4))
            if progress > 0 && progress < 1 {
                particles(progress: progress)
            }
        }
    }

    private var capsule: some View {
        Label(text, systemImage: "cursorarrow")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 226, height: 38)
            .background(.regularMaterial, in: Capsule())
    }

    private func particles(progress: Double) -> some View {
        Canvas { context, size in
            let distance = 1 - pow(1 - progress, 2)
            for index in 0..<48 {
                // Interleave the upper and lower specks across the capsule.
                let horizontal = Double(index % 24) / 23
                let vertical = index < 24 ? -1.0 : 1.0
                let seed = Double((index * 17) % 29) / 28
                let x = size.width / 2 + (horizontal - 0.5) * (186 + distance * (22 + seed * 36))
                let y = size.height / 2 + vertical * (4 + seed * 8 + distance * (9 + seed * 8))
                let radius = (0.75 + seed * 1.45) * (1 - progress * 0.6)
                let opacity = min(progress * 9, 1) * pow(1 - progress, 1.3)
                let color: Color = index.isMultiple(of: 3) ? .accentColor : .primary
                let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: dot), with: .color(color.opacity(opacity)))
            }
        }
        .accessibilityHidden(true)
    }
}
