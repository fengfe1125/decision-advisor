import AppKit
import SwiftUI

// MARK: - Adaptive Color Palette ("静谧松林 · 温润纸感")

enum Theme {
    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1.0)
        })
    }

    static func dynamicNSColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1.0)
        }
    }

    // Surfaces
    static let sidebarBg = dynamic(
        light: (0.945, 0.935, 0.914),  // #F1EFE9 Warm stone
        dark:  (0.086, 0.098, 0.094)   // #161918 Deep obsidian moss
    )
    static let canvasBg = dynamic(
        light: (0.980, 0.976, 0.965),  // #FAF9F6 Warm alabaster paper
        dark:  (0.110, 0.125, 0.120)   // #1C201F Quiet dark slate
    )
    static let cardBg = dynamic(
        light: (1.000, 1.000, 1.000),  // #FFFFFF Crisp card
        dark:  (0.145, 0.165, 0.157)   // #252A28 Elevated card
    )
    static let surfaceSubtle = dynamic(
        light: (0.929, 0.918, 0.894),  // #EDEAE4 Soft pill track
        dark:  (0.141, 0.161, 0.153)   // #242927
    )
    static let hoverFill = dynamic(
        light: (0.902, 0.890, 0.863),  // #E6E3DC
        dark:  (0.176, 0.200, 0.192)   // #2D3331
    )
    static let codeBg = dynamic(
        light: (0.949, 0.941, 0.922),  // #F2F0EB
        dark:  (0.098, 0.114, 0.108)   // #191D1C
    )

    // Hairlines & Borders
    static let borderSubtle = dynamic(
        light: (0.894, 0.878, 0.847),  // #E4E0D8
        dark:  (0.204, 0.231, 0.220)   // #343B38
    )
    static let borderStrong = dynamic(
        light: (0.824, 0.804, 0.765),  // #D2CDC3
        dark:  (0.267, 0.302, 0.286)   // #444D49
    )

    // Typography
    static let textPrimary = dynamic(
        light: (0.118, 0.137, 0.125),  // #1E2320 Deep forest ink
        dark:  (0.925, 0.922, 0.902)   // #ECEBE6 Warm cream ink
    )
    static let textSecondary = dynamic(
        light: (0.396, 0.404, 0.380),  // #656761
        dark:  (0.624, 0.647, 0.627)   // #9FA5A0
    )
    static let textTertiary = dynamic(
        light: (0.580, 0.584, 0.557),  // #94958E
        dark:  (0.435, 0.459, 0.443)   // #6F7571
    )

    // Brand Accent — Deep Spruce Green (matches AppIcon)
    static let accent = dynamic(
        light: (0.145, 0.353, 0.290),  // #255A4A
        dark:  (0.314, 0.659, 0.557)   // #50A88E
    )
    static let accentHover = dynamic(
        light: (0.114, 0.290, 0.235),  // #1D4A3C
        dark:  (0.388, 0.733, 0.627)   // #63BBA0
    )
    static let accentSoft = dynamic(
        light: (0.882, 0.933, 0.914),  // #E1EEE9
        dark:  (0.129, 0.220, 0.192)   // #213831
    )
    static let accentBorder = dynamic(
        light: (0.694, 0.824, 0.776),  // #B1D2C6
        dark:  (0.204, 0.365, 0.314)   // #345D50
    )
    static let userBubble = dynamic(
        light: (0.157, 0.365, 0.302),  // #285D4D
        dark:  (0.176, 0.392, 0.325)   // #2D6453
    )

    // Semantic
    static let success = dynamic(
        light: (0.165, 0.533, 0.361),  // #2A885C
        dark:  (0.325, 0.745, 0.545)   // #53BE8B
    )
    static let successSoft = dynamic(
        light: (0.894, 0.957, 0.922),
        dark:  (0.125, 0.243, 0.184)
    )
    static let warning = dynamic(
        light: (0.718, 0.435, 0.114),  // #B76F1D
        dark:  (0.910, 0.643, 0.310)   // #E8A44F
    )
    static let warningSoft = dynamic(
        light: (0.984, 0.945, 0.886),
        dark:  (0.220, 0.169, 0.098)
    )
    static let danger = dynamic(
        light: (0.725, 0.235, 0.227),  // #B93C3A
        dark:  (0.918, 0.435, 0.427)   // #EA6F6D
    )
    static let dangerSoft = dynamic(
        light: (0.988, 0.918, 0.914),
        dark:  (0.235, 0.122, 0.122)
    )

    static let headerHeight: CGFloat = 46
    static let sidebarWidth: CGFloat = 252
    static let trafficLightClearance: CGFloat = 84
}

