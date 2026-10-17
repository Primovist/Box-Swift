import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct AVPlayerVideoSurface: UIViewRepresentable {
    let session: AVPlaybackSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeUIView(context: Context) -> AVPlayerHostView {
        let view = AVPlayerHostView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer.player = session.player
#if os(iOS)
        session.attachPictureInPicture(to: view.playerLayer)
#endif
        context.coordinator.hostView = view
        return view
    }
    func updateUIView(_ view: AVPlayerHostView, context: Context) {
        view.playerLayer.player = session.player
        view.playerLayer.videoGravity = session.aspectRatioLabel == "填充" ? .resizeAspectFill : .resizeAspect
    }
    static func dismantleUIView(_ view: AVPlayerHostView, coordinator: Coordinator) {
#if os(iOS)
        coordinator.session.detachPictureInPicture(from: view.playerLayer)
#endif
        view.playerLayer.player = nil
        coordinator.hostView = nil
    }
    final class Coordinator {
        let session: AVPlaybackSession
        weak var hostView: AVPlayerHostView?
        init(session: AVPlaybackSession) { self.session = session }
    }
}

final class AVPlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
