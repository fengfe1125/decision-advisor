import SwiftUI
import UIKit

@MainActor
enum AdvisorTheme {
    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat),
        lightAlpha: CGFloat = 1.0,
        darkAlpha: CGFloat = 1.0
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let c = isDark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    // Surfaces — 与 macOS 端「白玻璃 · 温润薄荷绿」及品牌罗盘图标保持一致
    static let paper = Color(uiColor: .systemBackground)
    static let raisedPaper = Color(uiColor: .secondarySystemBackground)
    static let cardSurface = dynamic(
        light: (0.985, 0.990, 0.987),
        dark: (0.125, 0.145, 0.137)
    )
    static let composerFill = dynamic(
        light: (1.0, 1.0, 1.0),
        dark: (0.145, 0.168, 0.158),
        lightAlpha: 0.88,
        darkAlpha: 0.86
    )
    static let chipFill = dynamic(
        light: (0.945, 0.960, 0.953),
        dark: (0.195, 0.228, 0.214)
    )
    static let codeBg = dynamic(
        light: (0.955, 0.965, 0.959),
        dark: (0.105, 0.125, 0.118)
    )

    // Ink & Rules
    static let ink = Color.primary
    static let secondaryInk = Color.secondary
    static let tertiaryInk = Color(uiColor: .tertiaryLabel)
    static let rule = Color(uiColor: .separator)
    static let subtleBorder = dynamic(
        light: (0.10, 0.20, 0.15),
        dark: (0.85, 0.95, 0.90),
        lightAlpha: 0.10,
        darkAlpha: 0.14
    )

    // Brand Spruce Green
    static let accent = dynamic(
        light: (0.145, 0.455, 0.335),   // #257455 沉稳松针绿（按钮与强调）
        dark: (0.355, 0.785, 0.615)     // #5AC89D 清透薄荷松绿
    )
    static let accentInk = dynamic(
        light: (0.125, 0.415, 0.300),   // #206A4C 高对比强调字
        dark: (0.450, 0.840, 0.680)
    )
    static let accentSoft = dynamic(
        light: (0.145, 0.455, 0.335),
        dark: (0.355, 0.785, 0.615),
        lightAlpha: 0.11,
        darkAlpha: 0.18
    )
    static let accentBorder = dynamic(
        light: (0.145, 0.455, 0.335),
        dark: (0.355, 0.785, 0.615),
        lightAlpha: 0.34,
        darkAlpha: 0.42
    )
    static let onAccent = dynamic(
        light: (1.0, 1.0, 1.0),
        dark: (0.045, 0.115, 0.088)
    )

    // User Message Bubble — 柔和薄荷纸感，长文阅读更轻松
    static let outgoingBubble = dynamic(
        light: (0.902, 0.965, 0.933),   // #E6F6EE
        dark: (0.145, 0.295, 0.240)     // #254B3D
    )
    static let outgoingInk = dynamic(
        light: (0.105, 0.245, 0.185),   // #1B3E2F
        dark: (0.930, 0.972, 0.950)
    )

    // Semantics
    static let warning = dynamic(
        light: (0.765, 0.485, 0.085),
        dark: (0.940, 0.700, 0.320)
    )
    static let warningSoft = dynamic(
        light: (0.880, 0.590, 0.140),
        dark: (0.940, 0.700, 0.320),
        lightAlpha: 0.13,
        darkAlpha: 0.18
    )
    static let coral = Color(uiColor: .systemRed)

    static let contentWidth: CGFloat = 760
    static let corner: CGFloat = 20

    static func display(_ style: Font.TextStyle) -> Font {
        .system(style, weight: .semibold)
    }

    static func body(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .system(style, weight: weight)
    }
}

/// 兼容旧引用名，避免其他视图断链。
typealias MurmurTheme = AdvisorTheme

/// 悬浮液态玻璃容器：iOS 26+ 使用原生 `.glassEffect`，旧系统平滑降级为半透明毛玻璃卡片。
struct FloatingComposerSurface: ViewModifier {
    var cornerRadius: CGFloat = 24
    var isFocused: Bool = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content
                .background(AdvisorTheme.composerFill.opacity(0.45), in: shape)
                .glassEffect(.regular, in: shape)
                .overlay(
                    shape.strokeBorder(
                        isFocused ? AdvisorTheme.accentBorder : AdvisorTheme.subtleBorder,
                        lineWidth: isFocused ? 1.1 : 0.6
                    )
                )
                .shadow(color: .black.opacity(isFocused ? 0.10 : 0.06), radius: isFocused ? 16 : 10, y: 4)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(AdvisorTheme.composerFill.opacity(0.65), in: shape)
                .overlay(
                    shape.strokeBorder(
                        isFocused ? AdvisorTheme.accentBorder : AdvisorTheme.subtleBorder,
                        lineWidth: isFocused ? 1.1 : 0.6
                    )
                )
                .shadow(color: .black.opacity(isFocused ? 0.12 : 0.08), radius: isFocused ? 16 : 10, y: 4)
        }
    }
}

struct FloatingGlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(AdvisorTheme.subtleBorder, lineWidth: 0.6))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }
}

extension View {
    func floatingComposerSurface(cornerRadius: CGFloat = 24, isFocused: Bool = false) -> some View {
        modifier(FloatingComposerSurface(cornerRadius: cornerRadius, isFocused: isFocused))
    }

    func floatingGlassCircle() -> some View {
        modifier(FloatingGlassCircle())
    }

    @ViewBuilder
    func softBottomScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
    }
}

/// 成长顾问的品牌标（叶针罗盘），固定尺寸显示，避免按图片原始像素撑开布局。
struct AdvisorMark: View {
    let size: CGFloat

    var body: some View {
        Image("AdvisorMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(AdvisorTheme.subtleBorder, lineWidth: 0.75)
            }
            .accessibilityLabel("成长顾问")
    }
}
