import SwiftUI
import UIKit

struct KSPlayerVideoSurface: UIViewRepresentable {
    let session: KSPlaybackSession

    func makeUIView(context: Context) -> KSPlayerHostView {
        let view = KSPlayerHostView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        context.coordinator.hostView = view
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: KSPlayerHostView, context: Context) {
        guard let playerView = session.playerLayer.player.view else { return }
        if view.playerView !== playerView {
            view.playerView?.removeFromSuperview()
            view.playerView = playerView
            playerView.removeFromSuperview()
            playerView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(playerView)
            NSLayoutConstraint.activate([
                playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                playerView.topAnchor.constraint(equalTo: view.topAnchor),
                playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        playerView.contentMode = session.aspectRatioLabel == "填充" ? .scaleAspectFill : .scaleAspectFit
    }

    static func dismantleUIView(_ view: KSPlayerHostView, coordinator: Coordinator) {
        view.playerView?.removeFromSuperview()
        view.playerView = nil
        coordinator.hostView = nil
    }

    final class Coordinator {
        weak var hostView: KSPlayerHostView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}

final class KSPlayerHostView: UIView {
    var playerView: UIView?
}
