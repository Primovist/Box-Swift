import SwiftUI
import UIKit

private enum TVBoxPalette {
    #if os(iOS)
    static let background = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let muted = Color(uiColor: .secondaryLabel)
    #elseif os(tvOS)
    static let background = Color(uiColor: UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 0.04 : 0.98, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 0.12 : 0.92, alpha: 1)
    })
    static let muted = Color(uiColor: UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 0.68 : 0.34, alpha: 1)
    })
    #else
    static let background = Color.black
    static let surface = Color.gray.opacity(0.15)
    static let muted = Color.gray
    #endif
    static let accent = Color.accentColor
    static let cyan = Color.accentColor
}

struct ScreenBackground: View {
    var body: some View {
        TVBoxPalette.background
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