// MARK: - Brand Emblem ("温润纸感 · 成长双叶与北极星", matches AppIcon.icns)

private enum BrandEmblemAsset {
    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIconEmblem", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }()
}

struct CompassEmblem: View {
    var size: CGFloat = 28

    var body: some View {
        let cornerRadius = size * 0.24
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Group {
            if let nsImage = BrandEmblemAsset.image {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                fallbackVector
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.65),
                            Color(red: 0.145, green: 0.353, blue: 0.290).opacity(0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(0.75, size * 0.022)
                )
        )
        .shadow(color: Color(red: 0.08, green: 0.16, blue: 0.13).opacity(0.16), radius: size * 0.16, y: size * 0.06)
    }

    private var fallbackVector: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.992, green: 0.988, blue: 0.973),
                    Color(red: 0.937, green: 0.922, blue: 0.882)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height

                // Left spruce leaf
                var leftLeaf = Path()
                leftLeaf.move(to: CGPoint(x: w * 0.50, y: h * 0.84))
                leftLeaf.addCurve(
                    to: CGPoint(x: w * 0.20, y: h * 0.34),
                    control1: CGPoint(x: w * 0.44, y: h * 0.68),
                    control2: CGPoint(x: w * 0.16, y: h * 0.55)
                )
                leftLeaf.addCurve(
                    to: CGPoint(x: w * 0.50, y: h * 0.57),
                    control1: CGPoint(x: w * 0.34, y: h * 0.36),
                    control2: CGPoint(x: w * 0.45, y: h * 0.45)
                )
                leftLeaf.addCurve(
                    to: CGPoint(x: w * 0.50, y: h * 0.84),
                    control1: CGPoint(x: w * 0.54, y: h * 0.64),
                    control2: CGPoint(x: w * 0.54, y: h * 0.74)
                )
                leftLeaf.closeSubpath()
                context.fill(
                    leftLeaf,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.16, green: 0.40, blue: 0.33),
                            Color(red: 0.09, green: 0.24, blue: 0.19)
                        ]),
                        startPoint: CGPoint(x: w * 0.22, y: h * 0.34),
                        endPoint: CGPoint(x: w * 0.50, y: h * 0.84)
                    )
                )

                // Right spruce leaf
                var rightLeaf = Path()
                rightLeaf.move(to: CGPoint(x: w * 0.50, y: h * 0.84))
                rightLeaf.addCurve(
                    to: CGPoint(x: w * 0.80, y: h * 0.34),
                    control1: CGPoint(x: w * 0.56, y: h * 0.68),
                    control2: CGPoint(x: w * 0.84, y: h * 0.55)
                )
                rightLeaf.addCurve(
                    to: CGPoint(x: w * 0.50, y: h * 0.57),
                    control1: CGPoint(x: w * 0.66, y: h * 0.36),
                    control2: CGPoint(x: w * 0.55, y: h * 0.45)
                )
                rightLeaf.addCurve(
                    to: CGPoint(x: w * 0.50, y: h * 0.84),
                    control1: CGPoint(x: w * 0.46, y: h * 0.64),
                    control2: CGPoint(x: w * 0.46, y: h * 0.74)
                )
                rightLeaf.closeSubpath()
                context.fill(
                    rightLeaf,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.24, green: 0.53, blue: 0.44),
                            Color(red: 0.12, green: 0.31, blue: 0.25)
                        ]),
                        startPoint: CGPoint(x: w * 0.78, y: h * 0.34),
                        endPoint: CGPoint(x: w * 0.50, y: h * 0.84)
                    )
                )

                // Center translucent overlap petal
                var overlap = Path()
                overlap.move(to: CGPoint(x: w * 0.50, y: h * 0.57))
                overlap.addCurve(
                    to: CGPoint(x: w * 0.50, y: h * 0.84),
                    control1: CGPoint(x: w * 0.55, y: h * 0.65),
                    control2: CGPoint(x: w * 0.54, y: h * 0.75)
                )
                overlap.addCurve(
                    to: CGPoint(x: w * 0.50, y: h * 0.57),
                    control1: CGPoint(x: w * 0.46, y: h * 0.75),
                    control2: CGPoint(x: w * 0.45, y: h * 0.65)
                )
                overlap.closeSubpath()
                context.fill(overlap, with: .color(Color(red: 0.42, green: 0.70, blue: 0.60).opacity(0.45)))

                // 4-point golden Polaris star
                let sx = w * 0.50
                let sy = h * 0.30
                let arm = w * 0.125
                let waist = w * 0.032
                var star = Path()
                star.move(to: CGPoint(x: sx, y: sy - arm))
                star.addLine(to: CGPoint(x: sx + waist, y: sy - waist))
                star.addLine(to: CGPoint(x: sx + arm, y: sy))
                star.addLine(to: CGPoint(x: sx + waist, y: sy + waist))
                star.addLine(to: CGPoint(x: sx, y: sy + arm))
                star.addLine(to: CGPoint(x: sx - waist, y: sy + waist))
                star.addLine(to: CGPoint(x: sx - arm, y: sy))
                star.addLine(to: CGPoint(x: sx - waist, y: sy - waist))
                star.closeSubpath()
                context.fill(
                    star,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.96, green: 0.82, blue: 0.49),
                            Color(red: 0.78, green: 0.56, blue: 0.22)
                        ]),
                        startPoint: CGPoint(x: sx - arm, y: sy - arm),
                        endPoint: CGPoint(x: sx + arm, y: sy + arm)
                    )
                )
            }
        }
    }
}

