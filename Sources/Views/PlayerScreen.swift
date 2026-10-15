import SwiftUI
import Combine
import VLCKit
#if os(iOS)
import UIKit
import MediaPlayer
import AVFAudio
#endif

struct VLCTrackOption: Identifiable, Hashable {
    let index: Int
    let title: String

    var id: Int { index }
}

private struct PlayerMenuOption: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
}

private struct AspectRatioOption: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

private enum PlayerTouchGesture: Equatable {
    case seek
    case brightness
    case volume
    case ignored
}

private enum LivePlayerPanel: String, Equatable, Identifiable {
    case guide = "节目单"
    case sources = "线路"
    case playlist = "片源与选集"

    var id: String { rawValue }
}

private enum LivePortraitTab: String, CaseIterable, Identifiable {
    case groups = "分类"
    case channels = "频道"
    case programs = "节目"
    case sources = "线路"

    var id: String { rawValue }
}

#if os(iOS)
@MainActor
private final class SystemVolumeController: ObservableObject {
    private weak var volumeView: MPVolumeView?
    private weak var slider: UISlider?

    var volume: Double {
        Double(AVAudioSession.sharedInstance().outputVolume) * 100
    }

    func attach(to volumeView: MPVolumeView) {
        self.volumeView = volumeView
        slider = findVolumeSlider(in: volumeView)
    }

    func setVolume(_ value: Double) {
        if slider == nil, let volumeView { attach(to: volumeView) }
        guard let slider else { return }
        slider.setValue(Float(min(1, max(0, value / 100))), animated: false)
        slider.sendActions(for: .valueChanged)
    }

    private func findVolumeSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let slider = findVolumeSlider(in: subview) { return slider }
        }
        return nil
    }
}

private struct SystemVolumeControl: UIViewRepresentable {
    let controller: SystemVolumeController

    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        controller.attach(to: volumeView)
        let controller = self.controller
        Task { @MainActor [weak volumeView, weak controller] in
            await Task.yield()
            if let volumeView { controller?.attach(to: volumeView) }
        }
        return volumeView
    }

    func updateUIView(_ volumeView: MPVolumeView, context: Context) {
        controller.attach(to: volumeView)
    }
}
#endif

@MainActor
final class DanmakuPlaybackClock: ObservableObject {
    @Published private(set) var isAdvancing = false
    @Published private(set) var revision = 0

    private var positionMilliseconds: Double = 0
    private var anchorUptime = ProcessInfo.processInfo.systemUptime
    private var playbackRate = 1.0
    private var rateAdjustmentMillisecondsPerSecond = 0.0
    private var hasReceivedMediaSample = false

    func time(at uptime: TimeInterval) -> Double {
        guard isAdvancing else { return max(0, positionMilliseconds) }
        let elapsed = max(0, uptime - anchorUptime)
        let rate = max(0, playbackRate * 1_000 + rateAdjustmentMillisecondsPerSecond)
        return max(0, positionMilliseconds + elapsed * rate)
    }

    func setAdvancing(_ advancing: Bool, at uptime: TimeInterval) {
        let current = time(at: uptime)
        guard isAdvancing != advancing else { return }
        isAdvancing = advancing
        rateAdjustmentMillisecondsPerSecond = 0
        anchor(to: current, at: uptime)
    }

    func setPlaybackRate(_ rate: Float, at uptime: TimeInterval) {
        let current = time(at: uptime)
        playbackRate = Double(rate)
        rateAdjustmentMillisecondsPerSecond = 0
        anchor(to: current, at: uptime)
    }

    func anchor(to milliseconds: Double, at uptime: TimeInterval, resetRate: Bool = false) {
        positionMilliseconds = max(0, milliseconds)
        anchorUptime = uptime
        if resetRate {
            rateAdjustmentMillisecondsPerSecond = 0
            revision &+= 1
        }
    }

    func resetSampleSynchronization() {
        hasReceivedMediaSample = false
    }

    func reconcile(with sample: Double, at uptime: TimeInterval) {
        guard isAdvancing else { return }
        guard hasReceivedMediaSample else {
            hasReceivedMediaSample = true
            anchor(to: sample, at: uptime, resetRate: true)
            return
        }
        let predicted = time(at: uptime)
        let error = sample - predicted
        let deadZone = 24.0
        let targetAdjustment: Double
        if abs(error) <= deadZone {
            targetAdjustment = 0
        } else {
            targetAdjustment = min(40, max(-40, error * 0.16))
        }
        rateAdjustmentMillisecondsPerSecond += (targetAdjustment - rateAdjustmentMillisecondsPerSecond) * 0.2
        anchor(to: predicted, at: uptime)
    }
}

@MainActor
final class VLCPlaybackSession: NSObject, ObservableObject, VLCMediaPlayerDelegate, VLCPictureInPictureMediaControlling {
    @Published private(set) var status = "准备连接"
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackRequested = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsedText = "00:00"
    @Published private(set) var durationText = "--:--"
    @Published private(set) var currentMilliseconds = 0
    @Published private(set) var playbackGeneration = 0
    @Published private(set) var canSeek = false
    @Published private(set) var canSeekByTime = false
    @Published private(set) var title = ""
    @Published private(set) var audioTracks: [VLCTrackOption] = []
    @Published private(set) var subtitleTracks: [VLCTrackOption] = []
    @Published private(set) var selectedAudioTrackIndex = -1
    @Published private(set) var selectedSubtitleTrackIndex = -1
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var didReachEnd = false
    @Published private(set) var aspectRatioLabel = "原始"
#if os(iOS)
    @Published private(set) var isPictureInPictureReady = false
    @Published private(set) var isPictureInPictureActive = false
#endif

    let player: VLCMediaPlayer
    let danmakuClock = DanmakuPlaybackClock()
    private(set) var request: PlaybackRequest
    private var progressTimer: Timer?
    private var catchupTimelineOffsetMilliseconds = 0
    private var isAwaitingCatchupMediaSample = false
    private var isDanmakuBuffering = false
    private var pendingDanmakuSeekTargetMilliseconds: Double?
    private var pendingPositionSeekTargetFraction: Double?
    private var pendingPositionSeekOriginFraction: Double?
    private var pendingPositionSeekOriginMilliseconds: Double?
    private var pendingDanmakuSeekStartedAt: TimeInterval?
    private var lateDanmakuSeekTargetMilliseconds: Double?
    private var lateDanmakuSeekOriginMilliseconds: Double?
    private var lateDanmakuSeekLastSampleMilliseconds: Double?
    private var lateDanmakuSeekLastSampleUptime: TimeInterval?
    private var latePositionSeekTargetFraction: Double?
    private var latePositionSeekOriginFraction: Double?
    private var latePositionSeekOriginMilliseconds: Double?
    private var danmakuSeekOriginMilliseconds: Double?
    private var danmakuSeekLastSampleMilliseconds: Double?
    private var danmakuSeekLastSampleUptime: TimeInterval?
    private var didApplyResumePosition = false
    private var reportedDurationMilliseconds = 0
    private var aspectRatio: String?
    private var ignoreNextStoppedEvent = false
    private var observedNearEnd = false
#if os(iOS)
    private weak var pictureInPictureController: VLCPictureInPictureWindowControlling?
    private var pictureInPictureDrawableID: UUID?
    private var pictureInPictureControllerID: ObjectIdentifier?
#endif

    init(request: PlaybackRequest) {
        self.request = request
        title = request.title
        player = VLCMediaPlayer(options: ["--hw-dec"])
        super.init()
        player.delegate = self
#if os(iOS)
        configureAudioSession()
#endif
        player.media = makeMedia()
        parseMediaIfNeeded()
        refreshProgress()
        startProgressUpdates()
    }

    func play() {
        guard player.media != nil else {
            status = "播放失败"
            return
        }
        playbackRequested = true
        status = "正在连接…"
        player.play()
        startProgressUpdates()
    }

    func retry() {
        ignoreNextStoppedEvent = true
        observedNearEnd = false
        reportedDurationMilliseconds = 0
        player.stop()
        player.media = makeMedia()
        isAwaitingCatchupMediaSample = request.catchupWindow != nil
        parseMediaIfNeeded()
        setAspectRatio(aspectRatio, label: aspectRatioLabel)
        progress = request.durationMilliseconds > 0
            ? min(1, Double(catchupTimelineOffsetMilliseconds) / Double(request.durationMilliseconds))
            : 0
        currentMilliseconds = catchupTimelineOffsetMilliseconds
        elapsedText = Self.clockString(milliseconds: Int32(clamping: catchupTimelineOffsetMilliseconds))
        durationText = request.isLive ? "LIVE" : "--:--"
        canSeek = false
        canSeekByTime = false
        didReachEnd = false
        didApplyResumePosition = false
        danmakuClock.resetSampleSynchronization()
        resetDanmakuClock(to: catchupTimelineOffsetMilliseconds, awaitingPlayerSample: true)
        play()
    }

    func replace(with request: PlaybackRequest) {
        replace(with: request, catchupOffsetMilliseconds: 0)
    }

    private func replace(with request: PlaybackRequest, catchupOffsetMilliseconds: Int, autoplay: Bool = true) {
        progressTimer?.invalidate()
        progressTimer = nil
        ignoreNextStoppedEvent = true
        observedNearEnd = false
        reportedDurationMilliseconds = 0
        player.stop()
        self.request = request
        self.catchupTimelineOffsetMilliseconds = max(0, catchupOffsetMilliseconds)
        self.isAwaitingCatchupMediaSample = request.catchupWindow != nil
        playbackGeneration += 1
        title = request.title
        status = "正在连接…"
        isPlaying = false
        playbackRequested = false
        progress = request.durationMilliseconds > 0
            ? min(1, Double(self.catchupTimelineOffsetMilliseconds) / Double(request.durationMilliseconds))
            : 0
        currentMilliseconds = self.catchupTimelineOffsetMilliseconds
        elapsedText = Self.clockString(milliseconds: Int32(clamping: self.catchupTimelineOffsetMilliseconds))
        durationText = request.isLive ? "LIVE" : "--:--"
        canSeek = false
        canSeekByTime = false
        didReachEnd = false
        updateDanmakuClockPlaybackState(isPlaying: false, isBuffering: false)
        danmakuClock.resetSampleSynchronization()
        resetDanmakuClock(to: self.catchupTimelineOffsetMilliseconds, awaitingPlayerSample: true)
        audioTracks = []
        subtitleTracks = []
        didApplyResumePosition = false
        player.media = makeMedia()
        parseMediaIfNeeded()
        setAspectRatio(aspectRatio, label: aspectRatioLabel)
        if autoplay {
            play()
        } else {
            status = "已暂停"
            startProgressUpdates()
        }
    }

    func togglePlayback() {
        if playbackRequested || isPlaying {
            pause()
        } else {
            player.play()
            playbackRequested = true
            updateDanmakuClockPlaybackState(isPlaying: true, isBuffering: false)
            status = "正在播放"
        }
        refreshProgress()
    }

    func pause() {
        guard playbackRequested || isPlaying else { return }
        playbackRequested = false
        player.pause()
        updateDanmakuClockPlaybackState(isPlaying: false, isBuffering: false)
        status = "已暂停"
        refreshProgress()
    }

    func seek(by seconds: Int) {
        guard canSeekByTime else { return }
        let duration = totalDurationMilliseconds
        let origin = currentPlaybackMilliseconds
        let target = min(duration, max(0, origin + seconds * 1_000))
        guard seekCatchupIfNeeded(to: target) else {
            player.time = VLCTime(int: Int32(clamping: max(0, target - catchupTimelineOffsetMilliseconds)))
            resetDanmakuClock(to: target, awaitingPlayerSample: true, originMilliseconds: origin)
            refreshProgress()
            return
        }
    }

    private var currentPlaybackMilliseconds: Int {
        guard !isAwaitingCatchupMediaSample else { return catchupTimelineOffsetMilliseconds }
        let localTime = max(0, Int(player.time.intValue))
        return max(0, catchupTimelineOffsetMilliseconds + localTime)
    }

    /// Restarts a non-seekable catch-up stream at a new server-side start time.
    /// Returns true when the catch-up URL was rebuilt and playback was replaced.
    private func seekCatchupIfNeeded(to targetMilliseconds: Int) -> Bool {
        guard let window = request.catchupWindow,
              (!player.isSeekable || targetMilliseconds < catchupTimelineOffsetMilliseconds),
              window.supportsServerSeeking else { return false }
        let offset = min(max(0, targetMilliseconds), max(0, window.durationMilliseconds - 1_000))
        guard let url = window.url(startingAtMilliseconds: offset) else { return false }
        let shouldResume = playbackRequested || isPlaying
        replace(
            with: request.replacing(url: url),
            catchupOffsetMilliseconds: offset,
            autoplay: shouldResume
        )
        return true
    }

    func seek(to fraction: Double) {
        guard canSeek else { return }
        let duration = totalDurationMilliseconds
        let boundedFraction = min(1, max(0, fraction))
        guard duration > 0 || player.isSeekable else { return }
        guard duration > 0 else {
            clearPendingDanmakuSeek()
            clearLateDanmakuSeek()
            clearPositionSeek()
            pendingPositionSeekTargetFraction = boundedFraction
            pendingPositionSeekOriginFraction = Double(player.position)
            pendingPositionSeekOriginMilliseconds = Double(currentPlaybackMilliseconds)
            pendingDanmakuSeekStartedAt = ProcessInfo.processInfo.systemUptime
            player.position = boundedFraction
            refreshProgress()
            return
        }
        let target = Int(Double(duration) * boundedFraction)
        let origin = currentPlaybackMilliseconds
        guard seekCatchupIfNeeded(to: target) else {
            player.time = VLCTime(int: Int32(clamping: max(0, target - catchupTimelineOffsetMilliseconds)))
            resetDanmakuClock(to: target, awaitingPlayerSample: true, originMilliseconds: origin)
            refreshProgress()
            return
        }
    }

