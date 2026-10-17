import AVFoundation
import Combine
import Foundation
import KSPlayer
#if os(iOS)
import AVFAudio
import AVKit
#endif

struct KSPlaybackTrackOption: Identifiable, Hashable {
    let index: Int
    let title: String
    var id: Int { index }
}

@MainActor
final class KSPlaybackSession: NSObject, ObservableObject {
    @Published private(set) var status = "准备连接"
    @Published private(set) var failureMessage = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackRequested = false
    @Published private(set) var progress = 0.0
    @Published private(set) var elapsedText = "00:00"
    @Published private(set) var durationText = "--:--"
    @Published private(set) var currentMilliseconds = 0
    @Published private(set) var playbackGeneration = 0
    @Published private(set) var canSeek = false
    @Published private(set) var canSeekByTime = false
    @Published private(set) var title = ""
    @Published private(set) var audioTracks: [KSPlaybackTrackOption] = []
    @Published private(set) var subtitleTracks: [KSPlaybackTrackOption] = []
    @Published private(set) var selectedAudioTrackIndex = -1
    @Published private(set) var selectedSubtitleTrackIndex = -1
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var didReachEnd = false
    @Published private(set) var aspectRatioLabel = "原始"
#if os(iOS)
    @Published private(set) var isPictureInPictureReady = false
    @Published private(set) var isPictureInPictureActive = false
#endif

    let danmakuClock = DanmakuPlaybackClock()
    private(set) var request: PlaybackRequest
    private(set) var playerLayer: KSPlayerLayer!
    let subtitleModel = SubtitleModel()
    private var progressTimer: Timer?
    private var catchupOffsetMilliseconds = 0
    private var pendingResumePositionMilliseconds: Int?
    private var hasServerCatchupSeek = false
    private var aspectRatio: String?
    private var audioOptions: [MediaPlayerTrack] = []
    private var subtitleOptions: [MediaPlayerTrack] = []

    init(request: PlaybackRequest) {
        self.request = request
        title = request.title
        if !request.isLive {
            let resumePosition = request.resumeMilliseconds > 0 ? request.resumeMilliseconds : request.skipOpeningMilliseconds
            pendingResumePositionMilliseconds = resumePosition > 0 ? resumePosition : nil
        }
        super.init()
#if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
#endif
        playerLayer = makePlayerLayer(for: request)
        subtitleModel.url = request.url
        applySubtitlePreferences()
        startProgressUpdates()
    }

    func play() {
        guard !request.url.isFileURL || FileManager.default.fileExists(atPath: request.url.path) else {
            fail("本地媒体文件不存在。")
            return
        }
        failureMessage = ""
        playbackRequested = true
        status = "正在连接…"
        playerLayer.play()
        playerLayer.player.playbackRate = playbackRate
        refreshProgress()
    }

    func retry() {
        resetPlayerLayer(applyResumePosition: !hasServerCatchupSeek)
        play()
    }

    func replace(with request: PlaybackRequest) {
        hasServerCatchupSeek = false
        replace(with: request, catchupOffsetMilliseconds: 0)
    }

    private func replace(with request: PlaybackRequest, catchupOffsetMilliseconds: Int, autoplay: Bool = true, applyResumePosition: Bool = true) {
        self.request = request
        self.catchupOffsetMilliseconds = max(0, catchupOffsetMilliseconds)
        title = request.title
        resetPlayerLayer(applyResumePosition: applyResumePosition)
        if autoplay { play() } else { status = "已暂停" }
    }

    func togglePlayback() {
        if playbackRequested || isPlaying { pause() } else { play() }
    }

    func pause() {
        playbackRequested = false
        playerLayer.pause()
        isPlaying = false
        danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
        status = "已暂停"
        refreshProgress()
    }

    func seek(by seconds: Int) {
        guard canSeekByTime, totalDurationMilliseconds > 0 else { return }
        let target = min(totalDurationMilliseconds, max(0, currentMilliseconds + seconds * 1_000))
        seek(to: Double(target) / Double(totalDurationMilliseconds))
    }

