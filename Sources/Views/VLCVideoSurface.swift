import SwiftUI
import UIKit
import VLCKit

struct VLCVideoSurface: UIViewRepresentable {
    let session: VLCPlaybackSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> UIView {
        let view = VLCVideoHostView(frame: .zero)
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        let drawable = VLCVideoDrawable(hostView: view, session: session)
        context.coordinator.drawable = drawable
#if os(iOS)
        session.registerPictureInPictureDrawable(drawable.id)
#endif
        session.player.drawable = drawable
        context.coordinator.attachedView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.attachedView !== uiView,
           let drawable = context.coordinator.drawable {
            session.player.drawable = drawable
            context.coordinator.attachedView = uiView
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
#if os(iOS)
        coordinator.session.detachVideoSurface()
#endif
        if let drawable = coordinator.drawable,
           (coordinator.session.player.drawable as? VLCVideoDrawable) === drawable {
            coordinator.session.player.drawable = nil
        }
        if coordinator.attachedView === uiView {
            coordinator.attachedView = nil
        }
        coordinator.drawable = nil
    }

    final class Coordinator {
        let session: VLCPlaybackSession
        fileprivate var drawable: VLCVideoDrawable?
        weak var attachedView: UIView?

        init(session: VLCPlaybackSession) {
            self.session = session
        }
    }
}

fileprivate final class VLCVideoDrawable: NSObject, VLCDrawable {
    let id = UUID()
    private let hostView: VLCVideoHostView
    private weak var session: VLCPlaybackSession?

    init(hostView: VLCVideoHostView, session: VLCPlaybackSession) {
        self.hostView = hostView
        self.session = session
        super.init()
    }

    func addSubview(_ view: UIView) {
        view.frame = hostView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.videoView = view
        hostView.addSubview(view)
    }

    func bounds() -> CGRect {
        hostView.bounds
    }
}

private final class VLCVideoHostView: UIView {
    weak var videoView: UIView?

    override func layoutSubviews() {
        super.layoutSubviews()
        videoView?.frame = bounds
    }
}

#if os(iOS)
extension VLCVideoDrawable: VLCPictureInPictureDrawable {
    func mediaController() -> VLCPictureInPictureMediaControlling {
        session ?? InactivePictureInPictureMediaController.shared
    }

    func pictureInPictureReady() -> ((VLCPictureInPictureWindowControlling?) -> Void)? {
        let drawableID = id
        return { [weak session] controller in
            guard let controller else { return }
            Task { @MainActor [weak session] in
                session?.pictureInPictureReady(controller, drawableID: drawableID)
            }
        }
    }
}
#endif

#if os(iOS)
private final class InactivePictureInPictureMediaController: NSObject, VLCPictureInPictureMediaControlling {
    static let shared = InactivePictureInPictureMediaController()

    func play() {}
    func pause() {}
    func seek(by offset: Int64, completion: @escaping () -> Void) { completion() }
    func mediaLength() -> Int64 { 0 }
    func mediaTime() -> Int64 { 0 }
    func isMediaSeekable() -> Bool { false }
    func isMediaPlaying() -> Bool { false }
}
#endif
