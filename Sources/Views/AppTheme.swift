import SwiftUI

private enum TVBoxPalette {
    static let background = Color(red: 0.035, green: 0.045, blue: 0.065)
    static let surface = Color(red: 0.085, green: 0.105, blue: 0.14)
    static let muted = Color(red: 0.58, green: 0.63, blue: 0.71)
    static let accent = Color(red: 1.0, green: 0.27, blue: 0.31)
    static let cyan = Color(red: 0.27, green: 0.83, blue: 0.88)
}

struct ScreenBackground: View {
    var body: some View {
        ZStack {
            TVBoxPalette.background
            LinearGradient(
                colors: [TVBoxPalette.accent.opacity(0.12), .clear, TVBoxPalette.cyan.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct SectionEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(2.2)
            .foregroundStyle(TVBoxPalette.cyan)
    }
}

struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(TVBoxPalette.accent.gradient, in: Capsule())
            .overlay(Capsule().strokeBorder(isFocused ? .white.opacity(0.9) : .clear, lineWidth: 2).padding(-2))
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.04 : 1))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

struct FocusAwareButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isFocused ? .white.opacity(0.9) : .clear, lineWidth: 2).padding(-2))
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.035 : 1))
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.13), value: isFocused)
    }
}

extension Color {
    static var tvboxBackground: Color { TVBoxPalette.background }
    static var tvboxSurface: Color { TVBoxPalette.surface }
    static var tvboxMuted: Color { TVBoxPalette.muted }
    static var tvboxAccent: Color { TVBoxPalette.accent }
    static var tvboxCyan: Color { TVBoxPalette.cyan }
}

#if os(iOS)
struct EdgeSwipeBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var dragOffset: CGFloat = 0
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: dragOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .local)
                    .onChanged { value in
                        guard value.startLocation.x <= 28,
                              value.translation.width > 0,
                              value.translation.width > abs(value.translation.height) else { return }
                        dragOffset = min(width, value.translation.width)
                    }
                    .onEnded { value in
                        let isEdgeSwipe = value.startLocation.x <= 28
                            && value.translation.width > 0
                            && value.translation.width > abs(value.translation.height)
                        guard isEdgeSwipe else {
                            dragOffset = 0
                            return
                        }

                        if value.translation.width > width * 0.30 || value.predictedEndTranslation.width > width * 0.42 {
                            withAnimation(.easeOut(duration: 0.18)) { dragOffset = width }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { dismiss() }
                        } else {
                            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.88)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
    }
}

extension View {
    func edgeSwipeBack(width: CGFloat) -> some View {
        modifier(EdgeSwipeBackModifier(width: width))
    }
}
#endif