// MARK: - Native Window Seamless Configurator & Drag Handle

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.backgroundColor = Theme.dynamicNSColor(
            light: (0.980, 0.976, 0.965),
            dark:  (0.110, 0.125, 0.120)
        )
    }
}

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragNSView {
        DragNSView()
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {}

    final class DragNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

// MARK: - Unified Segmented Pill Control

struct UnifiedSegmentedControl<Option: Identifiable & Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var compact: Bool = false

    @Namespace private var pillNamespace
    @State private var hovered: Option? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = selection == option
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                        selection = option
                    }
                } label: {
                    Text(label(option))
                        .font(.system(size: compact ? 12 : 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.textPrimary : (hovered == option ? Theme.textPrimary.opacity(0.85) : Theme.textSecondary))
                        .padding(.horizontal, compact ? 10 : 12)
                        .padding(.vertical, compact ? 5 : 6)
                        .frame(maxWidth: compact ? .infinity : nil)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.cardBg)
                                    .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Theme.borderSubtle.opacity(0.8), lineWidth: 0.5)
                                    )
                                    .matchedGeometryEffect(id: "active-pill", in: pillNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    hovered = inside ? option : (hovered == option ? nil : hovered)
                }
            }
        }
        .padding(3)
        .background(Theme.surfaceSubtle, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Theme.borderSubtle.opacity(0.65), lineWidth: 0.5)
        )
    }
}

// MARK: - Unified Button Styles

struct SprucePrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration, compact: compact)
    }

    private struct BodyView: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12.5 : 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(isEnabled ? 1.0 : 0.72))
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.vertical, compact ? 6 : 8)
                .background(
                    RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                        .fill(
                            !isEnabled
                            ? Theme.accent.opacity(0.38)
                            : (configuration.isPressed || isHovering ? Theme.accentHover : Theme.accent)
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovering = $0 }
        }
    }
}

struct SubtleOutlineButtonStyle: ButtonStyle {
    var compact: Bool = false
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration, compact: compact, isActive: isActive)
    }

    private struct BodyView: View {
        let configuration: Configuration
        let compact: Bool
        let isActive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                .foregroundStyle(
                    !isEnabled
                    ? Theme.textTertiary
                    : (isActive ? Theme.accent : Theme.textPrimary)
                )
                .padding(.horizontal, compact ? 10 : 13)
                .padding(.vertical, compact ? 5.5 : 7)
                .background(
                    RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
                        .fill(
                            isActive
                            ? Theme.accentSoft
                            : (configuration.isPressed || isHovering ? Theme.hoverFill.opacity(0.75) : Theme.cardBg)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
                        .strokeBorder(
                            isActive ? Theme.accentBorder : Theme.borderSubtle,
                            lineWidth: 0.9
                        )
                )
                .opacity(isEnabled ? 1.0 : 0.6)
                .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovering = $0 }
        }
    }
}

struct GhostIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration, size: size, isActive: isActive)
    }

    private struct BodyView: View {
        let configuration: Configuration
        let size: CGFloat
        let isActive: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .foregroundStyle(isActive ? Theme.accent : (isHovering ? Theme.textPrimary : Theme.textSecondary))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isActive
                            ? Theme.accentSoft
                            : (configuration.isPressed || isHovering ? Theme.hoverFill.opacity(0.75) : .clear)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Unified Styled Field Container

struct UnifiedFieldBox<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(Theme.canvasBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.borderSubtle, lineWidth: 0.9)
            )
    }
}

