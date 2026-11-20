import SwiftUI

// MARK: - Liquid Glass design system
//
// macOS 26+ gets Apple's Liquid Glass (`glassEffect`, `.glass` button styles).
// Older systems fall back to translucent materials so the app still looks right.

extension View {
    /// A floating glass surface (cards, panels, rows).
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint?.opacity(0.18)).interactive(interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .background(tint?.opacity(0.08) ?? .clear, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }

    /// A small glass capsule (chips, badges, toolbars).
    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint?.opacity(0.25)), in: Capsule())
        } else {
            self.background(.thinMaterial, in: Capsule())
                .background(tint?.opacity(0.12) ?? .clear, in: Capsule())
        }
    }

    /// Liquid Glass buttons; `prominent` for the main action on a screen.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// Groups nearby glass shapes so they blend like Apple's controls (no-op before macOS 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Soft color field behind the content so glass has something to refract.
/// Static on purpose — an animated background forced a layout pass every frame.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.indigo.opacity(scheme == .dark ? 0.38 : 0.20), .clear],
                           center: UnitPoint(x: 0.12, y: 0.08), startRadius: 0, endRadius: 650)
            RadialGradient(colors: [Color.teal.opacity(scheme == .dark ? 0.30 : 0.16), .clear],
                           center: UnitPoint(x: 0.95, y: 0.3), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color.purple.opacity(scheme == .dark ? 0.34 : 0.18), .clear],
                           center: UnitPoint(x: 0.55, y: 1.05), startRadius: 0, endRadius: 600)
        }
        .drawingGroup()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

}

/// Large rounded numerals used for headline stats.
struct StatText: View {
    let value: String
    var body: some View {
        Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
    }
}

/// A rounded SF Symbol tile, like the icons in System Settings.
struct SymbolTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .shadow(color: color.opacity(0.35), radius: 6, y: 2)
    }
}
