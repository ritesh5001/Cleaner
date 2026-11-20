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

/// Soft, slowly drifting color field behind the content so glass has something to refract.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { context in
            let t = context.date.timeIntervalSinceReferenceDate / 18
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    blob(.indigo, size: max(w, h) * 0.75)
                        .position(x: w * (0.15 + 0.08 * sin(t)), y: h * (0.12 + 0.06 * cos(t * 0.8)))
                    blob(.teal, size: max(w, h) * 0.6)
                        .position(x: w * (0.9 + 0.06 * cos(t * 0.7)), y: h * (0.3 + 0.08 * sin(t * 0.9)))
                    blob(.purple, size: max(w, h) * 0.7)
                        .position(x: w * (0.55 + 0.1 * sin(t * 0.6)), y: h * (1.0 + 0.05 * cos(t)))
                }
            }
        }
        .ignoresSafeArea()
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(scheme == .dark ? 0.38 : 0.22), .clear],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .blur(radius: 40)
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