    func selectAudioTrack(_ index: Int) {
        let tracks = player.audioTracks
        guard tracks.indices.contains(index) else { return }
        tracks[index].isSelectedExclusively = true
        selectedAudioTrackIndex = index
    }

    func selectSubtitleTrack(_ index: Int) {
        if index < 0 {
            player.deselectAllTextTracks()
        } else {
            let tracks = player.textTracks
            guard tracks.indices.contains(index) else { return }
            tracks[index].isSelectedExclusively = true
        }
        selectedSubtitleTrackIndex = index
    }

    func setPlaybackRate(_ rate: Float) {
        refreshProgress()
        let now = ProcessInfo.processInfo.systemUptime
        player.rate = rate
        playbackRate = rate
        danmakuClock.setPlaybackRate(rate, at: now)
    }

    func setAspectRatio(_ ratio: String?, label: String) {
        aspectRatio = ratio
        aspectRatioLabel = label
        guard let ratio else {
            player.videoAspectRatio = nil
            return
        }
        player.videoAspectRatio = ratio
    }

    func stop() {
#if os(iOS)
        if isPictureInPictureReady { pictureInPictureController?.stopPictureInPicture() }
#endif
        progressTimer?.invalidate()
        progressTimer = nil
        ignoreNextStoppedEvent = true
        playbackRequested = false
        player.stop()
        updateDanmakuClockPlaybackState(isPlaying: false, isBuffering: false)
        player.drawable = nil
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isPictureInPictureReady = false
        isPictureInPictureActive = false
        pictureInPictureController = nil
        pictureInPictureDrawableID = nil
        pictureInPictureControllerID = nil
#endif
    }

#if os(iOS)
    func detachVideoSurface() {
        if isPictureInPictureReady { pictureInPictureController?.stopPictureInPicture() }
        isPictureInPictureReady = false
        isPictureInPictureActive = false
        pictureInPictureController = nil
        pictureInPictureDrawableID = nil
        pictureInPictureControllerID = nil
        player.drawable = nil
    }

    func registerPictureInPictureDrawable(_ id: UUID) {
        pictureInPictureDrawableID = id
        isPictureInPictureReady = false
        pictureInPictureController = nil
    }

    func pictureInPictureReady(_ controller: VLCPictureInPictureWindowControlling, drawableID: UUID) {
        guard pictureInPictureDrawableID == drawableID else { return }
        pictureInPictureController = controller
        let controllerID = ObjectIdentifier(controller)
        pictureInPictureControllerID = controllerID
        controller.stateChangeEventHandler = { [weak self] isStarted in
            Task { @MainActor [weak self] in
                self?.pictureInPictureStateChanged(
                    isStarted,
                    drawableID: drawableID,
                    controllerID: controllerID
                )
            }
        }
        isPictureInPictureReady = true
        controller.invalidatePlaybackState()
    }

    func startPictureInPicture() {
        guard isPictureInPictureReady else { return }
        pictureInPictureController?.startPictureInPicture()
    }

    private func pictureInPictureStateChanged(
        _ isActive: Bool,
        drawableID: UUID,
        controllerID: ObjectIdentifier
    ) {
        guard pictureInPictureDrawableID == drawableID,
              pictureInPictureControllerID == controllerID else { return }
        isPictureInPictureActive = isActive
        pictureInPictureController?.invalidatePlaybackState()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            status = "音频会话配置失败：\(error.localizedDescription)"
        }
    }

#endif

    func seek(by offset: Int64, completion: @escaping () -> Void) {
        guard canSeekByTime else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        let origin = currentPlaybackMilliseconds
        let target = max(0, min(totalDurationMilliseconds, origin + Int(offset)))
        if seekCatchupIfNeeded(to: target) {
            DispatchQueue.main.async(execute: completion)
            return
        }
        let started = player.jump(withOffset: Int32(clamping: target - origin), completion: completion)
        guard started else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        resetDanmakuClock(to: target, awaitingPlayerSample: true, originMilliseconds: origin)
    }
    func mediaLength() -> Int64 { Int64(totalDurationMilliseconds) }
    func mediaTime() -> Int64 { Int64(currentPlaybackMilliseconds) }
    func isMediaSeekable() -> Bool { canSeekByTime }
    func isMediaPlaying() -> Bool { isPlaying }

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            self?.refreshState(newState)
#if os(iOS)
            self?.pictureInPictureController?.invalidatePlaybackState()
#endif
        }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor [weak self] in
            guard let self, !self.request.isLive, length > 0 else { return }
            self.reportedDurationMilliseconds = Int(clamping: length)
            self.refreshProgress()
#if os(iOS)
            self.pictureInPictureController?.invalidatePlaybackState()
#endif
        }
    }

    nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let percentage = progress <= 1 ? progress * 100 : progress
            let buffering = percentage < 99.5
            self.updateDanmakuClockPlaybackState(isBuffering: buffering)
            self.status = buffering
                ? String(format: "正在缓冲 %.0f%%", percentage)
                : (self.isPlaying ? "正在播放" : "已暂停")
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let isActuallyPlaying: Bool
            if case .playing = self.player.state {
                isActuallyPlaying = true
            } else {
                isActuallyPlaying = false
            }
            if self.isAwaitingCatchupMediaSample, self.playbackRequested, isActuallyPlaying {
                self.isAwaitingCatchupMediaSample = false
            }
            self.refreshProgress()
        }
    }

    private func makeMedia() -> VLCMedia? {
        guard let media = VLCMedia(url: request.url) else { return nil }
        if let userAgent = header(named: "User-Agent") {
            media.addOption(":http-user-agent=\(userAgent)")
        }
        if let referer = header(named: "Referer") {
            media.addOption(":http-referrer=\(referer)")
        }
        for (name, value) in request.headers where
            !["user-agent", "referer", "referrer"].contains(name.lowercased()) {
            if name.caseInsensitiveCompare("Cookie") == .orderedSame {
                media.addOption(":http-cookie=\(value)")
            } else {
                media.addOption(":http-header=\(name): \(value)")
            }
        }
        return media
    }

    private func parseMediaIfNeeded() {
        guard !request.isLive, let media = player.media else { return }
        _ = VLCMediaParser.shared().queue(media, options: VLCMediaParsingOptions(rawValue: 1))
    }

    private func header(named name: String) -> String? {
        request.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func startProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshProgress() }
        }
    }

    private func refreshState(_ state: VLCMediaPlayerState) {
        switch state {
        case .playing:
            guard playbackRequested else {
                player.pause()
                status = "已暂停"
                updateDanmakuClockPlaybackState(isPlaying: false, isBuffering: false)
                refreshProgress()
                return
            }
            status = "正在播放"
            updateDanmakuClockPlaybackState(isPlaying: true, isBuffering: false)
            ignoreNextStoppedEvent = false
            observedNearEnd = false
            refreshTracks()
        case .paused:
            guard !playbackRequested else { break }
            status = "已暂停"
            updateDanmakuClockPlaybackState(isPlaying: false, isBuffering: false)
        case .opening:
            guard playbackRequested else { break }
            status = "正在缓冲…"
            updateDanmakuClockPlaybackState(isBuffering: true)
        case .stopping:
            guard !playbackRequested else { break }
            status = "正在停止…"
            updateDanmakuClockPlaybackState(isPlaying: false, isBuffering: false)
        case .stopped:
            guard case .stopped = player.state else {
                if ignoreNextStoppedEvent { ignoreNextStoppedEvent = false }
                break
            }
            if ignoreNextStoppedEvent {
                ignoreNextStoppedEvent = false
                if !playbackRequested {
                    status = "已停止"
                    updateDanmakuClockPlaybackState(isPlaying: false, isBuffering: false)
                }
            } else {
                playbackRequested = false
                let reachedEnd = !request.isLive && isAtEndOrObservedNearEnd
                status = reachedEnd ? "播放结束" : "已停止"
                updateDanmakuClockPlaybackState(isPlaying: false, isBuffering: false)
                if reachedEnd { didReachEnd = true }
            }
        case .error:
            playbackRequested = false
            status = "播放失败"
            updateDanmakuClockPlaybackState(isPlaying: false, isBuffering: false)
        default:
            status = "准备连接"
        }
        refreshProgress()
    }

    private func refreshTracks() {
        let audio = player.audioTracks
        audioTracks = audio.enumerated().map { index, track in
            VLCTrackOption(index: index, title: track.trackName)
        }
        selectedAudioTrackIndex = audio.firstIndex(where: \.isSelected) ?? -1

        let subtitles = player.textTracks
        var choices = [VLCTrackOption(index: -1, title: "关闭字幕")]
        choices.append(contentsOf: subtitles.enumerated().map { index, track in
            VLCTrackOption(index: index, title: track.trackName)
        })
        subtitleTracks = choices
        selectedSubtitleTrackIndex = subtitles.firstIndex(where: \.isSelected) ?? -1
    }

    private func refreshProgress() {
        if !didApplyResumePosition, isPlaying, player.isSeekable {
            didApplyResumePosition = true
            let target = request.resumeMilliseconds > 0
                ? request.resumeMilliseconds
                : request.skipOpeningMilliseconds
            if target > 0 {
                let duration = totalDurationMilliseconds
                let position = duration > 0 ? min(target, max(0, duration - 1_000)) : target
                let origin = currentPlaybackMilliseconds
                player.time = VLCTime(int: Int32(clamping: max(0, position - catchupTimelineOffsetMilliseconds)))
                resetDanmakuClock(to: position, awaitingPlayerSample: true, originMilliseconds: origin)
            }
        }
        let current = currentPlaybackMilliseconds
        updateDanmakuClock(with: Int32(clamping: current))
        let total = totalDurationMilliseconds
        if isPlaying {
            observedNearEnd = !request.isLive && total > 0 && Int(current) >= Int(total) - 1_500
        }
        let currentValue = Int(current)
        if currentMilliseconds != currentValue { currentMilliseconds = currentValue }
        let elapsedValue = Self.clockString(milliseconds: Int32(clamping: current))
        if elapsedText != elapsedValue { elapsedText = elapsedValue }
        let durationValue = total > 0 ? Self.clockString(milliseconds: Int32(clamping: total)) : (request.isLive ? "LIVE" : "--:--")
        if durationText != durationValue { durationText = durationValue }
        let progressValue = total > 0
            ? min(1, Double(current) / Double(total))
            : (player.isSeekable && !request.isLive ? min(1, max(0, Double(player.position))) : 0)
        if abs(progress - progressValue) > 0.0001 { progress = progressValue }
        let canSeekValue = !request.isLive
            && (player.isSeekable || request.catchupWindow?.supportsServerSeeking == true)
        if canSeek != canSeekValue { canSeek = canSeekValue }
        let canSeekByTimeValue = !request.isLive && total > 0
            && (player.isSeekable || request.catchupWindow?.supportsServerSeeking == true)
        if canSeekByTime != canSeekByTimeValue { canSeekByTime = canSeekByTimeValue }
    }

    private func updateDanmakuClock(with sampledMilliseconds: Int32) {
        let now = ProcessInfo.processInfo.systemUptime
        let sample = Double(max(0, sampledMilliseconds))

        if let target = pendingPositionSeekTargetFraction,
           let originFraction = pendingPositionSeekOriginFraction,
           let originMilliseconds = pendingPositionSeekOriginMilliseconds {
            let elapsed = now - (pendingDanmakuSeekStartedAt ?? now)
            if positionSeekLanded(
                targetFraction: target,
                originFraction: originFraction,
                originMilliseconds: originMilliseconds,
                elapsed: elapsed,
                sampledMilliseconds: sample
            ) {
                clearPositionSeek()
                anchorDanmakuClock(to: sample, at: now)
                return
            }
            if elapsed >= 3 {
                latePositionSeekTargetFraction = target
                latePositionSeekOriginFraction = originFraction
                latePositionSeekOriginMilliseconds = originMilliseconds
                clearPendingPositionSeek()
                anchorDanmakuClock(to: sample, at: now)
                return
            }
            return
        }

        if let target = latePositionSeekTargetFraction,
           let originFraction = latePositionSeekOriginFraction,
           let originMilliseconds = latePositionSeekOriginMilliseconds,
           positionSeekLanded(
               targetFraction: target,
               originFraction: originFraction,
               originMilliseconds: originMilliseconds,
               elapsed: now - (pendingDanmakuSeekStartedAt ?? now),
               sampledMilliseconds: sample
           ) {
            clearLatePositionSeek()
            anchorDanmakuClock(to: sample, at: now)
            return
        }

        if let target = lateDanmakuSeekTargetMilliseconds {
            var confirmedSeekSample = abs(sample - target) <= 750
            if let origin = lateDanmakuSeekOriginMilliseconds,
               let previousSample = lateDanmakuSeekLastSampleMilliseconds,
               let previousSampleUptime = lateDanmakuSeekLastSampleUptime {
                let isAdvancing = isPlaying && !isDanmakuBuffering
                let previousElapsed = isAdvancing
                    ? max(0, now - previousSampleUptime) * 1_000 * Double(playbackRate)
                    : 0
                let sampledChange = sample - previousSample
                let seekDirection = target - origin
                let movedInSeekDirection = seekDirection < 0
                    ? sampledChange < -750
                    : (seekDirection > 0 ? sampledChange > previousElapsed + 1_500 : false)
                confirmedSeekSample = confirmedSeekSample || movedInSeekDirection
            }

            if confirmedSeekSample {
                clearLateDanmakuSeek()
                anchorDanmakuClock(to: sample, at: now)
                return
            }

            lateDanmakuSeekLastSampleMilliseconds = sample
            lateDanmakuSeekLastSampleUptime = now
        }

        if let seekTarget = pendingDanmakuSeekTargetMilliseconds {
            var confirmedSeekSample = abs(sample - seekTarget) <= 750
            if let origin = danmakuSeekOriginMilliseconds,
               let previousSample = danmakuSeekLastSampleMilliseconds,
               let previousSampleUptime = danmakuSeekLastSampleUptime {
                let isAdvancing = isPlaying && !isDanmakuBuffering
                let previousElapsed = isAdvancing
                    ? max(0, now - previousSampleUptime) * 1_000 * Double(playbackRate)
                    : 0
                let sampledChange = sample - previousSample
                let seekDirection = seekTarget - origin
                let movedInSeekDirection = seekDirection < 0
                    ? sampledChange < -750
                    : (seekDirection > 0 ? sampledChange > previousElapsed + 1_500 : false)
                confirmedSeekSample = confirmedSeekSample || movedInSeekDirection
            }

            if confirmedSeekSample {
                clearPendingDanmakuSeek()
                anchorDanmakuClock(to: sample, at: now)
                return
            }

            if now - (pendingDanmakuSeekStartedAt ?? now) >= 3 {
                lateDanmakuSeekTargetMilliseconds = seekTarget
                lateDanmakuSeekOriginMilliseconds = danmakuSeekOriginMilliseconds
                lateDanmakuSeekLastSampleMilliseconds = sample
                lateDanmakuSeekLastSampleUptime = now
                clearPendingDanmakuSeek()
                anchorDanmakuClock(to: sample, at: now)
                return
            }

            danmakuSeekLastSampleMilliseconds = sample
            danmakuSeekLastSampleUptime = now

            // Ignore old positions until the sampled timeline catches the monotonic clock.
            return
        }

        danmakuClock.reconcile(with: sample, at: now)
    }

    private func updateDanmakuClockPlaybackState(isPlaying: Bool? = nil, isBuffering: Bool? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let wasAdvancing = danmakuClock.isAdvancing
        if let isPlaying {
            self.isPlaying = isPlaying
        }
        if let isBuffering {
            isDanmakuBuffering = isBuffering
        }
        let shouldAdvance = self.isPlaying && !isDanmakuBuffering
        if wasAdvancing != shouldAdvance {
            danmakuClock.setAdvancing(shouldAdvance, at: now)
        }
    }

    private func resetDanmakuClock(
        to milliseconds: Int,
        awaitingPlayerSample: Bool,
        originMilliseconds: Int? = nil
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let position = Double(max(0, milliseconds))
        clearLateDanmakuSeek()
        clearPositionSeek()
        anchorDanmakuClock(
            to: position,
            at: now
        )
        pendingDanmakuSeekTargetMilliseconds = awaitingPlayerSample ? position : nil
        pendingPositionSeekOriginMilliseconds = nil
        pendingDanmakuSeekStartedAt = awaitingPlayerSample ? now : nil
        danmakuSeekOriginMilliseconds = awaitingPlayerSample ? originMilliseconds.map(Double.init) : nil
        danmakuSeekLastSampleMilliseconds = awaitingPlayerSample ? originMilliseconds.map(Double.init) : nil
        danmakuSeekLastSampleUptime = awaitingPlayerSample && originMilliseconds != nil ? now : nil
    }

    private func clearPendingDanmakuSeek() {
        pendingDanmakuSeekTargetMilliseconds = nil
        pendingDanmakuSeekStartedAt = nil
        danmakuSeekOriginMilliseconds = nil
        danmakuSeekLastSampleMilliseconds = nil
        danmakuSeekLastSampleUptime = nil
    }

    private func clearLateDanmakuSeek() {
        lateDanmakuSeekTargetMilliseconds = nil
        lateDanmakuSeekOriginMilliseconds = nil
        lateDanmakuSeekLastSampleMilliseconds = nil
        lateDanmakuSeekLastSampleUptime = nil
    }

    private func clearPendingPositionSeek() {
        pendingPositionSeekTargetFraction = nil
        pendingPositionSeekOriginFraction = nil
        pendingPositionSeekOriginMilliseconds = nil
    }

    private func clearLatePositionSeek() {
        latePositionSeekTargetFraction = nil
        latePositionSeekOriginFraction = nil
        latePositionSeekOriginMilliseconds = nil
    }

    private func clearPositionSeek() {
        clearPendingPositionSeek()
        clearLatePositionSeek()
    }

    private func positionSeekLanded(
        targetFraction: Double,
        originFraction: Double,
        originMilliseconds: Double,
        elapsed: TimeInterval,
        sampledMilliseconds: Double
    ) -> Bool {
        let currentFraction = Double(player.position)
        guard abs(currentFraction - targetFraction) <= 0.025 else { return false }
        if originFraction > 0.03 {
            let estimatedDuration = originMilliseconds / originFraction
            let targetMilliseconds = targetFraction * estimatedDuration
            if targetFraction < originFraction {
                return sampledMilliseconds <= targetMilliseconds + 1_000
            }
            if targetFraction > originFraction {
                return sampledMilliseconds >= targetMilliseconds - 1_500
            }
            return true
        }
        let expectedNaturalTime = originMilliseconds + elapsed * 1_000 * Double(playbackRate)
        if targetFraction < originFraction {
            return sampledMilliseconds < originMilliseconds - 750
        }
        if targetFraction > originFraction {
            return sampledMilliseconds > expectedNaturalTime + 750
        }
        return true
    }

    private func anchorDanmakuClock(to milliseconds: Double, at uptime: TimeInterval) {
        danmakuClock.anchor(to: milliseconds, at: uptime, resetRate: true)
    }

    private var isAtEndOrObservedNearEnd: Bool {
        let duration = totalDurationMilliseconds
        let current = currentPlaybackMilliseconds
        return duration > 0 && (observedNearEnd || current >= duration - 1_000)
    }

    private var totalDurationMilliseconds: Int {
        guard !request.isLive else { return 0 }
        if request.catchupWindow != nil, request.durationMilliseconds > 0 {
            return request.durationMilliseconds
        }
        if reportedDurationMilliseconds > 0 {
            return reportedDurationMilliseconds
        }
        let mediaDuration = max(0, Int(player.media?.length.intValue ?? 0))
        return mediaDuration > 0 ? mediaDuration : request.durationMilliseconds
    }

    var seekDurationMilliseconds: Int { totalDurationMilliseconds }

    private static func clockString(milliseconds: Int32) -> String {
        let seconds = max(0, Int(milliseconds / 1_000))
        let hours = seconds / 3_600
        let minutes = (seconds / 60) % 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", seconds / 60, remainingSeconds)
    }
}