    func seek(to fraction: Double) {
        guard canSeek, totalDurationMilliseconds > 0 else { return }
        pendingResumePositionMilliseconds = nil
        let target = min(totalDurationMilliseconds, max(0, Int(Double(totalDurationMilliseconds) * min(1, max(0, fraction)))))
        if let window = request.catchupWindow, window.supportsServerSeeking,
           let url = window.url(startingAtMilliseconds: min(target, max(0, window.durationMilliseconds - 1_000))) {
            let shouldResume = playbackRequested || isPlaying
            hasServerCatchupSeek = true
            replace(
                with: request.replacing(url: url),
                catchupOffsetMilliseconds: min(target, max(0, window.durationMilliseconds - 1_000)),
                autoplay: shouldResume,
                applyResumePosition: false
            )
            return
        }
        let localMilliseconds = max(0, target - catchupOffsetMilliseconds)
        let seekLayer = playerLayer!
        let generation = playbackGeneration
        playerLayer.seek(time: Double(localMilliseconds) / 1_000, autoPlay: playbackRequested || isPlaying) { [weak self, weak seekLayer] success in
            Task { @MainActor [weak self] in
                guard let self, success, let seekLayer,
                      self.playerLayer === seekLayer,
                      self.playbackGeneration == generation else { return }
                self.danmakuClock.anchor(to: Double(target), at: ProcessInfo.processInfo.systemUptime, resetRate: true)
                self.refreshProgress()
            }
        }
        danmakuClock.anchor(to: Double(target), at: ProcessInfo.processInfo.systemUptime, resetRate: true)
        refreshProgress()
    }

    func selectAudioTrack(_ index: Int) {
        guard audioOptions.indices.contains(index) else { return }
        playerLayer.player.select(track: audioOptions[index])
        selectedAudioTrackIndex = index
    }

    func selectSubtitleTrack(_ index: Int) {
        if index < 0 {
            subtitleOptions.forEach { $0.isEnabled = false }
            subtitleModel.selectedSubtitleInfo = nil
            selectedSubtitleTrackIndex = -1
            return
        }
        guard subtitleOptions.indices.contains(index) else { return }
        subtitleOptions.forEach { $0.isEnabled = false }
        playerLayer.player.select(track: subtitleOptions[index])
        subtitleModel.selectedSubtitleInfo = subtitleModel.subtitleInfos.first {
            ($0 as? MediaPlayerTrack)?.trackID == subtitleOptions[index].trackID
        }
        selectedSubtitleTrackIndex = index
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        playerLayer.player.playbackRate = rate
        danmakuClock.setPlaybackRate(rate, at: ProcessInfo.processInfo.systemUptime)
    }

