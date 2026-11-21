import AppKit
import SwiftUI

struct PhysicalKey: Identifiable {
    let id: ButtonID
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    var mark: String? = nil
    var mayUseInfrared = false

    private static func consumer(_ usage: UInt32, _ x: CGFloat, _ y: CGFloat, _ diameter: CGFloat,
                                 mark: String? = nil, infrared: Bool = false) -> Self {
        Self(id: ButtonID(page: 12, usage: usage), x: x, y: y, width: diameter, height: diameter,
             mark: mark, mayUseInfrared: infrared)
    }

    // Pixel centers on the 388 × 1080 front-view image bundled with the app.
    static let keys: [Self] = [
        consumer(0x42, 193, 65, 85, mark: "chevron.up"),
        consumer(0x44, 89, 166, 85, mark: "chevron.left"),
        consumer(0x41, 193, 166, 106),
        consumer(0x45, 297, 166, 85, mark: "chevron.right"),
        consumer(0x43, 193, 266, 85, mark: "chevron.down"),
        consumer(0x224, 115, 377, 102),
        Self(id: .assistant, x: 270, y: 377, width: 102, height: 102),
        consumer(0x223, 115, 511, 102),
        consumer(0xE2, 270, 511, 102, infrared: true),
        consumer(0x77, 115, 643, 102),
        consumer(0x78, 270, 643, 102),
        consumer(0x19E, 113, 774, 66, infrared: true),
        consumer(0x89, 272, 774, 66, infrared: true),
        Self(id: ButtonID(page: 12, usage: 0xE9), x: 411, y: 256, width: 91, height: 71,
             mark: "plus", mayUseInfrared: true),
        Self(id: ButtonID(page: 12, usage: 0xEA), x: 411, y: 338, width: 91, height: 71,
             mark: "minus", mayUseInfrared: true)
    ]

    var isSide: Bool { x > 388 }
}

struct RemotePicture: View {
    @ObservedObject var desk: Desk
    let accent: Color
    private static let artwork = Bundle.main.url(forResource: "chromecast-voice-remote", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.height / 1080, proxy.size.width / 580)
            let origin = (proxy.size.width - 436 * scale) / 2
            let top = (proxy.size.height - 1080 * scale) / 2
            ZStack(alignment: .topLeading) {
                if let image = Self.artwork {
                    Image(nsImage: image).resizable()
                        .frame(width: 388 * scale, height: 1080 * scale)
                        .shadow(color: .black.opacity(0.18), radius: 11, x: 0, y: 8)
                        .position(x: origin + 194 * scale, y: top + 540 * scale)
                        .accessibilityHidden(true)
                } else {
                    Capsule().fill(.regularMaterial)
                        .frame(width: 326 * scale, height: 1055 * scale)
                        .position(x: origin + 194 * scale, y: top + 540 * scale)
                        .accessibilityHidden(true)
                }

                ForEach(PhysicalKey.keys) { key in
                    RemoteHotspot(
                        key: key,
                        scale: scale,
                        accent: accent,
                        selected: desk.selection == key.id,
                        pressed: desk.pressedButtons.contains(key.id),
                        hovering: desk.hoveredButton == key.id,
                        actionName: desk.mappingTitle(key.id)
                    ) { desk.selectForEdit(key.id) }
                    .onHover { inside in
                        if inside { desk.hoveredButton = key.id }
                        else if desk.hoveredButton == key.id { desk.hoveredButton = nil }
                    }
                    .position(x: origin + key.x * scale, y: top + key.y * scale)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ui("Chromecast 遥控器正面按键图"))
    }
}

private struct RemoteHotspot: View {
    let key: PhysicalKey
    let scale: CGFloat
    let accent: Color
    let selected: Bool
    let pressed: Bool
    let hovering: Bool
    let actionName: String
    let activate: () -> Void

    var body: some View {
        let highlighted = selected || hovering || pressed
        let color: Color = pressed ? .green : accent
        let shape = RoundedRectangle(cornerRadius: key.isSide ? 7 : max(key.width, key.height) * scale / 2)
        Button(action: activate) {
            ZStack {
                shape.fill(highlighted ? color.opacity(pressed ? 0.38 : 0.22) : (key.isSide ? .white.opacity(0.93) : .clear))
                shape.strokeBorder(highlighted ? color : (key.isSide ? .black.opacity(0.20) : .clear),
                                   lineWidth: selected || pressed ? 2.5 : 1)
                if let mark = key.mark {
                    Image(systemName: mark)
                        .font(.system(size: max(9, 29 * scale), weight: .semibold))
                        .foregroundStyle(highlighted ? color : Color.black.opacity(0.65))
                }
            }
            .frame(width: key.width * scale, height: key.height * scale)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.id.interfaceLabel)
        .accessibilityValue(actionName)
        .help("\(key.id.interfaceLabel) · \(actionName)")
    }
}
