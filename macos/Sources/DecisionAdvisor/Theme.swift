import AppKit
import SwiftUI

// MARK: - Adaptive Color Palette ("白玻璃 · White Glass")
// 风格 B：macOS 原生 Liquid Glass 质感。亮色模式界面为纯白 + 中性浅灰，
// 绿色只用于按钮、选中态与强调色。

enum Theme {
    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat),
        lightAlpha: CGFloat = 1.0,
        darkAlpha: CGFloat = 1.0
    ) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static func dynamicNSColor(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat),
        lightAlpha: CGFloat = 1.0,
        darkAlpha: CGFloat = 1.0
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    // Surfaces
    static let sidebarBg = dynamic(
        light: (0.969, 0.973, 0.969), dark: (0.110, 0.141, 0.129),   // #F7F8F7 / #1C2421
        lightAlpha: 0.92, darkAlpha: 0.62
    )
    static let canvasBg = dynamic(
        light: (1.000, 1.000, 1.000),  // #FFFFFF 纯白
        dark:  (0.071, 0.098, 0.090)   // #121917 深松绿
    )
    static let cardBg = dynamic(
        light: (1.000, 1.000, 1.000), dark: (0.129, 0.165, 0.153),   // 白 / #212A27
        lightAlpha: 1.0, darkAlpha: 0.82
    )
    static let cardSolid = dynamic(
        light: (1.000, 1.000, 1.000),
        dark:  (0.145, 0.184, 0.169)   // #252F2B
    )
    static let surfaceSubtle = dynamic(
        light: (0.945, 0.953, 0.949), dark: (0.149, 0.188, 0.173),   // #F1F3F2 / #26302C
        lightAlpha: 1.0, darkAlpha: 0.9
    )
    static let hoverFill = dynamic(
        light: (0.922, 0.933, 0.929), dark: (0.180, 0.227, 0.208),   // #EBEEED / #2E3A35
        lightAlpha: 0.9, darkAlpha: 0.9
    )
    static let codeBg = dynamic(
        light: (0.965, 0.969, 0.965),  // #F6F7F6
        dark:  (0.090, 0.118, 0.110)   // #171E1C
    )

    // Hairlines & Borders (带一点绿的细线)
    static let borderSubtle = dynamic(
        light: (0.882, 0.894, 0.886), dark: (0.212, 0.263, 0.243),   // #E1E4E2 / #364340
        lightAlpha: 0.85, darkAlpha: 1.0
    )
    static let borderStrong = dynamic(
        light: (0.800, 0.816, 0.808),  // #CCD0CE
        dark:  (0.275, 0.337, 0.314)   // #465650
    )
    /// 玻璃面板内描边的高光（亮色模式为白色高光）
    static let glassEdge = dynamic(
        light: (1.0, 1.0, 1.0), dark: (1.0, 1.0, 1.0),
        lightAlpha: 0.85, darkAlpha: 0.08
    )

    // Typography
    static let textPrimaryNS = dynamicNSColor(
        light: (0.110, 0.122, 0.118),  // #1C1F1E
        dark:  (0.918, 0.937, 0.925)   // #EAEFEC
    )
    static let textPrimary = Color(nsColor: textPrimaryNS)
    static let textSecondary = dynamic(
        light: (0.373, 0.400, 0.384),  // #5F6662
        dark:  (0.612, 0.667, 0.643)   // #9CAAA4
    )
    static let textTertiary = dynamic(
        light: (0.608, 0.631, 0.616),  // #9BA19D
        dark:  (0.431, 0.490, 0.463)   // #6E7D76
    )

    // Brand Accent — 按钮绿（白底上的清爽绿色）
    static let accent = dynamic(
        light: (0.420, 0.784, 0.608),  // #6BC89B 淡绿（图标、开关、选中描边）
        dark:  (0.420, 0.800, 0.670)   // #6BCCAB
    )
    static let accentHover = dynamic(
        light: (0.690, 0.890, 0.788),  // #B0E3C9 淡绿按钮悬停
        dark:  (0.500, 0.850, 0.730)
    )
    static let accentLight = dynamic(
        light: (0.835, 0.957, 0.894),  // #D5F4E4 淡绿按钮上沿
        dark:  (0.361, 0.690, 0.580)
    )
    /// 浅底上的绿色文字（选中项、标签），比 accent 略深以保证可读性
    static let accentInkNS = dynamicNSColor(
        light: (0.165, 0.478, 0.333),  // #2A7A55 淡绿底上的深绿字
        dark:  (0.620, 0.890, 0.790)   // #9EE3C9
    )
    static let accentInk = Color(nsColor: accentInkNS)
    static let accentSoft = dynamic(
        light: (0.420, 0.784, 0.608), dark: (0.420, 0.800, 0.670),
        lightAlpha: 0.10, darkAlpha: 0.15
    )
    static let accentBorder = dynamic(
        light: (0.420, 0.784, 0.608), dark: (0.420, 0.800, 0.670),
        lightAlpha: 0.35, darkAlpha: 0.40
    )
    /// 选中态的淡绿填充（侧边栏菜单、筛选胶囊等）
    static let selectionFill = dynamic(
        light: (0.922, 0.973, 0.945),  // #EBF8F1
        dark:  (0.153, 0.282, 0.239)   // #27483D
    )
    /// 用户消息气泡：浅薄荷底 + 深绿字
    static let userBubble = dynamic(
        light: (0.906, 0.969, 0.937),  // #E7F7EF
        dark:  (0.165, 0.329, 0.275)   // #2A5446
    )
    static let userBubbleText = dynamic(
        light: (0.137, 0.290, 0.220),  // #234A38
        dark:  (0.918, 0.965, 0.945)
    )
    /// 按钮下沿的淡绿
    static let accentPastel = dynamic(
        light: (0.741, 0.910, 0.824),  // #BDE8D2
        dark:  (0.290, 0.659, 0.537)
    )
    /// 按钮文字/图标颜色（亮色模式深绿，深色模式白）
    static let onAccent = dynamic(
        light: (0.165, 0.478, 0.333),  // #2A7A55
        dark:  (1.0, 1.0, 1.0)
    )
    /// 主按钮的渐变（淡淡的薄荷绿）
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentLight, accentPastel], startPoint: .top, endPoint: .bottom)
    }

    // Semantic
    static let success = dynamic(
        light: (0.165, 0.600, 0.400),  // #2A9966
        dark:  (0.325, 0.780, 0.560)
    )
    static let successSoft = dynamic(
        light: (0.165, 0.600, 0.400), dark: (0.325, 0.780, 0.560),
        lightAlpha: 0.12, darkAlpha: 0.16
    )
    static let warning = dynamic(
        light: (0.745, 0.490, 0.090),  // #BE7D17
        dark:  (0.910, 0.660, 0.330)
    )
    static let warningSoft = dynamic(
        light: (0.906, 0.627, 0.157), dark: (0.910, 0.660, 0.330),
        lightAlpha: 0.14, darkAlpha: 0.16
    )
    static let danger = dynamic(
        light: (0.780, 0.255, 0.290),  // #C7414A
        dark:  (0.918, 0.450, 0.460)
    )
    static let dangerSoft = dynamic(
        light: (0.780, 0.255, 0.290), dark: (0.918, 0.450, 0.460),
        lightAlpha: 0.11, darkAlpha: 0.16
    )

    // 回答结构标签配色（事实 / 推断 / 反方 …）
    static let tagBlue = dynamic(light: (0.224, 0.345, 0.659), dark: (0.478, 0.627, 0.910))
    static let tagViolet = dynamic(light: (0.400, 0.275, 0.659), dark: (0.659, 0.580, 0.918))
    static let tagGold = dynamic(light: (0.541, 0.416, 0.0), dark: (0.890, 0.800, 0.420))

    static let headerHeight: CGFloat = 56
    static let sidebarWidth: CGFloat = 252
    static let inspectorWidth: CGFloat = 284
    static let panelInset: CGFloat = 8
    static let panelRadius: CGFloat = 16
    static let trafficLightClearance: CGFloat = 84
}

