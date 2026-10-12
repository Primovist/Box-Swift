import SwiftUI

struct DanmakuOverlay: View {
    @ObservedObject var session: VLCPlaybackSession
    let comments: [DanmakuComment]
    let generation: Int

    @AppStorage("tvbox.danmakuEnabled") private var isEnabled = true
    @AppStorage("tvbox.danmakuOpacity") private var opacity = 0.9
    @AppStorage("tvbox.danmakuSpeed") private var speed = 1.5
    @AppStorage("tvbox.danmakuSize") private var sizeScale = 0.8
    @AppStorage("tvbox.danmakuLines") private var maxLines = 3
    @AppStorage("tvbox.danmakuRandomColor") private var randomColor = false
    @State private var placements: [DanmakuPlacement] = []

    var body: some View {
        GeometryReader { geometry in
            let key = layoutKey(for: geometry.size)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isEnabled || !session.isDanmakuClockAdvancing || placements.isEmpty)) { _ in
                Canvas { context, size in
                    guard isEnabled, !placements.isEmpty else { return }
                    let time = session.danmakuPlaybackTime(at: ProcessInfo.processInfo.systemUptime)
                    draw(context: &context, size: size, time: time)
                }
                .clipped()
            }
            .task(id: key) {
                placements = DanmakuLayout.make(
                    comments: comments,
                    width: Double(geometry.size.width),
                    fontScale: sizeScale,
                    speed: speed,
                    maxLines: visibleLaneCount(for: geometry.size)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func layoutKey(for size: CGSize) -> String {
        "\(generation)-\(Int(size.width.rounded()))-\(Int(size.height.rounded()))-\(sizeScale)-\(speed)-\(maxLines)"
    }

    private func visibleLaneCount(for size: CGSize) -> Int {
        let portrait = size.width < size.height
        let contentHeight = Double(size.height) * (portrait ? 0.60 : 0.76)
        let laneHeight = max(23, 25 * sizeScale + 7)
        return max(1, min(maxLines, Int(contentHeight * 0.52 / laneHeight)))
    }

    private func draw(context: inout GraphicsContext, size: CGSize, time: Double) {
        let contentHeight = Double(size.height) * (size.width < size.height ? 0.60 : 0.76)
        let laneHeight = max(23, 25 * sizeScale + 7)
        let availableLanes = visibleLaneCount(for: size)
        let scrollDuration = DanmakuLayout.scrollDuration(speed: speed)

        for placement in placements {
            let comment = placement.comment
            let localTime = time / 1_000 - comment.time
            let duration: Double
            if comment.mode == .special {
                duration = comment.displayDuration
            } else if comment.mode == .fixedTop || comment.mode == .fixedBottom {
                duration = comment.displayDuration
            } else {
                duration = scrollDuration
            }
            guard localTime >= 0, localTime <= duration else { continue }

            let fontSize = DanmakuLayout.displayFontSize(comment: comment, width: Double(size.width), scale: sizeScale)
            let hue = color(for: comment)
            let font = Font.system(size: CGFloat(fontSize), weight: .semibold, design: .rounded)
            let text = Text(comment.text)
                .font(font)
                .foregroundColor(hue)
            let shadowText = Text(comment.text)
                .font(font)
                .foregroundColor(.black)
            let resolved = context.resolve(text)
            let resolvedShadow = context.resolve(shadowText)
            let measured = resolved.measure(in: CGSize(width: size.width * 3, height: size.height))
            let textWidth = max(fontSize, Double(measured.width))
            let textHeight = max(fontSize, Double(measured.height))
            let progress = min(1, max(0, localTime / max(0.1, duration)))
            let lane = placement.lane % availableLanes
            let point: CGPoint
            let commentOpacity: Double

            switch comment.mode {
            case .fixedTop:
                point = CGPoint(x: size.width / 2, y: CGFloat(14 + Double(lane) * laneHeight + textHeight / 2))
                commentOpacity = opacity
            case .fixedBottom:
                point = CGPoint(x: size.width / 2, y: CGFloat(contentHeight - 16 - Double(lane) * laneHeight - textHeight / 2))
                commentOpacity = opacity
            case .special:
                let motion = comment.motion
                let delay = motion?.delay ?? 0
                let motionProgress = min(1, max(0, (localTime - delay) / max(0.1, motion?.duration ?? duration)))
                let startX = (motion?.startX ?? 0.5) * Double(size.width)
                let startY = (motion?.startY ?? 0.5) * contentHeight
                let endX = (motion?.endX ?? motion?.startX ?? 0.5) * Double(size.width)
                let endY = (motion?.endY ?? motion?.startY ?? 0.5) * contentHeight
                point = CGPoint(
                    x: CGFloat(startX + (endX - startX) * motionProgress),
                    y: CGFloat(startY + (endY - startY) * motionProgress)
                )
                if let motion {
                    commentOpacity = opacity * (motion.startAlpha + (motion.endAlpha - motion.startAlpha) * motionProgress)
                } else {
                    commentOpacity = opacity
                }
            case .scrollLeftToRight, .reverse:
                let left = -textWidth / 2
                let right = Double(size.width) + textWidth / 2
                let y = Double(size.height) * 0.16 + Double(lane) * laneHeight + textHeight / 2
                point = CGPoint(x: CGFloat(left + (right - left) * progress), y: CGFloat(y))
                commentOpacity = opacity
            case .scrollRightToLeft, .unknown:
                let left = -textWidth / 2
                let right = Double(size.width) + textWidth / 2
                let y = Double(size.height) * 0.16 + Double(lane) * laneHeight + textHeight / 2
                point = CGPoint(x: CGFloat(right - (right - left) * progress), y: CGFloat(y))
                commentOpacity = opacity
            }

            var layer = context
            layer.opacity = min(1, max(0, commentOpacity))
            layer.draw(
                resolvedShadow,
                at: CGPoint(x: point.x + 1, y: point.y + 1),
                anchor: .center
            )
            layer.draw(resolved, at: point, anchor: .center)
        }
    }

    private func color(for comment: DanmakuComment) -> Color {
        if randomColor {
            let hue = Double((comment.id &* 37) % 360) / 360
            return Color(hue: hue, saturation: 0.84, brightness: 1)
        }
        let red = Double((comment.color >> 16) & 0xFF) / 255
        let green = Double((comment.color >> 8) & 0xFF) / 255
        let blue = Double(comment.color & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}