struct PlayerScreen: View {
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.dismiss) private var dismiss
#if os(iOS)
    @State private var systemVolumeController = SystemVolumeController()
    private var foregroundScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.screen
    }
#endif
    @StateObject private var session: VLCPlaybackSession
    @State private var isScrubbing = false
    @State private var seekValue: Double = 0
#if os(tvOS)
    @State private var progressScrubCommitTask: Task<Void, Never>?
#endif
    @State private var isSwitchingEpisode = false
    @State private var vodSelectionTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var playerMenuTitle = ""
    @State private var playerMenuOptions: [PlayerMenuOption] = []
    @State private var showingPlayerMenu = false
    @State private var danmakuComments: [DanmakuComment] = []
    @State private var danmakuGeneration = 0
    @State private var danmakuLoadError: String?
    @State private var danmakuMatchTitle: String?
    @State private var danmakuTask: Task<Void, Never>?
    @State private var showingDanmakuSearch = false
    @State private var showingSubtitleTracks = false
    @State private var resumePlaybackAfterDanmakuSearch = false
    @State private var resumePlaybackAfterSubtitleSelection = false
    @State private var resumePlaybackAfterPlayerMenu = false
    @State private var resumePlaybackAfterDanmakuSettings = false
    @State private var danmakuAPIWhenSettingsOpened = ""
    @State private var danmakuSearchPlaybackGeneration: Int?
    @State private var showingDanmakuSettings = false
    @State private var skipNextDanmakuEnableReload = false
    @State private var areControlsVisible = true
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var interactionHUDMessage: String?
    @State private var interactionHUDSymbol = "sun.max.fill"
    @State private var interactionHUDTask: Task<Void, Never>?
    @State private var touchGesture: PlayerTouchGesture?
    @State private var touchStartProgress = 0.0
    @State private var touchStartBrightness = 0.0
    @State private var touchStartVolume = 0.0
    @State private var landscapeLivePanel: LivePlayerPanel?
    @State private var livePortraitTab: LivePortraitTab = .channels
    @State private var selectedLiveGroupID: String?
    @State private var liveGuideDate = Calendar.current.startOfDay(for: Date())
    @State private var liveGuideClock = Date()
    @State private var lastScrolledLiveProgramID: String?
    @State private var livePrograms: [TVBoxEPGProgram] = []
    @State private var isLoadingLiveGuide = false
    @State private var liveGuideMessage: String?
    #if os(iOS)
    @State private var orientationBeforeManualChange: UIInterfaceOrientation?
    @State private var orientationScene: UIWindowScene?
    #endif
    @AppStorage("tvbox.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("tvbox.danmakuAPIURL") private var danmakuAPIAddress = ""
    @AppStorage("tvbox.autoNext") private var autoNextEpisode = true
    @AppStorage("tvbox.aspectRatio") private var savedAspectRatio = ""
    private let historySaveTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private var liveContext: LivePlaybackContext? { session.request.liveContext }
    private var selectedLiveGroup: TVBoxLiveGroup? {
        guard let groups = liveContext?.groups else { return nil }
        return groups.first(where: { $0.id == selectedLiveGroupID })
            ?? liveContext?.currentGroup
            ?? groups.first
    }
    private var liveGuideTaskKey: String {
        guard let liveContext else { return "" }
        return "\(liveContext.groupID)|\(liveContext.channelID)|\(liveGuideDate.timeIntervalSince1970)"
    }
    #if os(tvOS)
    @FocusState private var playControlFocused: Bool
    @FocusState private var progressFocused: Bool
    @FocusState private var playerSurfaceFocused: Bool
    @FocusState private var livePanelFocusTarget: String?
    @State private var pendingVodFocusID: String?
    #endif

    init(request: PlaybackRequest) {
        _session = StateObject(wrappedValue: VLCPlaybackSession(request: request))
    }

    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            let isPortraitLayout = geometry.size.height > geometry.size.width
            #else
            let isPortraitLayout = false
            #endif
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    ZStack {
                        VLCVideoSurface(session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                            .zIndex(0)
                        DanmakuOverlay(clock: session.danmakuClock, comments: danmakuComments, generation: danmakuGeneration)
                            .id("\(session.playbackGeneration)-\(danmakuGeneration)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                            .zIndex(1)
                        #if os(iOS)
                        GeometryReader { interaction in
                            touchInteractionLayer(size: interaction.size, isPortraitLayout: isPortraitLayout)
                        }
                        .zIndex(1)
                        #endif

                        if areControlsVisible {
                            Group {
                                #if os(iOS)
                                if isPortraitLayout {
                                    VStack(spacing: 0) {
                                        header
                                        Spacer(minLength: 0)
                                        if session.status == "播放失败" { failureCard }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, playerPadding(compact: true))
                                    .padding(.top, playerPadding(compact: true))
                                } else {
                                    VStack(spacing: 0) {
                                        header
                                        Spacer(minLength: 22)
                                        if session.status == "播放失败" { failureCard }
                                        Spacer(minLength: 22)
                                        controlPanel(compact: geometry.size.width < 600)
                                    }
                                    .padding(.leading, playerPadding(compact: geometry.size.width < 600) + geometry.safeAreaInsets.leading)
                                    .padding(.trailing, playerPadding(compact: geometry.size.width < 600) + geometry.safeAreaInsets.trailing)
                                    .padding(.top, playerPadding(compact: geometry.size.width < 600))
                                    .padding(.bottom, playerPadding(compact: geometry.size.width < 600))
                                }
                                #else
                                VStack(spacing: 0) {
                                    header
                                    Spacer(minLength: 22)
                                    if session.status == "播放失败" { failureCard }
                                    Spacer(minLength: 22)
                                    controlPanel(compact: geometry.size.width < 600)
                                }
                                .padding(.leading, max(playerPadding(compact: geometry.size.width < 600), geometry.safeAreaInsets.leading))
                                .padding(.trailing, max(playerPadding(compact: geometry.size.width < 600), geometry.safeAreaInsets.trailing))
                                .padding(.top, max(playerPadding(compact: geometry.size.width < 600), geometry.safeAreaInsets.top))
                                .padding(.bottom, max(playerPadding(compact: geometry.size.width < 600), geometry.safeAreaInsets.bottom))
                                #endif
                            }
                            .transition(session.request.liveContext != nil && !isPortraitLayout ? .identity : .opacity)
                            .zIndex(2)
                        }

                        if !isPortraitLayout, let landscapeLivePanel {
                            liveLandscapePanel(
                                landscapeLivePanel,
                                size: geometry.size,
                                safeAreaInsets: geometry.safeAreaInsets
                            )
                                .zIndex(3)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: isPortraitLayout && (liveContext != nil || session.request.item != nil) ? geometry.size.width * 9 / 16 : nil)

                    #if os(iOS)
                    if isPortraitLayout {
                        if liveContext != nil {
                            if areControlsVisible {
                                controlPanel(compact: true)
                                    .padding(.horizontal, playerPadding(compact: true))
                                    .padding(.top, 8)
                            }
                            livePortraitPanels
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        } else if let item = session.request.item {
                            if areControlsVisible {
                                controlPanel(compact: true)
                                    .padding(.horizontal, playerPadding(compact: true))
                                    .padding(.top, 8)
                            }
                            GeometryReader { detailsArea in
                                vodPortraitDetails(item, minimumHeight: detailsArea.size.height)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                controlPanel(compact: true)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, playerPadding(compact: true))
                            .padding(.top, 10)
                            .padding(.bottom, playerPadding(compact: true))
                                .opacity(areControlsVisible ? 1 : 0)
                                .allowsHitTesting(areControlsVisible)
                                .accessibilityHidden(!areControlsVisible)
                        }
                    }
                    #endif
                }
                .ignoresSafeArea(edges: isPortraitLayout ? [] : .all)
                .zIndex(0)
                #if os(iOS)
                SystemVolumeControl(controller: systemVolumeController)
                    .frame(width: 120, height: 24)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .offset(x: -500, y: -500)
                    .zIndex(4)
                #endif

                #if os(tvOS)
                if !areControlsVisible && landscapeLivePanel == nil {
                    Button { revealControls() } label: {
                        Color.clear
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focused($playerSurfaceFocused)
                    .focusEffectDisabled()
                    .accessibilityLabel("显示播放控件")
                    .zIndex(2)
                    .onMoveCommand { _ in revealControls() }
                }
                #endif

                #if os(iOS)
                if let interactionHUDMessage {
                    Label(interactionHUDMessage, systemImage: interactionHUDSymbol)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.72), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(3)
                }
                #endif
            }
            #if os(iOS)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onEnded { value in
                        let delta = value.translation
                        let videoHeight = geometry.size.width * 9 / 16
                        guard isPortraitLayout,
                              (liveContext != nil || session.request.item != nil),
                              value.startLocation.y >= videoHeight,
                              value.startLocation.x <= max(28, geometry.safeAreaInsets.leading + 18),
                              delta.width >= 90,
                              abs(delta.height) < 100,
                              delta.width > abs(delta.height) else { return }
                        closePlayer()
                    }
            )
            #endif
            .foregroundStyle(.white)
        }
        .onAppear {
            let option = Self.aspectRatios.first { $0.value == savedAspectRatio }
            session.setAspectRatio(option?.value.isEmpty == false ? option?.value : nil, label: option?.label ?? "原始")
            focusLiveGuideDateForPlayback()
            session.play()
            loadEpisodeDanmaku()
            #if os(tvOS)
            playControlFocused = true
            #endif
        }
        .task(id: liveGuideTaskKey) {
            await loadLiveGuide()
        }
        .onDisappear {
            persistPlaybackPosition()
            danmakuTask?.cancel()
            controlsHideTask?.cancel()
            interactionHUDTask?.cancel()
            vodSelectionTask?.cancel()
            vodSelectionTask = nil
            #if os(tvOS)
            progressScrubCommitTask?.cancel()
            #endif
            #if os(iOS)
            restoreOrientationAfterPlayback()
            #endif
            session.stop()
        }
        .onReceive(historySaveTimer) { _ in
            let calendar = liveGuideCalendar
            let previousDay = calendar.startOfDay(for: liveGuideClock)
            let wasFollowingLiveToday = session.request.isLive
                && session.request.catchupWindow == nil
                && calendar.isDate(liveGuideDate, inSameDayAs: previousDay)
            let currentTime = Date()
            liveGuideClock = currentTime
            let currentDay = calendar.startOfDay(for: currentTime)
            if wasFollowingLiveToday && !calendar.isDate(previousDay, inSameDayAs: currentDay) {
                liveGuideDate = currentDay
            }
            persistPlaybackPosition()
        }
        .onChange(of: session.didReachEnd) { _, reachedEnd in
            guard reachedEnd, autoNextEpisode, !session.request.isLive, session.request.liveContext == nil,
                  session.request.queueIndex + 1 < session.request.queue.count else { return }
            moveToEpisode(1)
        }
        .onChange(of: session.playbackGeneration) { _, _ in
            #if os(tvOS)
            progressScrubCommitTask?.cancel()
            progressScrubCommitTask = nil
            isScrubbing = false
            seekValue = session.progress
            #endif
            focusLiveGuideDateForPlayback()
            loadEpisodeDanmaku()
        }
        .onChange(of: danmakuEnabled) { _, enabled in
            if enabled {
                if skipNextDanmakuEnableReload {
                    skipNextDanmakuEnableReload = false
                } else {
                    loadEpisodeDanmaku()
                }
            } else {
                skipNextDanmakuEnableReload = false
            }
        }
        .onChange(of: session.isPlaying) { _, playing in
            if playing {
                revealControls()
            } else {
                controlsHideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) { areControlsVisible = true }
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                controlsHideTask?.cancel()
            } else {
                revealControls()
            }
        }
        .onChange(of: showingDanmakuSearch) { _, showing in
            if showing { controlsHideTask?.cancel() }
            else {
                if resumePlaybackAfterDanmakuSearch {
                    resumePlaybackAfterDanmakuSearch = false
                    session.play()
                    revealControls()
                }
            }
        }
        .onChange(of: showingDanmakuSettings) { _, showing in
            if showing {
                danmakuAPIWhenSettingsOpened = danmakuAPIAddress
                controlsHideTask?.cancel()
            } else {
                if resumePlaybackAfterDanmakuSettings {
                    resumePlaybackAfterDanmakuSettings = false
                    session.play()
                    revealControls()
                } else if session.isPlaying {
                    revealControls()
                }
                if danmakuEnabled, danmakuAPIWhenSettingsOpened != danmakuAPIAddress {
                    loadEpisodeDanmaku()
                }
            }
        }
        .onChange(of: showingPlayerMenu) { _, showing in
            if showing { controlsHideTask?.cancel() }
            else if resumePlaybackAfterPlayerMenu {
                resumePlaybackAfterPlayerMenu = false
                session.play()
                revealControls()
            } else if session.isPlaying {
                revealControls()
            }
        }
        .onChange(of: showingSubtitleTracks) { _, showing in
            if showing {
                controlsHideTask?.cancel()
            } else if resumePlaybackAfterSubtitleSelection {
                resumePlaybackAfterSubtitleSelection = false
                session.play()
                revealControls()
            }
        }
        .alert("无法开始播放", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showingDanmakuSearch) {
            DanmakuSearchView(
                initialQuery: session.request.item?.title ?? session.title,
                mediaTitle: session.request.item?.title ?? session.title,
                mediaCategory: session.request.item?.category ?? "",
                mediaYear: session.request.item?.year ?? "",
                currentEpisodeTitle: currentDanmakuEpisodeTitle,
                expectsEpisodeMatch: session.request.queue.count > 1
            ) { comments, matchTitle in
                guard danmakuSearchPlaybackGeneration == session.playbackGeneration else { return }
                danmakuTask?.cancel()
                danmakuGeneration += 1
                danmakuLoadError = nil
                danmakuComments = comments
                danmakuMatchTitle = matchTitle
                if !danmakuEnabled { skipNextDanmakuEnableReload = true }
                danmakuEnabled = true
                #if os(iOS)
                showInteractionHUD("弹幕已匹配：\(matchTitle)", symbol: "checkmark.circle.fill", duration: 2)
                #endif
            }
        }
        .sheet(isPresented: $showingDanmakuSettings) {
            DanmakuSettingsSheet()
        }
        #if os(iOS)
        .confirmationDialog("选择字幕", isPresented: $showingSubtitleTracks, titleVisibility: .visible) {
            ForEach(session.subtitleTracks) { option in
                Button(option.index == session.selectedSubtitleTrackIndex ? "✓  \(option.title)" : option.title) {
                    session.selectSubtitleTrack(option.index)
                }
            }
        }