// MARK: - Glass Materials

/// AppKit 原生毛玻璃（behind-window blending），让面板透出桌面与窗口背景。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// 整个窗口的底：亮色模式纯白；深色模式保留几团极淡的绿色色斑增加景深。
struct MintBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Theme.canvasBg
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    Circle()
                        .fill(Color(red: 0.60, green: 0.85, blue: 0.74).opacity(dark ? 0.10 : 0))
                        .frame(width: w * 0.62, height: w * 0.62)
                        .position(x: w * 0.12, y: h * 0.08)
                    Circle()
                        .fill(Color(red: 0.70, green: 0.86, blue: 0.86).opacity(dark ? 0.07 : 0))
                        .frame(width: w * 0.55, height: w * 0.55)
                        .position(x: w * 0.92, y: h * 0.18)
                    Circle()
                        .fill(Color(red: 0.86, green: 0.92, blue: 0.78).opacity(dark ? 0.05 : 0))
                        .frame(width: w * 0.6, height: w * 0.6)
                        .position(x: w * 0.72, y: h * 1.02)
                }
                .blur(radius: 90)
            }
        }
        .ignoresSafeArea()
    }
}

/// 浮动玻璃面板：毛玻璃 + 淡绿白色调 + 内描边高光 + 柔和投影。
struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = Theme.panelRadius
    var tint: Color = Theme.sidebarBg
    var shadow: Bool = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow)
                    tint
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(Theme.glassEdge, lineWidth: 1))
            .overlay(shape.strokeBorder(Color.black.opacity(0.045), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(shadow ? 0.07 : 0), radius: 14, y: 5)
    }
}

