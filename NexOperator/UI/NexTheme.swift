import SwiftUI

enum NexTheme {
    // Base - System adaptive colors
    static let bg = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceHover = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let border = Color(nsColor: .separatorColor)

    // Text - System semantic colors
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary

    // Hit targets & spacing (Apple HIG: min 44pt, we use 28-32 for compact UI)
    static let hitTargetSmall: CGFloat = 28
    static let hitTargetMedium: CGFloat = 32
    static let hitTargetLarge: CGFloat = 36
    static let dragHandleThickness: CGFloat = 8
    static let buttonSpacing: CGFloat = 6
    static let iconSizeSmall: CGFloat = 12
    static let iconSizeMedium: CGFloat = 14

    // Accent - Uses system accent color (configurable in System Settings)
    static let accent = Color.accentColor
    static let accentLight = Color.accentColor.opacity(0.8)
    static let accentDim = Color.accentColor.opacity(0.1)
    static let accentGradient = LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

struct GlassBackground: ViewModifier {
    var material: Material = .bar

    func body(content: Content) -> some View {
        content
            .background(material)
            .overlay(
                Rectangle()
                    .stroke(NexTheme.border, lineWidth: 0.5)
            )
    }
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(NexTheme.border, lineWidth: 0.5)
                    )
            )
    }
}

extension View {
    func glassBackground(material: Material = .bar) -> some View {
        modifier(GlassBackground(material: material))
    }

    func glassCard(cornerRadius: CGFloat = 8) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}
