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
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        player.drawable = uiView
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.player.drawable = nil
    }

    final class Coordinator {
        let player: VLCMediaPlayer

        init(player: VLCMediaPlayer) {
            self.player = player
        }
    }
}
