import SwiftUI
import UIKit
import VLCKit

struct VLCVideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        player.drawable = view
        context.coordinator.attachedView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.attachedView !== uiView {
            player.drawable = uiView
            context.coordinator.attachedView = uiView
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.player.drawable = nil
        coordinator.attachedView = nil
    }

    final class Coordinator {
        let player: VLCMediaPlayer
        weak var attachedView: UIView?

        init(player: VLCMediaPlayer) {
            self.player = player
        }
    }
}