#endif
        .confirmationDialog(playerMenuTitle, isPresented: $showingPlayerMenu, titleVisibility: .visible) {
            ForEach(playerMenuOptions) { option in
                Button(option.title, action: option.action)
            }
        }
#if os(tvOS)
        .onExitCommand {
            if landscapeLivePanel != nil {
                revealControls()
            } else {
                closePlayer()
            }
        }
        .onPlayPauseCommand {
            session.togglePlayback()
            revealControls()
        }
        #endif
        .preferredColorScheme(.dark)
    }

    #if os(iOS)
    private func touchInteractionLayer(size: CGSize, isPortraitLayout: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                ExclusiveGesture(
                    SpatialTapGesture(count: 2),
                    SpatialTapGesture(count: 1)
                )
                .onEnded { result in
                    switch result {
                    case .first(let value):
                        handleDoubleTap(at: value.location.x, width: size.width)
                    case .second(let value):
                        if session.request.liveContext != nil && !isPortraitLayout {
                            if landscapeLivePanel != nil {
                                controlsHideTask?.cancel()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    landscapeLivePanel = nil
                                    areControlsVisible = false
                                }
                            } else if value.location.x < size.width * 0.28 {
                                toggleLivePanel(.guide)
                            } else if value.location.x > size.width * 0.72 {
                                toggleLivePanel(.sources)
                            } else {
                                toggleControlsVisibility()
                            }
                        } else if session.request.item != nil && !isPortraitLayout && value.location.x < size.width * 0.28 {
                            toggleLivePanel(.playlist)
                        } else {
                            toggleControlsVisibility()
                        }
                    }
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        handlePlayerDrag(value, size: size)
                    }
                    .onEnded { _ in
                        finishPlayerDrag()
                    }
            )
    }

    private func handleDoubleTap(at x: CGFloat, width: CGFloat) {
        if x < width / 3 {
            if session.canSeekByTime {
                session.seek(by: -15)
                showInteractionHUD("−15 秒", symbol: "gobackward.15")
            } else {
                showInteractionHUD("当前内容无法快退", symbol: "gobackward.15")
            }
        } else if x >= width * 2 / 3 {
            if session.canSeekByTime {
                session.seek(by: 15)
                showInteractionHUD("+15 秒", symbol: "goforward.15")
            } else {
                showInteractionHUD("当前内容无法快进", symbol: "goforward.15")
            }
        } else {
            session.togglePlayback()
            showInteractionHUD(session.isPlaying ? "播放" : "暂停", symbol: session.isPlaying ? "play.fill" : "pause.fill")
        }
        revealControls()
    }

    private func handlePlayerDrag(_ value: DragGesture.Value, size: CGSize) {
        controlsHideTask?.cancel()
        let translation = value.translation
        if touchGesture == nil {
            if abs(translation.width) >= abs(translation.height) {
                guard session.canSeek else {
                    touchGesture = .ignored
                    showInteractionHUD("当前内容无法调整进度", symbol: "timeline.selection")
                    return
                }
                touchGesture = .seek
                touchStartProgress = session.progress
                seekValue = session.progress
                isScrubbing = true
            } else if value.startLocation.x < size.width / 3 {
                touchGesture = .brightness
                touchStartBrightness = Double(foregroundScreen?.brightness ?? 0.5)
            } else if value.startLocation.x >= size.width * 2 / 3 {
                touchGesture = .volume
                touchStartVolume = systemVolumeController.volume
            } else {
                touchGesture = .ignored
                return
            }
        }

        switch touchGesture {
        case .some(.seek):
            seekValue = min(1, max(0, touchStartProgress + Double(translation.width / max(1, size.width))))
            showInteractionHUD("进度 \(Int(seekValue * 100))%", symbol: "timeline.selection")
        case .some(.brightness):
            let level = min(1, max(0, touchStartBrightness - Double(translation.height / max(1, size.height))))
            foregroundScreen?.brightness = CGFloat(level)
            showInteractionHUD("亮度 \(Int(level * 100))%", symbol: "sun.max.fill")
        case .some(.volume):
            let level = min(100, max(0, touchStartVolume - Double(translation.height / max(1, size.height)) * 100))
            systemVolumeController.setVolume(level)
            showInteractionHUD("音量 \(Int(level))%", symbol: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        case .some(.ignored), .none:
            break
        }
    }

    private func finishPlayerDrag() {
        if touchGesture == .seek, session.canSeek {
            session.seek(to: seekValue)
        }
        isScrubbing = false
        touchGesture = nil
        revealControls()
    }

    private func toggleOrientation() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        if orientationBeforeManualChange == nil {
            orientationBeforeManualChange = scene.interfaceOrientation
            orientationScene = scene
        }
        let requested: UIInterfaceOrientationMask = scene.interfaceOrientation.isLandscape ? .portrait : .landscapeRight
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: requested)) { _ in }
    }

    private func restoreOrientationAfterPlayback() {
        guard !showingDanmakuSearch, !showingDanmakuSettings, !showingSubtitleTracks else { return }
        guard let orientationBeforeManualChange else { return }
        self.orientationBeforeManualChange = nil
        defer { orientationScene = nil }
        let mask: UIInterfaceOrientationMask
        switch orientationBeforeManualChange {
        case .portrait:
            mask = .portrait
        case .portraitUpsideDown:
            mask = .portraitUpsideDown
        case .landscapeLeft:
            mask = .landscapeLeft
        case .landscapeRight:
            mask = .landscapeRight
        default:
            return
        }
        orientationScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    #endif

    private func closePlayer() {
        #if os(iOS)
        restoreOrientationAfterPlayback()
        #endif
        dismiss()
    }

    @MainActor
    private func toggleControlsVisibility() {
        if landscapeLivePanel != nil {
            revealControls()
            return
        }
        if areControlsVisible {
            controlsHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { areControlsVisible = false }
        } else {
            revealControls()
        }
    }

    @MainActor
    private func revealControls() {
        if landscapeLivePanel != nil {
            controlsHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { landscapeLivePanel = nil }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard landscapeLivePanel == nil else { return }
                revealControls()
            }
            return
        }
        let wasHidden = !areControlsVisible
        withAnimation(.easeInOut(duration: 0.2)) { areControlsVisible = true }
        controlsHideTask?.cancel()
        #if os(tvOS)
        playerSurfaceFocused = false
        if wasHidden {
            Task { @MainActor in
                await Task.yield()
                if areControlsVisible { playControlFocused = true }
            }
        }
        #endif
        guard landscapeLivePanel == nil else { return }
        guard session.isPlaying else { return }
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, session.isPlaying, !isScrubbing, touchGesture == nil else { return }
            withAnimation(.easeInOut(duration: 0.25)) { areControlsVisible = false }
            #if os(tvOS)
            playControlFocused = false
            Task { @MainActor in
                await Task.yield()
                if !areControlsVisible { playerSurfaceFocused = true }
            }
            #endif
        }
    }

    #if os(iOS)
    @MainActor
    private func showInteractionHUD(_ message: String, symbol: String, duration: Double = 0.9) {
        interactionHUDMessage = message
        interactionHUDSymbol = symbol
        interactionHUDTask?.cancel()
        interactionHUDTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { interactionHUDMessage = nil }
        }
    }
    #endif

    private var header: some View {
        HStack(spacing: 14) {
            Button { closePlayer() } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: TVBoxTypography.readable(14), weight: .semibold))
                    .padding(.horizontal, TVBoxTypography.readable(15, minimum: 24))
                    .padding(.vertical, TVBoxTypography.readable(11, minimum: 18))
            }
            .playerControlButtonStyle()
            .accessibilityHint("关闭播放器并返回详情")
            Spacer(minLength: 10)
            Text(session.title)
                .font(.system(size: TVBoxTypography.readable(15)))
                .lineLimit(1)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(.black.opacity(0.48), in: Capsule())