    func setAspectRatio(_ ratio: String?, label: String) {
        aspectRatio = ratio
        aspectRatioLabel = label
        guard let view = playerLayer.player.view else { return }
        switch ratio {
        case "fill": view.contentMode = .scaleAspectFill
        default: view.contentMode = .scaleAspectFit
        }
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        playerLayer.delegate = nil
        playerLayer.stop()
        playbackRequested = false
        isPlaying = false
        danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
#if os(iOS)
        playerLayer.player.pipController?.stopPictureInPicture()
        isPictureInPictureReady = false
        isPictureInPictureActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

#if os(iOS)
    func startPictureInPicture() {
        guard isPictureInPictureReady else { return }
        playerLayer.isPipActive = true
    }
#endif

    private var totalDurationMilliseconds: Int {
        if let window = request.catchupWindow { return window.durationMilliseconds }
        if request.durationMilliseconds > 0 { return request.durationMilliseconds }
        let seconds = playerLayer.player.duration
        return seconds.isFinite ? max(0, Int(seconds * 1_000)) : 0
    }

    var seekDurationMilliseconds: Int { totalDurationMilliseconds }

    private var currentPlaybackMilliseconds: Int {
        let seconds = playerLayer.player.currentPlaybackTime
        return max(0, catchupOffsetMilliseconds + (seconds.isFinite ? Int(seconds * 1_000) : 0))
    }

    private func makePlayerLayer(for request: PlaybackRequest) -> KSPlayerLayer {
        // Prefer the FFmpeg based kernel so non-Apple codecs and stream protocols use the same path.
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = KSAVPlayer.self
        let options = makeOptions(for: request)
        return KSPlayerLayer(url: request.url, isAutoPlay: false, options: options, delegate: self)
    }

    private func makeOptions(for request: PlaybackRequest) -> KSOptions {
        let preferences = KSPlaybackPreferences.current
        let options = KSOptions()
        options.hardwareDecode = preferences.hardwareDecode
        options.asynchronousDecompression = preferences.asynchronousDecompression && preferences.hardwareDecode
        options.isAccurateSeek = preferences.accurateSeek
        options.isSecondOpen = preferences.secondOpen
        options.autoSelectEmbedSubtitle = preferences.autoSelectEmbeddedSubtitle
        options.autoDeInterlace = preferences.autoDeinterlace
        options.preferredForwardBufferDuration = preferences.preferredBufferSeconds
        options.maxBufferDuration = preferences.maximumBufferSeconds
        options.registerRemoteControll = true
        for (name, value) in request.headers {
            if name.caseInsensitiveCompare("User-Agent") == .orderedSame {
                options.userAgent = value
            }
            options.appendHeader([name: value])
        }
        return options
    }

    private func resetPlayerLayer(applyResumePosition: Bool) {
        progressTimer?.invalidate()
        progressTimer = nil
        do {
            let previousLayer = playerLayer!
            previousLayer.delegate = nil
#if os(iOS)
            previousLayer.isPipActive = false
#endif
            previousLayer.stop()
            playerLayer = nil
        }
        playerLayer = makePlayerLayer(for: request)
        playbackGeneration += 1
        catchupOffsetMilliseconds = max(0, catchupOffsetMilliseconds)
        failureMessage = ""
        status = "正在连接…"
        playbackRequested = false
        isPlaying = false
        didReachEnd = false
        pendingResumePositionMilliseconds = applyResumePosition && !request.isLive
            ? (request.resumeMilliseconds > 0 ? request.resumeMilliseconds : request.skipOpeningMilliseconds)
            : nil
        if pendingResumePositionMilliseconds == 0 { pendingResumePositionMilliseconds = nil }
        audioTracks = []
        subtitleTracks = []
        audioOptions = []
        subtitleOptions = []
        selectedAudioTrackIndex = -1
        selectedSubtitleTrackIndex = -1
        subtitleModel.selectedSubtitleInfo = nil
        subtitleModel.url = request.url
        applySubtitlePreferences()
        danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
        danmakuClock.resetSampleSynchronization()
        danmakuClock.setPlaybackRate(playbackRate, at: ProcessInfo.processInfo.systemUptime)
        danmakuClock.anchor(to: Double(max(0, catchupOffsetMilliseconds)), at: ProcessInfo.processInfo.systemUptime, resetRate: true)
        startProgressUpdates()
    }

    private func startProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshProgress() }
        }
    }

    private func refreshProgress() {
        let current = currentPlaybackMilliseconds
        let total = totalDurationMilliseconds
        currentMilliseconds = current
        elapsedText = Self.clockString(milliseconds: current)
        durationText = total > 0 ? Self.clockString(milliseconds: total) : (request.isLive ? "LIVE" : "--:--")
        progress = total > 0 ? min(1, Double(current) / Double(total)) : 0
        let seekable = playerLayer.player.isReadyToPlay && playerLayer.player.seekable
        let canSeekValue = total > 0 && (request.catchupWindow?.supportsServerSeeking == true || (!request.isLive && seekable))
        canSeek = canSeekValue
        canSeekByTime = canSeekValue
        if canSeekValue, let resumePosition = pendingResumePositionMilliseconds {
            pendingResumePositionMilliseconds = nil
            seek(to: Double(min(resumePosition, total)) / Double(total))
            return
        }
        refreshTracks()
        _ = subtitleModel.subtitle(currentTime: Double(max(0, currentPlaybackMilliseconds - catchupOffsetMilliseconds)) / 1_000)
        refreshPictureInPictureState()
        danmakuClock.reconcile(with: Double(current), at: ProcessInfo.processInfo.systemUptime)
    }

    private func refreshTracks() {
        let currentAudioTracks = playerLayer.player.tracks(mediaType: .audio)
        audioOptions = currentAudioTracks
        let mappedAudioTracks = currentAudioTracks.enumerated().map { index, track in
            KSPlaybackTrackOption(index: index, title: track.name.isEmpty ? (track.languageCode ?? "音轨 \(index + 1)") : track.name)
        }
        if audioTracks != mappedAudioTracks { audioTracks = mappedAudioTracks }
        let audioSelection = currentAudioTracks.firstIndex(where: \.isEnabled) ?? -1
        if selectedAudioTrackIndex != audioSelection { selectedAudioTrackIndex = audioSelection }

        let currentSubtitleTracks = playerLayer.player.tracks(mediaType: .subtitle)
        subtitleOptions = currentSubtitleTracks
        let mappedSubtitleTracks = [KSPlaybackTrackOption(index: -1, title: "关闭字幕")] + currentSubtitleTracks.enumerated().map { index, track in
            KSPlaybackTrackOption(index: index, title: track.name.isEmpty ? (track.languageCode ?? "字幕 \(index + 1)") : track.name)
        }
        if subtitleTracks != mappedSubtitleTracks { subtitleTracks = mappedSubtitleTracks }
        let subtitleSelection = currentSubtitleTracks.firstIndex(where: \.isEnabled) ?? -1
        if selectedSubtitleTrackIndex != subtitleSelection { selectedSubtitleTrackIndex = subtitleSelection }
    }

    private func refreshPictureInPictureState() {
#if os(iOS)
        isPictureInPictureReady = AVPictureInPictureController.isPictureInPictureSupported() && playerLayer.player.pipController != nil
        isPictureInPictureActive = playerLayer.player.pipController?.isPictureInPictureActive ?? false
#endif
    }

    private func fail(_ message: String) {
        failureMessage = message
        status = "播放失败"
        playbackRequested = false
        isPlaying = false
        danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
    }

    private func applySubtitlePreferences() {
        let defaults = UserDefaults.standard
        SubtitleModel.textFontSize = CGFloat(defaults.object(forKey: "tvbox.ksplayer.subtitleFontSize") as? Double ?? 26)
        SubtitleModel.textBold = defaults.object(forKey: "tvbox.ksplayer.subtitleBold") as? Bool ?? false
        subtitleModel.subtitleDelay = defaults.object(forKey: "tvbox.ksplayer.subtitleDelay") as? Double ?? 0
    }

    private static func clockString(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
}