// MARK: - True Wrapping FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, min(currentX - spacing, maxWidth))
        }

        return CGSize(width: totalWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Rich Native Markdown Renderer

struct RichMarkdownView: View {
    let text: String
    var fontSize: CGFloat = 14.5

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(prefix: String, text: String)
        case quote(String)
        case code(language: String, content: String)
        case divider
    }

    private var blocks: [Block] {
        parseBlocks(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    inlineText(content)
                        .font(.system(
                            size: level == 1 ? fontSize + 5 : (level == 2 ? fontSize + 2.5 : fontSize + 1),
                            weight: .semibold
                        ))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.top, level == 1 ? 8 : 5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .paragraph(let content):
                    inlineText(content)
                        .font(.system(size: fontSize))
                        .lineSpacing(5.5)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .bullet(let content):
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(Theme.accent.opacity(0.75))
                            .frame(width: 5, height: 5)
                            .padding(.top, fontSize * 0.52)
                        inlineText(content)
                            .font(.system(size: fontSize))
                            .lineSpacing(5)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .numbered(let prefix, let content):
                    HStack(alignment: .top, spacing: 8) {
                        Text(prefix)
                            .font(.system(size: fontSize - 0.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                            .frame(minWidth: 20, alignment: .trailing)
                        inlineText(content)
                            .font(.system(size: fontSize))
                            .lineSpacing(5)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .quote(let content):
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent.opacity(0.55))
                            .frame(width: 3)
                        inlineText(content)
                            .font(.system(size: fontSize - 0.5))
                            .lineSpacing(4.5)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .background(Theme.surfaceSubtle.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                case .code(let lang, let content):
                    CodeBlockView(language: lang, code: content)

                case .divider:
                    Rectangle()
                        .fill(Theme.borderSubtle)
                        .frame(height: 1)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func inlineText(_ raw: String) -> Text {
        if let attr = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(raw)
    }

    private func parseBlocks(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Block] = []
        var paraBuffer: [String] = []
        var inCode = false
        var codeLang = ""
        var codeLines: [String] = []

        func flushPara() {
            let joined = paraBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                result.append(.paragraph(joined))
            }
            paraBuffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    result.append(.code(language: codeLang, content: codeLines.joined(separator: "\n")))
                    inCode = false
                    codeLang = ""
                    codeLines.removeAll()
                } else {
                    flushPara()
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushPara()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushPara()
                result.append(.divider)
                continue
            }

            if trimmed.hasPrefix("### ") {
                flushPara()
                result.append(.heading(level: 3, text: String(trimmed.dropFirst(4))))
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushPara()
                result.append(.heading(level: 2, text: String(trimmed.dropFirst(3))))
                continue
            }
            if trimmed.hasPrefix("# ") {
                flushPara()
                result.append(.heading(level: 1, text: String(trimmed.dropFirst(2))))
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushPara()
                let quoteText = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : ""
                if case .quote(let prev) = result.last {
                    result[result.count - 1] = .quote(prev + "\n" + quoteText)
                } else {
                    result.append(.quote(quoteText))
                }
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushPara()
                result.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }

            if let dotIdx = trimmed.firstIndex(of: "."),
               dotIdx > trimmed.startIndex,
               trimmed.distance(from: trimmed.startIndex, to: dotIdx) <= 3 {
                let prefixNum = trimmed[..<dotIdx]
                let afterDot = trimmed.index(after: dotIdx)
                if prefixNum.allSatisfy(\.isNumber),
                   afterDot < trimmed.endIndex,
                   trimmed[afterDot] == " " {
                    flushPara()
                    let bodyStart = trimmed.index(after: afterDot)
                    result.append(.numbered(prefix: "\(prefixNum).", text: String(trimmed[bodyStart...])))
                    continue
                }
            }

            paraBuffer.append(line)
        }

        if inCode && !codeLines.isEmpty {
            result.append(.code(language: codeLang, content: codeLines.joined(separator: "\n")))
        }
        flushPara()
        return result
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Theme.success : Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surfaceSubtle.opacity(0.55))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 0.8)
        )
    }
}

// MARK: - Subtle Empty State Component

struct CalmEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft.opacity(0.8))
                    .frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