/// 轻量玻璃卡片（不使用 NSVisualEffectView，适合列表内大量重复的卡片）。
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var isSelected: Bool = false
    var isHovering: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(isSelected || isHovering ? Theme.cardSolid.opacity(0.94) : Theme.cardBg))
            .overlay(shape.strokeBorder(Theme.glassEdge, lineWidth: 1))
            .overlay(
                shape.strokeBorder(
                    isSelected ? Theme.accent : Color.black.opacity(0.05),
                    lineWidth: isSelected ? 2 : 0.5
                )
            )
            .shadow(
                color: isSelected
                    ? Theme.accent.opacity(0.18)
                    : Color.black.opacity(isHovering ? 0.08 : 0.035),
                radius: isSelected || isHovering ? 12 : 5,
                y: isSelected || isHovering ? 5 : 2
            )
    }
}

/// 工具栏里的玻璃胶囊（分段控件、模型选择、检查器按钮等）。
struct GlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Theme.cardBg))
            .overlay(Capsule().strokeBorder(Theme.glassEdge, lineWidth: 1))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.07), radius: 8, y: 3)
    }
}

/// 悬浮弹出卡片（模型切换、对话模式、检索上下文）：匹配「白玻璃 · White Glass」界面质感。
struct GlassPopoverModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    VisualEffectBackground(material: .popover, blendingMode: .withinWindow)
                    Theme.cardSolid.opacity(0.95)
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(Theme.glassEdge, lineWidth: 1))
            .overlay(shape.strokeBorder(Theme.borderSubtle.opacity(0.95), lineWidth: 0.75))
            .shadow(color: Color.black.opacity(0.11), radius: 22, y: 10)
            .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = Theme.panelRadius, tint: Color = Theme.sidebarBg, shadow: Bool = true) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, tint: tint, shadow: shadow))
    }

    func glassCard(cornerRadius: CGFloat = 14, isSelected: Bool = false, isHovering: Bool = false) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, isSelected: isSelected, isHovering: isHovering))
    }

    func glassCapsule() -> some View {
        modifier(GlassCapsuleModifier())
    }

    func glassPopover(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassPopoverModifier(cornerRadius: cornerRadius))
    }
}

/// 检查器 / 设置里的分组标题
struct GlassSectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 3)
    }
}

/// 系统设置风格的彩色图标方块
struct ColorIconTile: View {
    let systemName: String
    var color: Color = Theme.accent
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom))
            )
    }
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
            light: (1.0, 1.0, 1.0),
            dark:  (0.071, 0.098, 0.090)
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

// MARK: - Unified Segmented Pill Control (玻璃胶囊分段控件)

struct UnifiedSegmentedControl<Option: Identifiable & Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var compact: Bool = false
    var icon: ((Option) -> String)? = nil

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
                    HStack(spacing: 5) {
                        if let icon {
                            Image(systemName: icon(option))
                                .font(.system(size: compact ? 10.5 : 11.5, weight: .medium))
                                .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                        }
                        Text(label(option))
                            .font(.system(size: compact ? 12 : 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Theme.textPrimary : (hovered == option ? Theme.textPrimary.opacity(0.85) : Theme.textSecondary))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, compact ? 10 : 13)
                    .padding(.vertical, compact ? 5 : 6)
                    .frame(maxWidth: compact ? .infinity : nil)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.cardSolid)
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                .overlay(Capsule().strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5))
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
        .glassCapsule()
        .fixedSize(horizontal: !compact, vertical: false)
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
                .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
                .foregroundStyle(Theme.onAccent.opacity(isEnabled ? 1.0 : 0.6))
                .padding(.horizontal, compact ? 13 : 17)
                .padding(.vertical, compact ? 6 : 8)
                .background(
                    Capsule()
                        .fill(
                            !isEnabled
                            ? AnyShapeStyle(Theme.accentSoft)
                            : (configuration.isPressed || isHovering
                               ? AnyShapeStyle(Theme.accentHover)
                               : AnyShapeStyle(Theme.accentGradient))
                        )
                )
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 0.6))
                .shadow(color: Theme.accent.opacity(isEnabled ? 0.15 : 0), radius: 5, y: 2)
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
                .padding(.horizontal, compact ? 11 : 14)
                .padding(.vertical, compact ? 5.5 : 7)
                .background(
                    Capsule()
                        .fill(
                            isActive
                            ? Theme.accentSoft
                            : (configuration.isPressed || isHovering ? Theme.cardSolid : Theme.cardBg)
                        )
                )
                .overlay(Capsule().strokeBorder(Theme.glassEdge, lineWidth: 1))
                .overlay(
                    Capsule().strokeBorder(
                        isActive ? Theme.accentBorder : Color.black.opacity(0.08),
                        lineWidth: isActive ? 0.9 : 0.5
                    )
                )
                .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1.5)
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
                    Capsule()
                        .fill(
                            isActive
                            ? Theme.accentSoft
                            : (configuration.isPressed || isHovering ? Theme.hoverFill.opacity(0.8) : .clear)
                        )
                )
                .contentShape(Capsule())
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
            .background(Theme.cardSolid.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
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