extension KSPlaybackSession: KSPlayerLayerDelegate {
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard playerLayer === layer else { return }
        switch state {
            case .initialized:
                self.isPlaying = false
                if self.playbackRequested { self.status = "正在连接…" }
                self.danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
            case .preparing:
                self.isPlaying = false
                self.status = "正在连接…"
                self.danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
            case .readyToPlay:
                self.failureMessage = ""
                self.status = "准备就绪"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak layer] in
                    guard let self, let layer, self.playerLayer === layer,
                          let dataSource = layer.player.subtitleDataSouce else { return }
                    self.subtitleModel.addSubtitle(dataSouce: dataSource)
                    if self.subtitleModel.selectedSubtitleInfo == nil,
                       KSPlaybackPreferences.current.autoSelectEmbeddedSubtitle {
                        self.subtitleModel.selectedSubtitleInfo = dataSource.infos.first { $0.isEnabled }
                    }
                }
                self.refreshProgress()
            case .buffering:
                self.isPlaying = false
                self.status = self.playbackRequested ? "正在缓冲…" : "已暂停"
                self.danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
            case .bufferFinished:
                self.isPlaying = true
                self.status = "正在播放"
                self.danmakuClock.setAdvancing(true, at: ProcessInfo.processInfo.systemUptime)
            case .paused:
                self.isPlaying = false
                if self.playbackRequested { self.status = "正在缓冲…" }
                self.danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
            case .playedToTheEnd:
                self.playbackRequested = false
                self.isPlaying = false
                self.status = "播放结束"
                self.didReachEnd = true
                self.danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
            case .error:
                self.fail("KSPlayer 无法打开此媒体。请检查片源地址、请求头或解码设置。")
        }
        refreshProgress()
    }

    func player(layer: KSPlayerLayer, currentTime _: TimeInterval, totalTime _: TimeInterval) {
        guard playerLayer === layer else { return }
        refreshProgress()
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard playerLayer === layer, let error else { return }
        fail(error.localizedDescription)
    }

    func player(layer _: KSPlayerLayer, bufferedCount _: Int, consumeTime _: TimeInterval) {}
}

private struct KSPlaybackPreferences {
    var hardwareDecode: Bool
    var asynchronousDecompression: Bool
    var accurateSeek: Bool
    var secondOpen: Bool
    var autoSelectEmbeddedSubtitle: Bool
    var autoDeinterlace: Bool
    var preferredBufferSeconds: TimeInterval
    var maximumBufferSeconds: TimeInterval

    static var current: KSPlaybackPreferences {
        let defaults = UserDefaults.standard
        let maximum = min(60.0, max(5.0, defaults.object(forKey: "tvbox.ksplayer.maximumBufferSeconds") as? Double ?? 30.0))
        let preferred = min(maximum, max(1.0, defaults.object(forKey: "tvbox.ksplayer.preferredBufferSeconds") as? Double ?? 3.0))
        return KSPlaybackPreferences(
            hardwareDecode: defaults.object(forKey: "tvbox.ksplayer.hardwareDecode") as? Bool ?? true,
            asynchronousDecompression: defaults.bool(forKey: "tvbox.ksplayer.asynchronousDecompression"),
            accurateSeek: defaults.bool(forKey: "tvbox.ksplayer.accurateSeek"),
            secondOpen: defaults.bool(forKey: "tvbox.ksplayer.secondOpen"),
            autoSelectEmbeddedSubtitle: defaults.object(forKey: "tvbox.ksplayer.autoSelectEmbeddedSubtitle") as? Bool ?? true,
            autoDeinterlace: defaults.bool(forKey: "tvbox.ksplayer.autoDeinterlace"),
            preferredBufferSeconds: preferred,
            maximumBufferSeconds: maximum
        )
    }
}
