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
import UIKit

struct EdgeSwipeBackModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            NativeBackGestureEnabler()
                .frame(width: 1, height: 1)
                .opacity(0)
        }
    }
}

private struct NativeBackGestureEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        BackGestureLifecycleController(coordinator: context.coordinator)
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.attach(to: controller.navigationController)
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var navigationController: UINavigationController?
        private weak var originalDelegate: UIGestureRecognizerDelegate?

        func attach(to navigationController: UINavigationController?) {
            guard let navigationController,
                  let gesture = navigationController.interactivePopGestureRecognizer else { return }

            if self.navigationController !== navigationController {
                restore()
                self.navigationController = navigationController
                originalDelegate = gesture.delegate
                gesture.delegate = self
            } else if gesture.delegate !== self {
                originalDelegate = gesture.delegate
                gesture.delegate = self
            }
            gesture.isEnabled = navigationController.viewControllers.count > 1
        }

        func restore() {
            guard let navigationController,
                  let gesture = navigationController.interactivePopGestureRecognizer,
                  gesture.delegate === self else { return }
            gesture.isEnabled = navigationController.viewControllers.count > 1
            gesture.delegate = originalDelegate
            self.navigationController = nil
            originalDelegate = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController,
                  navigationController.viewControllers.count > 1,
                  navigationController.transitionCoordinator == nil,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: navigationController.view)
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
        }
    }
}

private final class BackGestureLifecycleController: UIViewController {
    private let coordinator: NativeBackGestureEnabler.Coordinator

    init(coordinator: NativeBackGestureEnabler.Coordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        coordinator.attach(to: navigationController)
    }
}

extension View {
    func edgeSwipeBack(width _: CGFloat) -> some View {
        modifier(EdgeSwipeBackModifier())
    }
}
#endif
