import AppKit
import SwiftUI

final class AppSwitcher: ObservableObject {
    @Published private(set) var apps: [NSRunningApplication] = []
    @Published private(set) var selection = 0
    private(set) var columns = 5
    private var panel: NSPanel?
    private var trigger: ButtonID?

    func show(trigger: ButtonID) {
        let workspace = NSWorkspace.shared
        let frontPID = workspace.frontmostApplication?.processIdentifier
        apps = workspace.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        guard !apps.isEmpty else { return }
        if let current = apps.firstIndex(where: { $0.processIdentifier == frontPID }) {
            let foreground = apps.remove(at: current)
            apps.insert(foreground, at: 0)
        }
        selection = 0
        self.trigger = trigger
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        columns = max(1, min(5, Int((area.width - 64) / 112)))
        let rows = (apps.count + columns - 1) / columns
        let size = NSSize(width: CGFloat(min(columns, apps.count)) * 112 + 36,
                          height: CGFloat(min(rows, 3)) * 102 + 76)
        let frame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                           width: size.width, height: size.height)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: SwitcherView(switcher: self))
        panel = window
        window.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        trigger = nil
        apps = []
    }

    func consume(_ button: ButtonID) -> Bool {
        guard panel != nil else { return false }
        if button == trigger || button == ButtonID(page: 12, usage: 0x224) {
            dismiss()
            return true
        }
        switch (button.page, button.usage) {
        case (12, 0x41):
            let app = apps[selection]
            dismiss()
            if !app.isTerminated {
                app.unhide()
                app.activate()
            }
        case (12, 0x42):
            if selection >= columns { selection -= columns }
        case (12, 0x43):
            if selection / columns < (apps.count - 1) / columns {
                selection = min(selection + columns, apps.count - 1)
            }
        case (12, 0x44): selection = (selection - 1 + apps.count) % apps.count
        case (12, 0x45): selection = (selection + 1) % apps.count
        default: break
        }
        return true
    }
}

private struct SwitcherView: View {
    @ObservedObject var switcher: AppSwitcher

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("切换应用").font(.headline)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(106), spacing: 6), count: switcher.columns),
                              alignment: .leading, spacing: 6) {
                        ForEach(Array(switcher.apps.enumerated()), id: \.element.processIdentifier) { index, app in
                            VStack(spacing: 6) {
                                Image(nsImage: app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
                                    .resizable().scaledToFit().frame(width: 46, height: 46)
                                Text(app.localizedName ?? app.bundleIdentifier ?? "应用")
                                    .font(.caption).lineLimit(1)
                            }
                            .frame(width: 106, height: 96)
                            .background {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(index == switcher.selection ? Color.accentColor.opacity(0.24) : Color.clear)
                            }
                            .overlay {
                                if index == switcher.selection {
                                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(index == switcher.selection ? .isSelected : [])
                            .id(index)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: switcher.selection) { _, index in scroll.scrollTo(index) }
            }
            Text("方向键选择  ·  确定打开  ·  返回关闭").font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