#if os(tvOS)
            if liveContext != nil {
                Button { toggleLivePanel(.guide) } label: {
                    Label("节目单", systemImage: "list.bullet.rectangle")
                }
                .playerControlButtonStyle()
                .accessibilityLabel("显示节目单")
                Button { toggleLivePanel(.sources) } label: {
                    Label("线路", systemImage: "antenna.radiowaves.left.and.right")
                }
                .playerControlButtonStyle()
                .accessibilityLabel("显示可切换线路")
            } else if session.request.item != nil {
                Button { toggleLivePanel(.playlist) } label: {
                    Label("片源/选集", systemImage: "list.bullet.rectangle")
                }
                .playerControlButtonStyle()
                .accessibilityLabel("显示片源和选集")
            }
#endif
        }
    }

    private func vodPortraitDetails(_ item: MediaItem, minimumHeight: CGFloat) -> some View {
        let compact = minimumHeight < 360
        return VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            VStack(alignment: .leading, spacing: compact ? 4 : 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(compact ? 1 : 2)
                    Spacer(minLength: 8)
                    if !compact, !item.remarks.isEmpty {
                        Text(item.remarks)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.tvboxMuted)
                            .lineLimit(1)
                    }
                }
                if !compact, !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.68))
                        .lineLimit(2)
                }
                if !compact {
                    let metadata = [item.year, item.area, item.language, item.actor.isEmpty ? "" : "主演：\(item.actor)"]
                        .filter { !$0.isEmpty }
                    if !metadata.isEmpty {
                        Text(metadata.joined(separator: " · "))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.tvboxMuted)
                            .lineLimit(2)
                    }
                }
            }
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
            vodPlaylistContent(scrollEpisodes: true, compact: compact)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 14)
        .padding(.top, compact ? 8 : 14)
        .padding(.bottom, compact ? 8 : 14)
        .frame(maxWidth: .infinity, minHeight: minimumHeight, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.tvboxSurface)
        .foregroundStyle(Color(uiColor: .label))
    }

    private func vodPlaylistContent(scrollEpisodes: Bool, compact: Bool = false) -> some View {
        #if os(tvOS)
        vodTVPlaylistContent
        #else
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            if let item = session.request.item, item.lines.count > 1 {
                if !compact {
                    Text("片源")
                        .font(vodSectionTitleFont)
                        .padding(.horizontal, vodFocusHorizontalInset)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: vodChoiceSpacing) {
                        ForEach(item.lines) { line in
                            Button {
                                switchPlaybackLine(line)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: line.id == session.request.lineID ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(vodChoiceIndicatorColor(isSelected: line.id == session.request.lineID))
                                        .accessibilityHidden(true)
                                    Text(line.flag)
                                        .lineLimit(1)
                                        .foregroundStyle(vodChoiceForeground(isSelected: line.id == session.request.lineID))
                                }
                                .font(vodChoiceFont)
                                .padding(.horizontal, vodChoiceHorizontalPadding)
                                .frame(minHeight: vodChoiceMinHeight)
                                .background(vodChoiceBackground(isSelected: line.id == session.request.lineID),
                                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(
                                            line.id == session.request.lineID ? Color.tvboxAccent.opacity(0.65) : .clear,
                                            lineWidth: 2
                                        )
                                }
                            }
                            #if os(tvOS)
                            .buttonStyle(.card)
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .accessibilityLabel(line.id == session.request.lineID ? "当前片源，\(line.flag)" : line.flag)
                            .accessibilityAddTraits(line.id == session.request.lineID ? .isSelected : [])
                            #if os(tvOS)
                            .focused($livePanelFocusTarget, equals: "vod:line:\(line.id)")
                            #endif
                            .disabled(isSwitchingEpisode)
                        }
                    }
                    .padding(.horizontal, vodFocusHorizontalInset)
                    .padding(.vertical, vodFocusVerticalInset)
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
            HStack(alignment: .firstTextBaseline) {
                Text("选集")
                    .font(vodSectionTitleFont)
                Spacer(minLength: 8)
                Text("\(session.request.queue.count) 集")
                    .font(vodCountFont)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            .padding(.horizontal, vodFocusHorizontalInset)
            if scrollEpisodes {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: vodChoiceSpacing) {
                            vodEpisodeButtons
                        }
                        .padding(.horizontal, vodFocusHorizontalInset)
                        .padding(.vertical, vodFocusVerticalInset)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    #if os(iOS)
                    .scrollBounceBehavior(.basedOnSize)
                    #endif
                    #if os(tvOS)
                    .focusSection()
                    #endif
                    .task {
                        #if os(tvOS)
                        if landscapeLivePanel == .playlist,
                           session.request.queue.indices.contains(session.request.queueIndex) {
                            let focusKey = vodFocusRestoreKey
                            let episode = session.request.queue[session.request.queueIndex]
                            await Task.yield()
                            guard landscapeLivePanel == .playlist, focusKey == vodFocusRestoreKey else { return }
                            proxy.scrollTo(episode.id, anchor: .center)
                            await Task.yield()
                            guard landscapeLivePanel == .playlist, focusKey == vodFocusRestoreKey else { return }
                            livePanelFocusTarget = "vod:\(episode.id)"
                        }
                        #endif
                    }
                    #if os(tvOS)
                    .onChange(of: vodFocusRestoreKey) { _, _ in
                        guard landscapeLivePanel == .playlist,
                              session.request.queue.indices.contains(session.request.queueIndex) else { return }
                        let focusKey = vodFocusRestoreKey
                        let episode = session.request.queue[session.request.queueIndex]
                        Task { @MainActor in
                            await Task.yield()
                            guard landscapeLivePanel == .playlist, focusKey == vodFocusRestoreKey else { return }
                            proxy.scrollTo(episode.id, anchor: .center)
                            await Task.yield()
                            guard landscapeLivePanel == .playlist, focusKey == vodFocusRestoreKey else { return }
                            livePanelFocusTarget = "vod:\(episode.id)"
                        }
                    }
                    #endif
                }
            } else {
                LazyVStack(alignment: .leading, spacing: vodChoiceSpacing) {
                    vodEpisodeButtons
                }
                .padding(.horizontal, vodFocusHorizontalInset)
                .padding(.vertical, vodFocusVerticalInset)
            }
            if isSwitchingEpisode {
                ProgressView("正在切换剧集…")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    #if os(tvOS)
    private var vodTVPlaylistContent: some View {
        ScrollViewReader { proxy in
            List {
                if let item = session.request.item, item.lines.count > 1 {
                    Section("片源") {
                        ForEach(item.lines) { line in
                            let isSelected = line.id == session.request.lineID
                            Button {
                                switchPlaybackLine(line)
                            } label: {
                                HStack {
                                    Label(line.flag, systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.body.weight(.medium))
                                    Spacer()
                                    if isSelected {
                                        Text("当前")
                                            .font(.subheadline)
                                            .foregroundStyle(Color.tvboxMuted)
                                    }
                                }
                                .foregroundStyle(Color(uiColor: .label))
                                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .platformFocusableButtonStyle()
                            .listRowBackground(isSelected ? Color.tvboxSelection.opacity(0.24) : Color.clear)
                            .focused($livePanelFocusTarget, equals: "vod:line:\(line.id)")
                            .disabled(isSwitchingEpisode)
                        }
                    }
                }

                Section {
                    ForEach(Array(session.request.queue.enumerated()), id: \.element.id) { index, episode in
                        let isSelected = index == session.request.queueIndex
                        Button {
                            selectVodEpisode(episode, at: index)
                        } label: {
                            HStack {
                                Label(episode.title, systemImage: isSelected ? "checkmark.circle.fill" : "play.circle")
                                    .font(.body.weight(isSelected ? .semibold : .regular))
                                    .lineLimit(2)
                                Spacer(minLength: 12)
                                if isSelected {
                                    Text("正在播放")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.tvboxMuted)
                                }
                            }
                            .foregroundStyle(Color(uiColor: .label))
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .platformFocusableButtonStyle()
                        .listRowBackground(isSelected ? Color.tvboxSelection.opacity(0.24) : Color.clear)
                        .focused($livePanelFocusTarget, equals: "vod:\(episode.id)")
                        .onAppear {
                            guard pendingVodFocusID == episode.id,
                                  landscapeLivePanel == .playlist else { return }
                            livePanelFocusTarget = "vod:\(episode.id)"
                            pendingVodFocusID = nil
                        }
                        .onChange(of: pendingVodFocusID) { _, focusID in
                            guard focusID == episode.id,
                                  landscapeLivePanel == .playlist else { return }
                            livePanelFocusTarget = "vod:\(episode.id)"
                            pendingVodFocusID = nil
                        }
                        .disabled(isSwitchingEpisode)
                        .id(episode.id)
                    }
                } header: {
                    HStack {
                        Text("选集")
                        Spacer()
                        Text("\(session.request.queue.count) 集")
                            .foregroundStyle(Color.tvboxMuted)
                    }
                }

                if isSwitchingEpisode {
                    ProgressView("正在切换剧集…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .listStyle(.plain)
            .platformListBackgroundHidden()
            .onAppear {
                focusCurrentVodEpisode(using: proxy)
            }
            .onChange(of: vodFocusRestoreKey) { _, _ in
                focusCurrentVodEpisode(using: proxy)
            }
        }
    }

    private func focusCurrentVodEpisode(using proxy: ScrollViewProxy) {
        guard landscapeLivePanel == .playlist,
              session.request.queue.indices.contains(session.request.queueIndex) else { return }
        let focusKey = vodFocusRestoreKey
        let episode = session.request.queue[session.request.queueIndex]
        pendingVodFocusID = episode.id
        Task { @MainActor in
            await Task.yield()
            guard landscapeLivePanel == .playlist, focusKey == vodFocusRestoreKey else { return }
            proxy.scrollTo(episode.id, anchor: .center)
        }
    }
    #endif

    @ViewBuilder
    private var vodEpisodeButtons: some View {
        ForEach(Array(session.request.queue.enumerated()), id: \.element.id) { index, episode in
            Button {
                selectVodEpisode(episode, at: index)
            } label: {
                HStack(spacing: vodChoiceSpacing) {
                    Image(systemName: index == session.request.queueIndex ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(vodChoiceIndicatorColor(isSelected: index == session.request.queueIndex))
                        .accessibilityHidden(true)
                    Text(episode.title)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                        .foregroundStyle(vodChoiceForeground(isSelected: index == session.request.queueIndex))
                    Spacer(minLength: 8)
                }
                .font(vodChoiceFont)
                .padding(.horizontal, vodChoiceHorizontalPadding)
                .frame(maxWidth: .infinity, minHeight: vodChoiceMinHeight, alignment: .leading)
                .background(vodChoiceBackground(isSelected: index == session.request.queueIndex),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            index == session.request.queueIndex ? Color.tvboxAccent.opacity(0.65) : .clear,
                            lineWidth: 2
                        )
                }
            }
            #if os(tvOS)
            .buttonStyle(.card)
            #else
            .buttonStyle(.plain)
            #endif
            #if os(tvOS)
            .focused($livePanelFocusTarget, equals: "vod:\(episode.id)")
            #endif
            .accessibilityLabel(index == session.request.queueIndex ? "正在播放，\(episode.title)" : episode.title)
            .accessibilityAddTraits(index == session.request.queueIndex ? .isSelected : [])
            .disabled(isSwitchingEpisode)
            .id(episode.id)
        }
    }

    private var vodChoiceFont: Font {
        #if os(tvOS)
        .system(size: TVBoxTypography.readable(20), weight: .semibold)
        #else
        .callout.weight(.semibold)
        #endif
    }

    private var vodSectionTitleFont: Font {
        #if os(tvOS)
        .system(size: TVBoxTypography.readable(17), weight: .semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }

    private var vodCountFont: Font {
        #if os(tvOS)
        .system(size: TVBoxTypography.readable(14), weight: .medium)
        #else
        .caption.weight(.medium)
        #endif
    }

    private var vodChoiceSpacing: CGFloat {
        #if os(tvOS)
        18
        #else
        8
        #endif
    }

    private var vodFocusRestoreKey: String {
        "\(session.request.lineID)|\(session.request.episodeID)|\(session.request.queueIndex)"
    }

    private var vodChoiceHorizontalPadding: CGFloat {
        #if os(tvOS)
        20
        #else
        12
        #endif
    }

    private var vodFocusHorizontalInset: CGFloat {
        #if os(tvOS)
        32
        #else
        0
        #endif
    }

    private var vodFocusVerticalInset: CGFloat {
        #if os(tvOS)
        24
        #else
        0
        #endif
    }

    private func vodChoiceBackground(isSelected: Bool) -> Color {
        #if os(tvOS)
        isSelected ? Color.tvboxAccent.opacity(0.18) : Color.primary.opacity(0.07)
        #else
        isSelected ? Color.tvboxAccent : Color.tvboxSurface
        #endif
    }

    private func vodChoiceForeground(isSelected: Bool) -> Color {
        #if os(tvOS)
        Color.primary
        #else
        isSelected ? Color.white : Color.primary
        #endif
    }

    private func vodChoiceIndicatorColor(isSelected: Bool) -> Color {
        #if os(tvOS)
        isSelected ? Color.tvboxAccent : Color.secondary
        #else
        isSelected ? Color.white : Color.secondary
        #endif
    }

    private var vodChoiceMinHeight: CGFloat {
        #if os(tvOS)
        88
        #else
        44
        #endif
    }

    private var livePortraitPanels: some View {
        VStack(spacing: 12) {
            Picker("直播导航", selection: $livePortraitTab) {
                ForEach(LivePortraitTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch livePortraitTab {
                case .groups: liveGroupContent
                case .channels: liveChannelContent
                case .programs: liveGuideContent
                case .sources: liveSourceContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(14)
        .background(Color.tvboxSurface)
        .foregroundStyle(Color(uiColor: .label))
    }

    private var liveGroupContent: some View {
        List {
            ForEach(liveContext?.groups ?? []) { group in
                Button {
                    selectedLiveGroupID = group.id
                    livePortraitTab = .channels
                } label: {
                    HStack {
                        Text(group.name)
                            .foregroundStyle(Color(uiColor: .label))
                        Spacer()
                        Text("\(group.channels.count)")
                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(group.id == selectedLiveGroup?.id ? Color.tvboxSelection.opacity(0.18) : Color.clear)
            }
        }
        .listStyle(.plain)
        .platformListBackgroundHidden()
    }

    private var liveChannelContent: some View {
        List {
            if let group = selectedLiveGroup {
                ForEach(group.channels) { channel in
                    Button {
                        selectLiveChannel(channel, group: group)
                    } label: {
                        HStack(spacing: 12) {
                            Group {
                                if let logoURL = channel.logoURL {
                                    CachedArtworkImage(url: logoURL, contentMode: .fit)
                                } else {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .foregroundStyle(Color.tvboxAccent)
                                }
                            }
                            .frame(width: 38, height: 38)
                            Text(channel.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(uiColor: .label))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if channel.id == liveContext?.channelID && group.id == liveContext?.groupID {
                                Image(systemName: "waveform")
                                    .foregroundStyle(Color.tvboxAccent)
                            }
                        }
                    }
                    .listRowBackground(channel.id == liveContext?.channelID && group.id == liveContext?.groupID
                                       ? Color.tvboxSelection.opacity(0.18) : Color.clear)
                    #if os(tvOS)
                    .focused($livePanelFocusTarget, equals: "channel:\(group.id):\(channel.id)")
                    #endif
                    .disabled(isSwitchingEpisode)
                }
            }
        }
        .listStyle(.plain)
        .platformListBackgroundHidden()
    }

    @ViewBuilder
    private func livePanelContent(_ panel: LivePlayerPanel) -> some View {
        switch panel {
        case .guide:
            liveLandscapeGuideContent
        case .sources:
            liveSourceContent
        case .playlist:
            vodPlaylistContent(scrollEpisodes: true)
        }
    }

    private var liveLandscapeGuideContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("分类")
                    .font(.system(size: TVBoxTypography.readable(17, minimum: 23), weight: .semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                ScrollViewReader { proxy in
                    List {
                        ForEach(liveContext?.groups ?? []) { group in
                            Button {
                                selectedLiveGroupID = group.id
                                #if os(tvOS)
                                livePanelFocusTarget = "group:\(group.id)"
                                #endif
                            } label: {
                                Text(group.name)
                                    .font(.system(size: TVBoxTypography.readable(13), weight: .medium))
                                    .lineLimit(2)
                                    .foregroundStyle(Color(uiColor: .label))
                                    .frame(maxWidth: .infinity, minHeight: TVBoxTypography.readable(42, minimum: 68), alignment: .leading)
                                    .padding(.horizontal, 9)
                            }
                            .platformFocusableButtonStyle()
                            .listRowBackground(group.id == selectedLiveGroup?.id ? Color.tvboxSelection.opacity(0.18) : Color.clear)
                            .listRowInsets(EdgeInsets(
                                top: TVBoxTypography.readable(3, minimum: 6),
                                leading: TVBoxTypography.readable(4, minimum: 8),
                                bottom: TVBoxTypography.readable(3, minimum: 6),
                                trailing: TVBoxTypography.readable(4, minimum: 8)
                            ))
                            #if os(tvOS)
                            .focused($livePanelFocusTarget, equals: "group:\(group.id)")
                            #endif
                            .accessibilityAddTraits(group.id == selectedLiveGroup?.id ? .isSelected : [])
                            .id(group.id)
                        }
                    }
                    .listStyle(.plain)
                    .platformListBackgroundHidden()
                    .onAppear {
                        guard let groupID = selectedLiveGroup?.id else { return }
                        proxy.scrollTo(groupID, anchor: .center)
                        #if os(tvOS)
                        Task { @MainActor in
                            await Task.yield()
                            guard landscapeLivePanel == .guide else { return }
                            livePanelFocusTarget = "group:\(groupID)"
                        }
                        #endif
                    }
                    .onChange(of: selectedLiveGroupID) { _, groupID in
                        guard let groupID else { return }
                        proxy.scrollTo(groupID, anchor: .center)
                    }
                }
            }
            .frame(width: TVBoxTypography.readable(112, minimum: 220), alignment: .topLeading)

            Divider().padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("频道")
                    .font(.system(size: TVBoxTypography.readable(17, minimum: 23), weight: .semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                List {
                    ForEach(selectedLiveGroup?.channels ?? []) { channel in
                        Button {
                            if let group = selectedLiveGroup {
                                selectLiveChannel(channel, group: group)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if let logoURL = channel.logoURL {
                                    CachedArtworkImage(url: logoURL, contentMode: .fit)
                                        .frame(width: TVBoxTypography.readable(30, minimum: 48), height: TVBoxTypography.readable(30, minimum: 48))
                                }
                                Text(channel.name)
                                    .font(.system(size: TVBoxTypography.readable(13), weight: .semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if channel.id == liveContext?.channelID && selectedLiveGroup?.id == liveContext?.groupID {
                                    Image(systemName: "waveform")
                                        .font(.caption)
                                        .foregroundStyle(Color.tvboxAccent)
                                }
                            }
                            .foregroundStyle(Color(uiColor: .label))
                        }
                        .platformFocusableButtonStyle()
                        .listRowBackground(channel.id == liveContext?.channelID && selectedLiveGroup?.id == liveContext?.groupID
                                           ? Color.tvboxSelection.opacity(0.18) : Color.clear)
                        #if os(tvOS)
                        .focused($livePanelFocusTarget, equals: "channel:\(selectedLiveGroup?.id ?? ""):\(channel.id)")
                        #endif
                        .disabled(isSwitchingEpisode)
                    }
                }
                .listStyle(.plain)
                .platformListBackgroundHidden()
            }
            .frame(width: TVBoxTypography.readable(148, minimum: 310), alignment: .topLeading)

            Divider().padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("节目")
                    .font(.system(size: TVBoxTypography.readable(17, minimum: 23), weight: .semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                liveGuideContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var liveGuideContent: some View {
        VStack(spacing: 10) {
            Picker("日期", selection: $liveGuideDate) {
                ForEach(liveGuideDates, id: \.self) { date in
                    Text(liveDateTitle(date)).tag(date)
                }
            }
            .pickerStyle(.menu)
            .tint(Color.tvboxSelection)

            if isLoadingLiveGuide {
                ProgressView("正在载入节目单…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if livePrograms.isEmpty {
                ContentUnavailableView(
                    liveGuideMessage ?? "没有可用的节目单",
                    systemImage: "calendar",
                    description: Text(liveContext?.epgURL.isEmpty == false ? "选择其他日期，或检查节目单配置。" : "当前配置没有提供节目单地址。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(livePrograms) { program in
                            liveProgramRow(program)
                                .id(program.id)
                        }
                    }
                    .listStyle(.plain)
                    .platformListBackgroundHidden()
                    .background(Color.clear)
                    .onAppear {
                        scrollToPlayingProgram(using: proxy, animated: false)
                    }
                    .onChange(of: livePrograms) { _, _ in
                        scrollToPlayingProgram(using: proxy)
                    }
                    .onChange(of: session.playbackGeneration) { _, _ in
                        scrollToPlayingProgram(using: proxy)
                    }
                    .onChange(of: liveGuideClock) { _, _ in
                        scrollToPlayingProgram(using: proxy, onlyIfChanged: true)
                    }
                }
            }
        }
        .onAppear(perform: focusLiveGuideDateForPlayback)
    }

    private var liveSourceContent: some View {
        List {
            if let channel = liveContext?.currentChannel {
                ForEach(channel.sources) { source in
                    Button {
                        selectLiveSource(source)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: source.id == liveContext?.sourceID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(source.id == liveContext?.sourceID ? Color.tvboxAccent : Color.secondary)
                            Text(source.name)
                                .font(.system(size: TVBoxTypography.readable(17)))
                                .lineLimit(1)
                                .foregroundStyle(Color(uiColor: .label))
                            Spacer()
                            if source.id == liveContext?.sourceID {
                                Text("当前")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.tvboxAccent)
                            }
                        }
                    }
                    .platformFocusableButtonStyle()
                    .listRowBackground(source.id == liveContext?.sourceID ? Color.tvboxSelection.opacity(0.18) : Color.clear)
                    #if os(tvOS)
                    .focused($livePanelFocusTarget, equals: "source:\(source.id)")
                    #endif
                    .disabled(isSwitchingEpisode)
                }
            }
        }
        .listStyle(.plain)
        .platformListBackgroundHidden()
    }

    private func liveProgramRow(_ program: TVBoxEPGProgram) -> some View {
        let target = liveProgramTarget(for: program)
        let interval = program.interval(on: liveGuideDate)
        let isPlaying = isPlayingLiveProgram(program)
        let status: String = {
            if target?.isLive == true { return isPlaying ? "正在直播" : "直播" }
            if target != nil { return isPlaying ? "正在回放" : "回放" }
            if let interval, liveGuideClock < interval.start { return "未开始" }
            return "不可回放"
        }()
        let statusColor = isPlaying ? Color.white : Color.tvboxMuted
        return Button {
            guard let target, let context = liveContext else { return }
            if let request = context.request(
                groupID: context.groupID,
                channelID: context.channelID,
                sourceID: context.sourceID,
                title: "\(context.currentChannel?.name ?? session.title) · \(program.title)",
                url: target.url,
                isLive: target.isLive,
                durationMilliseconds: target.durationMilliseconds,
                catchupWindow: target.catchupWindow
            ) {
                session.replace(with: request)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(program.start)
                        .font(.system(size: TVBoxTypography.readable(13, minimum: 23), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.blue)
                    Text(program.end)
                        .font(.system(size: TVBoxTypography.readable(11, minimum: 20), weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.82))
                }
                .frame(width: TVBoxTypography.readable(55, minimum: 88), alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.title)
                        .font(.system(size: TVBoxTypography.readable(14), weight: .semibold))
                        .foregroundStyle(Color(uiColor: .label))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(status)
                    .font(.system(size: TVBoxTypography.readable(11, minimum: 23), weight: .medium))
                    .foregroundStyle(target == nil ? Color(uiColor: .secondaryLabel) : statusColor)
                    .lineLimit(1)
            }
            .padding(.vertical, TVBoxTypography.readable(4, minimum: 16))
            .frame(minHeight: TVBoxTypography.readable(44, minimum: 104))
        }
        .disabled(target == nil)
        .listRowInsets(EdgeInsets(
            top: TVBoxTypography.readable(2, minimum: 4),
            leading: TVBoxTypography.readable(8, minimum: 12),
            bottom: TVBoxTypography.readable(2, minimum: 4),
            trailing: TVBoxTypography.readable(8, minimum: 12)
        ))
        .listRowBackground(isPlaying ? Color.tvboxSelection.opacity(0.22) : Color.clear)
    }

    private func liveLandscapePanel(
        _ panel: LivePlayerPanel,
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        let onLeft = panel != .sources
        return ZStack(alignment: onLeft ? .leading : .trailing) {
            liveSidePanel(panel, size: size, safeAreaInsets: safeAreaInsets)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: onLeft ? .leading : .trailing
        )
        .transition(.move(edge: onLeft ? .leading : .trailing).combined(with: .opacity))
    }

    private func liveSidePanel(
        _ panel: LivePlayerPanel,
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> some View {
        let availablePanelWidth = max(320, size.width - safeAreaInsets.leading - safeAreaInsets.trailing - 160)
        #if os(tvOS)
        let playlistPanelWidth = min(max(size.width * 0.46, 520), min(860, availablePanelWidth))
        #else
        let playlistPanelWidth = min(max(size.width * 0.42, 360), max(280, size.width - safeAreaInsets.leading - safeAreaInsets.trailing - 48))
        #endif

        return VStack(spacing: 14) {
            HStack {
                Text(panel.rawValue)
                    .font(.system(size: TVBoxTypography.readable(20), weight: .bold, design: .rounded))
                Spacer()
                Button { toggleLivePanel(panel) } label: {
                    Label("完成", systemImage: "xmark")
                }
                .playerControlButtonStyle()
                .frame(minHeight: TVBoxTypography.readable(48, minimum: 64))
            }
            livePanelContent(panel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 14 + safeAreaInsets.top)
        .padding(.bottom, 14 + safeAreaInsets.bottom)
        .padding(.leading, 14 + (panel != .sources ? safeAreaInsets.leading : 0))
        .padding(.trailing, 14 + (panel == .sources ? safeAreaInsets.trailing : 0))
        .frame(width: panel == .guide
            ? min(max(size.width * 0.88, 1_200), max(560, size.width - 160))
            : panel == .playlist ? playlistPanelWidth
            : min(max(size.width * 0.32, 280), 390))
        .frame(maxHeight: .infinity, alignment: .top)
        #if os(tvOS)
        .background(Color.black.opacity(0.96))
        #else
        .background(.regularMaterial)
        #endif
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1)
        }
        .foregroundStyle(Color(uiColor: .label))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { })
        .accessibilityAction(.escape) { toggleLivePanel(panel) }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var liveGuideDates: [Date] {
        let calendar = liveGuideCalendar
        let today = calendar.startOfDay(for: liveGuideClock)
        var dates = (-6...1).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        if let replayDate = session.request.catchupWindow?.start {
            let replayDay = calendar.startOfDay(for: replayDate)
            if !dates.contains(where: { calendar.isDate($0, inSameDayAs: replayDay) }) {
                dates.append(replayDay)
                dates.sort()
            }
        }
        return dates
    }

    private var liveGuideCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    private func focusLiveGuideDateForPlayback() {
        guard liveContext != nil else { return }
        let playbackDate = session.request.catchupWindow?.start ?? liveGuideClock
        let day = liveGuideCalendar.startOfDay(for: playbackDate)
        guard !liveGuideCalendar.isDate(liveGuideDate, inSameDayAs: day) else { return }
        liveGuideDate = day
    }

    private func isPlayingLiveProgram(_ program: TVBoxEPGProgram) -> Bool {
        guard let context = liveContext,
              session.request.liveContext?.groupID == context.groupID,
              session.request.liveContext?.channelID == context.channelID,
              let interval = program.interval(on: liveGuideDate) else { return false }
        if let window = session.request.catchupWindow {
            return abs(window.start.timeIntervalSince(interval.start)) < 60
                && abs(window.end.timeIntervalSince(interval.end)) < 60
        }
        guard session.request.isLive else { return false }
        let now = liveGuideClock
        return interval.start <= now && now < interval.end
    }

    private func scrollToPlayingProgram(using proxy: ScrollViewProxy, animated: Bool = true, onlyIfChanged: Bool = false) {
        guard let program = livePrograms.first(where: isPlayingLiveProgram) else { return }
        guard !onlyIfChanged || lastScrolledLiveProgramID != program.id else { return }
        lastScrolledLiveProgramID = program.id
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(program.id, anchor: .center)
            }
        } else {
            proxy.scrollTo(program.id, anchor: .center)
        }
    }

    private func liveDateTitle(_ date: Date) -> String {
        let calendar = liveGuideCalendar
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = liveGuideCalendar.timeZone
        formatter.dateFormat = "M/d EEE"
        return formatter.string(from: date)
    }

    private func loadLiveGuide() async {
        guard let context = liveContext else {
            livePrograms = []
            liveGuideMessage = nil
            return
        }
        guard !context.epgURL.isEmpty, let channel = context.currentChannel else {
            livePrograms = []
            liveGuideMessage = "当前配置没有提供节目单地址。"
            isLoadingLiveGuide = false
            return
        }
        isLoadingLiveGuide = true
        liveGuideMessage = nil
        do {
            let values = try await CatalogService().loadEPG(for: channel.name, template: context.epgURL, date: liveGuideDate)
            guard !Task.isCancelled else { return }
            livePrograms = values
            if values.isEmpty { liveGuideMessage = "这一天没有可用的节目单。" }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            livePrograms = []
            liveGuideMessage = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        isLoadingLiveGuide = false
    }

    private func liveProgramTarget(for program: TVBoxEPGProgram) -> (url: URL, isLive: Bool, durationMilliseconds: Int, catchupWindow: LiveCatchupWindow?)? {
        guard let context = liveContext,
              let channel = context.currentChannel,
              let source = context.currentSource,
              let interval = program.interval(on: liveGuideDate) else { return nil }
        let now = liveGuideClock
        if now < interval.start { return nil }
        if now < interval.end {
            guard let url = URL(string: source.address), Self.isSupportedStreamURL(url) else { return nil }
            return (url, true, 0, nil)
        }
        guard let sourceIndex = channel.sources.firstIndex(of: source) else { return nil }
        let template = sourceIndex < channel.catchupSources.count ? channel.catchupSources[sourceIndex] : ""
        let window = LiveCatchupWindow(
            sourceAddress: source.address,
            template: template,
            start: interval.start,
            end: interval.end
        )
        guard let url = window.url(), Self.isSupportedStreamURL(url) else { return nil }
        return (url, false, window.durationMilliseconds, window)
    }

    private func selectLiveSource(_ source: TVBoxLiveSource) {
        guard let context = liveContext,
              source.id != context.sourceID,
              let request = context.request(groupID: context.groupID, channelID: context.channelID, sourceID: source.id) else { return }
        isSwitchingEpisode = true
        session.replace(with: request)
        isSwitchingEpisode = false
        #if os(tvOS)
        livePanelFocusTarget = "source:\(source.id)"
        #endif
    }

    private func selectLiveChannel(_ channel: TVBoxLiveChannel, group: TVBoxLiveGroup) {
        guard let context = liveContext else { return }
        selectedLiveGroupID = group.id
        guard !(group.id == context.groupID && channel.id == context.channelID && session.request.isLive) else { return }
        guard let source = channel.sources.first(where: { source in
            guard let url = URL(string: source.address) else { return false }
            return Self.isSupportedStreamURL(url)
        }),
        let request = context.request(groupID: group.id, channelID: channel.id, sourceID: source.id) else { return }
        isSwitchingEpisode = true
        session.replace(with: request)
        isSwitchingEpisode = false
        #if os(tvOS)
        livePanelFocusTarget = "channel:\(group.id):\(channel.id)"
        #endif
    }

    private func toggleLivePanel(_ panel: LivePlayerPanel) {
        if landscapeLivePanel == panel {
            controlsHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) {
                landscapeLivePanel = nil
                areControlsVisible = false
            }
        } else {
            controlsHideTask?.cancel()
            if panel == .guide, let currentGroupID = liveContext?.groupID {
                selectedLiveGroupID = currentGroupID
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                landscapeLivePanel = panel
                areControlsVisible = false
            }
            #if os(tvOS)
            playerSurfaceFocused = false
            Task { @MainActor in
                await Task.yield()
                guard landscapeLivePanel == panel else { return }
                if panel == .sources, let source = liveContext?.currentSource {
                    livePanelFocusTarget = "source:\(source.id)"
                }
            }
            #endif
        }
    }

    private static func isSupportedStreamURL(_ url: URL) -> Bool {
        ["http", "https", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "")
    }

    private var failureCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("无法播放此地址")
                .font(.system(size: TVBoxTypography.readable(20), weight: .bold, design: .rounded))
            Button("重试") { session.retry() }
                .buttonStyle(.borderedProminent)
        }
        .padding(22)
        .frame(maxWidth: 520)
        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 22))
    }

    private func controlPanel(compact: Bool, includesTransportControls: Bool = true) -> some View {
        VStack(spacing: compact ? 10 : 13) {
            if includesTransportControls {
                transportControls(compact: compact)
            }

            HStack(spacing: compact ? 8 : 12) {
                Text(isScrubbing ? Self.clockString(fraction: seekValue, duration: session.durationText) : session.elapsedText)
                    .font(.system(size: TVBoxTypography.readable(11, minimum: 23), weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize()
                #if os(tvOS)
                tvProgressControl
                #else
                Slider(value: Binding(
                    get: { isScrubbing ? seekValue : session.progress },
                    set: { seekValue = $0 }
                ), in: 0...1, onEditingChanged: { editing in
                    if editing {
                        seekValue = session.progress
                        isScrubbing = true
                    } else {
                        isScrubbing = false
                        session.seek(to: seekValue)
                    }
                })
                .tint(Color.tvboxAccent)
                .disabled(!session.canSeek)
                #endif
                Text(session.durationText)
                    .font(.system(size: TVBoxTypography.readable(11, minimum: 23), weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize()
            }

            if compact {
                HStack(spacing: 8) {
                    aspectRatioMenu
                    ScrollView(.horizontal, showsIndicators: false) { additionalPlaybackOptions }
                }
            } else {
                playbackOptions
            }
            if compact {
                Text(isSwitchingEpisode ? "正在切换剧集…" : session.status)
                    .font(.system(size: TVBoxTypography.readable(11, minimum: 23), weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, compact ? 13 : 18)
        .padding(.vertical, compact ? 12 : 15)
        #if os(tvOS)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous))
        #else
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 18 : 22).strokeBorder(.white.opacity(0.09), lineWidth: 1))
        #endif
        .simultaneousGesture(TapGesture().onEnded { revealControls() })
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func transportControls(compact: Bool, centered: Bool = false) -> some View {
        HStack(spacing: compact ? 7 : 12) {
            if session.request.queueIndex > 0 {
                controlButton(title: session.request.isLive ? "上一频道" : "上一集", systemImage: "backward.end.fill") { moveToEpisode(-1) }
                    .disabled(isSwitchingEpisode)
            }
            controlButton(title: "后退 15 秒", systemImage: "gobackward.15") { session.seek(by: -15) }
                .disabled(!session.canSeekByTime)
            Button {
                revealControls()
                session.togglePlayback()
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: TVBoxTypography.readable(compact ? 20 : 18, minimum: 32), weight: .bold))
                    .frame(width: TVBoxTypography.readable(compact ? 60 : 52, minimum: 88), height: TVBoxTypography.readable(compact ? 60 : 52, minimum: 88))
            }
            .playerControlButtonStyle(isAccent: true)
            #if os(tvOS)
            .focused($playControlFocused)
            #endif
            .accessibilityLabel(session.isPlaying ? "暂停" : "播放")
            controlButton(title: "前进 15 秒", systemImage: "goforward.15") { session.seek(by: 15) }
                .disabled(!session.canSeekByTime)
            if session.request.queueIndex + 1 < session.request.queue.count {
                controlButton(title: session.request.isLive ? "下一频道" : "下一集", systemImage: "forward.end.fill") { moveToEpisode(1) }
                    .disabled(isSwitchingEpisode)
            }
            if !compact {
                Spacer(minLength: 12)
                Text(isSwitchingEpisode ? "正在切换剧集…" : session.status)
                    .font(.system(size: TVBoxTypography.readable(12, minimum: 23), weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, centered ? 18 : 0)
        .padding(.vertical, centered ? 13 : 0)
        .background(centered ? Color.black.opacity(0.58) : .clear, in: Capsule())
    }

    private func controlButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            revealControls()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: TVBoxTypography.readable(17, minimum: 28), weight: .semibold))
                .frame(width: TVBoxTypography.readable(42, minimum: 72), height: TVBoxTypography.readable(42, minimum: 72))
        }
        .playerControlButtonStyle()
        .accessibilityLabel(title)
    }

    private var playbackOptions: some View {
        HStack(spacing: 9) {
            aspectRatioMenu
            additionalPlaybackOptions
        }
    }

    private var additionalPlaybackOptions: some View {
        HStack(spacing: 9) {
#if os(iOS)
            if session.isPictureInPictureReady {
                Button {
                    session.startPictureInPicture()
                } label: {
                    trackMenuLabel(title: "画中画", systemImage: "pip.enter")
                }
                .playerControlButtonStyle()
                .accessibilityLabel("开始画中画播放")
            }
#endif
            if session.request.availableLines.count > 1 {
                lineMenu
            }
            if !session.audioTracks.isEmpty {
                trackMenu(title: "音轨", systemImage: "waveform", options: session.audioTracks, selectedIndex: session.selectedAudioTrackIndex) {
                    session.selectAudioTrack($0)
                }
            }
            if !session.subtitleTracks.isEmpty {
                #if os(iOS)
                Button {
                    presentSubtitleSelection()
                } label: {
                    trackMenuLabel(title: "字幕", systemImage: "captions.bubble")
                }
                .playerControlButtonStyle()
                #else
                trackMenu(title: "字幕", systemImage: "captions.bubble", options: session.subtitleTracks, selectedIndex: session.selectedSubtitleTrackIndex) {
                    session.selectSubtitleTrack($0)
                }
                #endif
            }
            if !session.request.isLive {
                danmakuMenu
            }
            #if os(tvOS)
            Button {
                presentPlayerMenu(
                    title: "播放速度",
                    options: [0.75, 1.0, 1.25, 1.5, 2.0].map { rate in
                        PlayerMenuOption(
                            id: String(rate),
                            title: rate == 1 ? "正常速度" : Self.rateLabel(rate),
                            action: { session.setPlaybackRate(Float(rate)) }
                        )
                    }
                )
            } label: {
                playbackRateLabel
            }
            .playerControlButtonStyle()
            .accessibilityLabel("播放速度：\(session.playbackRate == 1 ? "正常速度" : Self.rateLabel(Double(session.playbackRate)))")
            #else
            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button(rate == 1 ? "正常速度" : Self.rateLabel(rate)) {
                        session.setPlaybackRate(Float(rate))
                    }
                }
            } label: {
                playbackRateLabel
            }
            .playerControlButtonStyle()
            .accessibilityLabel("播放速度：\(session.playbackRate == 1 ? "正常速度" : Self.rateLabel(Double(session.playbackRate)))")
            #endif
            #if os(iOS)
            Button(action: toggleOrientation) {
                trackMenuLabel(title: "横竖屏", systemImage: "rotate.right")
            }
            .playerControlButtonStyle()
            .accessibilityLabel("切换横竖屏")
            #endif
            Spacer(minLength: 0)
        }
    }

    private var playbackRateLabel: some View {
        trackMenuLabel(title: "播放速度", systemImage: "speedometer")
    }

    private var danmakuMenu: some View {
        #if os(tvOS)
        Button {
            presentPlayerMenu(
                title: "弹幕",
                options: [
                    PlayerMenuOption(id: "search", title: "在线搜索弹幕", action: presentDanmakuSearch),
                    PlayerMenuOption(id: "toggle", title: danmakuEnabled ? "关闭弹幕" : "开启弹幕", action: { danmakuEnabled.toggle() }),
                    PlayerMenuOption(id: "settings", title: "弹幕设置", action: presentDanmakuSettings)
                ]
            )
        } label: {
            danmakuMenuLabel
        }
        .playerControlButtonStyle()
        .accessibilityLabel("弹幕菜单")
        .accessibilityHint(danmakuLoadError ?? danmakuMatchTitle.map { "当前匹配：\($0)" } ?? "在线搜索、切换显示或调整弹幕")
        #else
        Menu {
            Button("在线搜索弹幕", action: presentDanmakuSearch)
            Button(danmakuEnabled ? "关闭弹幕" : "开启弹幕") { danmakuEnabled.toggle() }
            Button("弹幕设置", action: presentDanmakuSettings)
        } label: {
            danmakuMenuLabel
        }
        .playerControlButtonStyle()
        .accessibilityLabel("弹幕菜单")
        .accessibilityHint(danmakuLoadError ?? danmakuMatchTitle.map { "当前匹配：\($0)" } ?? "在线搜索、切换显示或调整弹幕")
        #endif
    }

    private var danmakuMenuLabel: some View {
        trackMenuLabel(
            title: danmakuLoadError == nil
                ? (danmakuMatchTitle == nil ? (danmakuEnabled ? "弹幕" : "弹幕关") : "弹幕已匹配")
                : "弹幕错误",
            systemImage: "bubble.left.and.bubble.right"
        )
    }

    private var currentDanmakuEpisodeTitle: String {
        let queue = session.request.queue
        guard queue.indices.contains(session.request.queueIndex) else { return "" }
        return queue[session.request.queueIndex].title
    }

    private func presentDanmakuSearch() {
        danmakuSearchPlaybackGeneration = session.playbackGeneration
        resumePlaybackAfterDanmakuSearch = shouldResumePlayback
        session.pause()
        showingDanmakuSearch = true
    }

    private func loadEpisodeDanmaku() {
        danmakuTask?.cancel()
        danmakuGeneration += 1
        danmakuComments = []
        danmakuLoadError = nil
        danmakuMatchTitle = nil
        guard danmakuEnabled, !session.request.isLive else { return }
        let generation = danmakuGeneration
        let headers = session.request.headers
        let source = session.request.danmakuSource?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let item = session.request.item
        let mediaTitle = item?.title ?? session.title
        let category = item?.category ?? ""
        let year = item?.year ?? ""
        let episodeTitle = currentDanmakuEpisodeTitle
        let isSeries = session.request.queue.count > 1
        let apiAddress = danmakuAPIAddress
        danmakuTask = Task { @MainActor in
            do {
                let service = DanmakuService()
                let comments: [DanmakuComment]
                let matchTitle: String
                if !source.isEmpty {
                    comments = try await service.comments(from: source, headers: headers)
                    matchTitle = "\(mediaTitle) · \(episodeTitle)"
                } else {
                    let match = try await service.automaticMatch(
                        title: mediaTitle,
                        category: category,
                        year: year,
                        episodeTitle: episodeTitle,
                        isSeries: isSeries,
                        apiAddress: apiAddress
                    )
                    comments = match.comments
                    matchTitle = match.matchTitle
                }
                guard !Task.isCancelled, generation == danmakuGeneration else { return }
                danmakuComments = comments
                danmakuMatchTitle = matchTitle
                danmakuGeneration += 1
            } catch {
                guard !Task.isCancelled, generation == danmakuGeneration else { return }
                danmakuLoadError = "\(error.localizedDescription) 点按弹幕菜单可手动搜索。"
            }
        }
    }

    private static let aspectRatios = [
        AspectRatioOption(label: "原始", value: ""),
        AspectRatioOption(label: "16:9", value: "16:9"),
        AspectRatioOption(label: "4:3", value: "4:3"),
        AspectRatioOption(label: "1:1", value: "1:1"),
        AspectRatioOption(label: "2.35:1", value: "2.35:1")
    ]

    private var aspectRatioMenu: some View {
        #if os(tvOS)
        Button {
            presentPlayerMenu(
                title: "画面比例",
                options: Self.aspectRatios.map { option in
                    PlayerMenuOption(
                        id: option.id,
                        title: option.label == session.aspectRatioLabel ? "✓  \(option.label)" : option.label,
                        action: { selectAspectRatio(option) }
                    )
                }
            )
        } label: {
            trackMenuLabel(title: session.aspectRatioLabel, systemImage: "aspectratio")
        }
        .playerControlButtonStyle()
        .accessibilityLabel("画面比例：\(session.aspectRatioLabel)")
        #else
        Menu {
            ForEach(Self.aspectRatios) { option in
                Button {
                    selectAspectRatio(option)
                } label: {
                    if option.label == session.aspectRatioLabel {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            trackMenuLabel(title: session.aspectRatioLabel, systemImage: "aspectratio")
        }
        .playerControlButtonStyle()
        .accessibilityLabel("画面比例：\(session.aspectRatioLabel)")
        #endif
    }

    private func selectAspectRatio(_ option: AspectRatioOption) {
        savedAspectRatio = option.value
        session.setAspectRatio(option.value.isEmpty ? nil : option.value, label: option.label)
    }

    private func presentPlayerMenu(
        title: String,
        options: [PlayerMenuOption],
        pausesPlaybackForSelection: Bool = false
    ) {
        playerMenuTitle = title
        playerMenuOptions = options
        if pausesPlaybackForSelection {
            resumePlaybackAfterPlayerMenu = shouldResumePlayback
            session.pause()
        }
        showingPlayerMenu = true
    }

    private var shouldResumePlayback: Bool {
        session.playbackRequested || session.isPlaying
    }

    private func presentSubtitleSelection() {
        resumePlaybackAfterSubtitleSelection = shouldResumePlayback
        session.pause()
        showingSubtitleTracks = true
    }

    private func presentDanmakuSettings() {
        resumePlaybackAfterDanmakuSettings = shouldResumePlayback
        session.pause()
        showingDanmakuSettings = true
    }

    #if os(tvOS)
    private var tvProgressControl: some View {
        GeometryReader { geometry in
            let fraction = min(1, max(0, isScrubbing ? seekValue : session.progress))
            let inset: CGFloat = 14

            Button {} label: {
                ZStack(alignment: .leading) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Color.tvboxSelection)
                        .frame(height: 6)
                        .padding(.horizontal, inset)

                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.tvboxSelection, lineWidth: progressFocused ? 3 : 0)
                                .padding(-4)
                        }
                        .offset(x: inset + max(1, geometry.size.width - inset * 2) * CGFloat(fraction) - 9)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($progressFocused)
            .focusEffectDisabled()
            .disabled(!session.canSeek)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(session.elapsedText) / \(session.durationText)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: session.seek(by: 15)
                case .decrement: session.seek(by: -15)
                @unknown default: break
                }
            }
            .onMoveCommand { direction in
                switch direction {
                case .left: previewProgress(bySeconds: -5)
                case .right: previewProgress(bySeconds: 5)
                default: break
                }
            }
        }
        .frame(height: 56)
    }

    private func previewProgress(bySeconds seconds: Double) {
        guard session.seekDurationMilliseconds > 0 else { return }
        if !isScrubbing {
            seekValue = session.progress
            isScrubbing = true
        }
        let delta = seconds * 1_000 / Double(session.seekDurationMilliseconds)
        seekValue = min(1, max(0, seekValue + delta))
        progressScrubCommitTask?.cancel()
        progressScrubCommitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            finishProgressScrubbing()
        }
    }

    private func finishProgressScrubbing() {
        progressScrubCommitTask?.cancel()
        progressScrubCommitTask = nil
        guard isScrubbing else { return }
        isScrubbing = false
        session.seek(to: seekValue)
    }
    #endif

    private func trackMenu(
        title: String,
        systemImage: String,
        options: [VLCTrackOption],
        selectedIndex: Int,
        select: @escaping (Int) -> Void
    ) -> some View {
        Button {
            presentPlayerMenu(
                title: title,
                options: options.map { option in
                    PlayerMenuOption(
                        id: String(option.index),
                        title: option.index == selectedIndex ? "✓  \(option.title)" : option.title,
                        action: { select(option.index) }
                    )
                },
                pausesPlaybackForSelection: true
            )
        } label: {
            trackMenuLabel(title: title, systemImage: systemImage)
        }
        .playerControlButtonStyle()
        .accessibilityLabel(title)
    }

    private func trackMenuLabel(title: String, systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: TVBoxTypography.readable(16, minimum: 28), weight: .semibold))
            .frame(width: TVBoxTypography.readable(42, minimum: 72), height: TVBoxTypography.readable(42, minimum: 72))
            .contentShape(Capsule())
            .accessibilityLabel(title)
    }

    private var lineMenu: some View {
        #if os(tvOS)
        Button {
            presentPlayerMenu(
                title: "播放线路",
                options: session.request.availableLines.map { line in
                    PlayerMenuOption(
                        id: line.id,
                        title: line.id == session.request.lineID ? "✓  \(line.flag)" : line.flag,
                        action: { switchPlaybackLine(line) }
                    )
                }
            )
        } label: {
            trackMenuLabel(title: "线路", systemImage: "rectangle.stack")
        }
        .playerControlButtonStyle()
        .accessibilityLabel("播放线路")
        #else
        Menu {
            ForEach(session.request.availableLines) { line in
                Button {
                    switchPlaybackLine(line)
                } label: {
                    if line.id == session.request.lineID {
                        Label(line.flag, systemImage: "checkmark")
                    } else {
                        Text(line.flag)
                    }
                }
            }
        } label: {
            trackMenuLabel(title: "线路", systemImage: "rectangle.stack")
        }
        .playerControlButtonStyle()
        .accessibilityLabel("播放线路")
        #endif
    }

    private func switchPlaybackLine(_ line: PlaybackLine) {
        let current = session.request
        guard let item = current.item, line.id != current.lineID, !line.episodes.isEmpty else { return }
        let currentEpisode = current.queue.indices.contains(current.queueIndex) ? current.queue[current.queueIndex] : nil
        let nextIndex = currentEpisode.flatMap { episode in
            line.episodes.firstIndex(where: { $0.title.caseInsensitiveCompare(episode.title) == .orderedSame })
        } ?? min(current.queueIndex, line.episodes.count - 1)
        let episode = line.episodes[nextIndex]
        isSwitchingEpisode = true
        persistPlaybackPosition()
        vodSelectionTask?.cancel()
        vodSelectionTask = Task {
            do {
                let next = try await catalog.playbackRequest(
                    for: item,
                    episode: episode,
                    queue: line.episodes,
                    queueIndex: nextIndex
                )
                guard !Task.isCancelled else { return }
                session.replace(with: next)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                #if os(tvOS)
                if landscapeLivePanel == .playlist, let currentEpisode {
                    livePanelFocusTarget = "vod:\(currentEpisode.id)"
                }
                #endif
            }
            guard !Task.isCancelled else { return }
            isSwitchingEpisode = false
        }
    }

    private func selectVodEpisode(_ episode: Episode, at index: Int) {
        let current = session.request
        guard index != current.queueIndex,
              let item = current.item,
              !isSwitchingEpisode else { return }
        isSwitchingEpisode = true
        persistPlaybackPosition()
        vodSelectionTask?.cancel()
        vodSelectionTask = Task {
            do {
                let next = try await catalog.playbackRequest(
                    for: item,
                    episode: episode,
                    queue: current.queue,
                    queueIndex: index
                )
                guard !Task.isCancelled else { return }
                session.replace(with: next)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                #if os(tvOS)
                if landscapeLivePanel == .playlist, current.queue.indices.contains(current.queueIndex) {
                    livePanelFocusTarget = "vod:\(current.queue[current.queueIndex].id)"
                }
                #endif
            }
            guard !Task.isCancelled else { return }
            isSwitchingEpisode = false
        }
    }

    private func moveToEpisode(_ offset: Int) {
        let current = session.request
        let targetIndex = current.queueIndex + offset
        guard current.queue.indices.contains(targetIndex) else { return }
        let episode = current.queue[targetIndex]
        if let context = current.liveContext,
           let target = context.groups.compactMap({ group in
               group.channels.first(where: { "live::\(group.id)::\($0.id)" == episode.id }).map { (group, $0) }
           }).first,
           let source = target.1.sources.first(where: { source in
               guard let url = URL(string: source.address) else { return false }
               return Self.isSupportedStreamURL(url)
           }),
           let request = context.request(groupID: target.0.id, channelID: target.1.id, sourceID: source.id) {
            isSwitchingEpisode = true
            session.replace(with: request)
            isSwitchingEpisode = false
            return
        }
        if current.isLive || current.item == nil {
            guard let url = URL(string: episode.address),
                  ["http", "https", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "") else { return }
            session.replace(with: PlaybackRequest(
                title: episode.title,
                url: url,
                headers: episode.headers,
                queue: current.queue,
                queueIndex: targetIndex,
                isLive: current.isLive,
                danmakuSource: episode.danmakuSource
            ))
            return
        }
        selectVodEpisode(episode, at: targetIndex)
    }

    private func persistPlaybackPosition() {
        guard session.canSeek, session.currentMilliseconds > 0 else { return }
        catalog.savePlaybackPosition(
            itemID: session.request.itemID,
            episodeID: session.request.episodeID,
            milliseconds: session.currentMilliseconds
        )
    }

    private func playerPadding(compact: Bool) -> CGFloat {
        #if os(tvOS)
        return 80
        #else
        return compact ? 15 : 24
        #endif
    }

    private static func clockString(fraction: Double, duration: String) -> String {
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        guard duration != "LIVE", !parts.isEmpty else { return "00:00" }
        let total = parts.reduce(0) { $0 * 60 + $1 }
        let seconds = Int(Double(total) * min(1, max(0, fraction)))
        let hours = seconds / 3_600
        let minutes = (seconds / 60) % 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", seconds / 60, remainingSeconds)
    }

    private static func rateLabel(_ rate: Double) -> String {
        String(format: "%.2g×", rate)
    }
}

private extension View {
    @ViewBuilder
    func platformListBackgroundHidden() -> some View {
        #if os(iOS)
        self.scrollContentBackground(.hidden)
        #else
        self
        #endif
    }

    @ViewBuilder
    func playerControlButtonStyle(isAccent: Bool = false) -> some View {
        if isAccent {
            self.buttonStyle(.borderedProminent)
                .tint(Color.tvboxSelection)
        } else {
            self.buttonStyle(.bordered)
                .tint(Color.white.opacity(0.85))
        }
    }
}
