import AVFoundation
import AVKit
import Combine
import Foundation
#if os(iOS)
import AVFAudio
#endif

struct AVTrackOption: Identifiable, Hashable {
    let index: Int
    let title: String
    var id: Int { index }
}

@MainActor
final class AVPlaybackSession: NSObject, ObservableObject {
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
    @Published private(set) var audioTracks: [AVTrackOption] = []
    @Published private(set) var subtitleTracks: [AVTrackOption] = []
    @Published private(set) var selectedAudioTrackIndex = -1
    @Published private(set) var selectedSubtitleTrackIndex = -1
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var didReachEnd = false
    @Published private(set) var aspectRatioLabel = "原始"
#if os(iOS)
    @Published private(set) var isPictureInPictureReady = false
    @Published private(set) var isPictureInPictureActive = false
#endif

    let player = AVPlayer()
    let danmakuClock = DanmakuPlaybackClock()
    private(set) var request: PlaybackRequest
    private var progressTimer: Timer?
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var catchupOffsetMilliseconds = 0
    private var pendingResumePositionMilliseconds: Int?
    private var hasServerCatchupSeek = false
    private var aspectRatio: String?
    private var audioOptions: [AVMediaSelectionOption] = []
    private var subtitleOptions: [AVMediaSelectionOption] = []
#if os(iOS)
    private var pictureInPictureController: AVPictureInPictureController?
#endif

    init(request: PlaybackRequest) {
        self.request = request
        self.title = request.title
        super.init()
#if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
#endif
        install(request: request, catchupOffsetMilliseconds: 0)
        startProgressUpdates()
    }

    func play() {
        guard Self.isSupportedURL(request.url) else {
            failureMessage = "AVPlayer 仅支持 HTTP/HTTPS；此源使用 \(request.url.scheme?.uppercased() ?? "未知")."
            status = "播放失败"
            playbackRequested = false
            return
        }
        guard player.currentItem != nil, failureMessage.isEmpty else {
            status = "播放失败"
            playbackRequested = false
            return
        }
        playbackRequested = true
        status = "正在连接…"
        player.playImmediately(atRate: playbackRate)
        refreshProgress()
    }

    func retry() {
        install(request: request, catchupOffsetMilliseconds: catchupOffsetMilliseconds, applyResumePosition: !hasServerCatchupSeek)
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
        install(request: request, catchupOffsetMilliseconds: catchupOffsetMilliseconds, applyResumePosition: applyResumePosition)
        if autoplay { play() } else { status = "已暂停" }
    }

    func togglePlayback() {
        if playbackRequested || isPlaying { pause() } else { play() }
    }

    func pause() {
        playbackRequested = false
        player.pause()
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
        player.seek(to: CMTime(value: Int64(localMilliseconds), timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshProgress() }
        }
        danmakuClock.anchor(to: Double(target), at: ProcessInfo.processInfo.systemUptime, resetRate: true)
        refreshProgress()
    }

    func selectAudioTrack(_ index: Int) {
        guard audioOptions.indices.contains(index), let group = currentGroup(for: .audible) else { return }
        player.currentItem?.select(audioOptions[index], in: group)
        selectedAudioTrackIndex = index
    }

    func selectSubtitleTrack(_ index: Int) {
        guard let group = currentGroup(for: .legible) else { return }
        if index < 0, group.allowsEmptySelection {
            player.currentItem?.select(nil, in: group)
            selectedSubtitleTrackIndex = -1
        } else if subtitleOptions.indices.contains(index) {
            player.currentItem?.select(subtitleOptions[index], in: group)
            selectedSubtitleTrackIndex = index
        }
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player.rate = rate }
        danmakuClock.setPlaybackRate(rate, at: ProcessInfo.processInfo.systemUptime)
    }

    func setAspectRatio(_ ratio: String?, label: String) {
        aspectRatio = ratio
        aspectRatioLabel = label
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playbackRequested = false
        isPlaying = false
        danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
#if os(iOS)
        pictureInPictureController?.stopPictureInPicture()
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        isPictureInPictureReady = false
        isPictureInPictureActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

#if os(iOS)
    func attachPictureInPicture(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        pictureInPictureController = AVPictureInPictureController(playerLayer: layer)
        pictureInPictureController?.delegate = self
        isPictureInPictureReady = pictureInPictureController != nil
    }

    func detachPictureInPicture(from layer: AVPlayerLayer) {
        guard pictureInPictureController?.playerLayer === layer else { return }
        pictureInPictureController?.stopPictureInPicture()
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        isPictureInPictureReady = false
        isPictureInPictureActive = false
    }

    func startPictureInPicture() { pictureInPictureController?.startPictureInPicture() }
#endif

    private var totalDurationMilliseconds: Int {
        if let window = request.catchupWindow { return window.durationMilliseconds }
        if request.durationMilliseconds > 0 { return request.durationMilliseconds }
        let seconds = player.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? max(0, Int(seconds * 1_000)) : 0
    }

    var seekDurationMilliseconds: Int { totalDurationMilliseconds }

    private var currentPlaybackMilliseconds: Int {
        let seconds = player.currentTime().seconds
        return max(0, catchupOffsetMilliseconds + (seconds.isFinite ? Int(seconds * 1_000) : 0))
    }

    private func install(request: PlaybackRequest, catchupOffsetMilliseconds: Int, applyResumePosition: Bool = true) {
        removeObservers()
        player.pause()
        isPlaying = false
        danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
        danmakuClock.resetSampleSynchronization()
        danmakuClock.setPlaybackRate(playbackRate, at: ProcessInfo.processInfo.systemUptime)
        danmakuClock.anchor(to: Double(max(0, catchupOffsetMilliseconds)), at: ProcessInfo.processInfo.systemUptime, resetRate: true)
        playbackGeneration += 1
        self.request = request
        self.catchupOffsetMilliseconds = max(0, catchupOffsetMilliseconds)
        title = request.title
        playbackRequested = false
        isPlaying = false
        didReachEnd = false
        pendingResumePositionMilliseconds = applyResumePosition && !request.isLive
            ? (request.resumeMilliseconds > 0 ? request.resumeMilliseconds : request.skipOpeningMilliseconds)
            : nil
        if pendingResumePositionMilliseconds == 0 { pendingResumePositionMilliseconds = nil }
        audioTracks = []; subtitleTracks = []; audioOptions = []; subtitleOptions = []
        selectedAudioTrackIndex = -1; selectedSubtitleTrackIndex = -1

        let headers = request.headers
        var options: [String: Any] = [:]
        if let userAgent = header("User-Agent", headers: headers) { options[AVURLAssetHTTPUserAgentKey] = userAgent }
        if let cookie = header("Cookie", headers: headers), let host = request.url.host {
            let cookies = cookie.split(separator: ";").compactMap { part -> HTTPCookie? in
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard pair.count == 2 else { return nil }
                return HTTPCookie(properties: [
                    .domain: host,
                    .path: "/",
                    .name: pair[0].trimmingCharacters(in: .whitespaces),
                    .value: pair[1].trimmingCharacters(in: .whitespaces),
                    .secure: request.url.scheme?.lowercased() == "https" ? "TRUE" : "FALSE"
                ])
            }
            options[AVURLAssetHTTPCookiesKey] = cookies
        }
        let unsupportedHeaderNames = headers.keys.filter { !["user-agent", "cookie"].contains($0.lowercased()) }
        guard Self.isSupportedURL(request.url) else {
            failureMessage = "AVPlayer 仅支持 HTTP/HTTPS；此源使用 \(request.url.scheme?.uppercased() ?? "未知")。"
            status = "播放失败"
            player.replaceCurrentItem(with: nil)
            return
        }
        guard unsupportedHeaderNames.isEmpty else {
            failureMessage = "此源需要 \(unsupportedHeaderNames.joined(separator: "、")) 请求头；AVPlayer 不支持可靠地发送这些请求头。"
            status = "播放失败"
            player.replaceCurrentItem(with: nil)
            return
        }
        failureMessage = ""
        status = "正在连接…"
        let item = AVPlayerItem(asset: AVURLAsset(url: request.url, options: options))
        player.replaceCurrentItem(with: item)
        let generation = playbackGeneration
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.playbackGeneration == generation, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.playbackRequested = false
                    self.isPlaying = false
                    self.failureMessage = item.error?.localizedDescription ?? "媒体格式或网络不受支持。"
                    self.status = "播放失败"
                    self.refreshProgress()
                } else if item.status == .readyToPlay {
                    await self.loadTracks(for: item)
                    guard self.playbackGeneration == generation, self.player.currentItem === item else { return }
                    self.refreshProgress()
                }
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak item] player, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.playbackGeneration == generation, self.player.currentItem === item else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.isPlaying = true
                    self.status = "正在播放"
                    self.danmakuClock.setAdvancing(true, at: ProcessInfo.processInfo.systemUptime)
                case .waitingToPlayAtSpecifiedRate:
                    self.isPlaying = false
                    if self.playbackRequested { self.status = "正在缓冲…" }
                    self.danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
                case .paused:
                    self.isPlaying = false
                    self.danmakuClock.setAdvancing(false, at: ProcessInfo.processInfo.systemUptime)
                @unknown default: break
                }
                self.refreshProgress()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.playbackGeneration == generation, self.player.currentItem === item else { return }
                self.playbackRequested = false
                self.isPlaying = false
                self.status = "播放结束"
                self.didReachEnd = true
                self.refreshProgress()
            }
        }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.refreshProgress()
            }
        }
        startProgressUpdates()
    }

    private func removeObservers() {
        itemStatusObservation?.invalidate(); itemStatusObservation = nil
        timeControlObservation?.invalidate(); timeControlObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
    }

    private func startProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshProgress() }
        }
    }

    private func refreshProgress() {
        let current = currentPlaybackMilliseconds
        let total = totalDurationMilliseconds
        currentMilliseconds = current
        elapsedText = Self.clockString(milliseconds: current)
        durationText = total > 0 ? Self.clockString(milliseconds: total) : (request.isLive ? "LIVE" : "--:--")
        progress = total > 0 ? min(1, Double(current) / Double(total)) : 0
        let itemReady = player.currentItem?.status == .readyToPlay
        let hasSeekableTimeRange = player.currentItem?.seekableTimeRanges.contains { value in
            let range = value.timeRangeValue
            return CMTimeCompare(CMTimeRangeGetEnd(range), range.start) > 0
        } ?? false
        let canSeekValue = total > 0 && itemReady && (
            request.catchupWindow?.supportsServerSeeking == true
                || (!request.isLive && hasSeekableTimeRange)
        )
        canSeek = canSeekValue
        canSeekByTime = canSeekValue
        if canSeekValue, let resumePosition = pendingResumePositionMilliseconds {
            pendingResumePositionMilliseconds = nil
            let boundedPosition = min(resumePosition, total)
            seek(to: Double(boundedPosition) / Double(total))
            return
        }
        danmakuClock.reconcile(with: Double(current), at: ProcessInfo.processInfo.systemUptime)
    }

    private func currentGroup(for characteristic: AVMediaCharacteristic) -> AVMediaSelectionGroup? {
        player.currentItem?.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
    }

    private func loadTracks(for item: AVPlayerItem) async {
        do {
            let audioGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
            let subtitleGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
            guard player.currentItem === item else { return }
            audioOptions = audioGroup?.options ?? []
            audioTracks = audioOptions.enumerated().map { AVTrackOption(index: $0.offset, title: $0.element.displayName) }
            selectedAudioTrackIndex = audioGroup.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }.flatMap { audioOptions.firstIndex(of: $0) } ?? -1
            subtitleOptions = subtitleGroup?.options ?? []
            subtitleTracks = [AVTrackOption(index: -1, title: "关闭字幕")] + subtitleOptions.enumerated().map { AVTrackOption(index: $0.offset, title: $0.element.displayName) }
            selectedSubtitleTrackIndex = subtitleGroup.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }.flatMap { subtitleOptions.firstIndex(of: $0) } ?? -1
        } catch {
            guard player.currentItem === item else { return }
            audioTracks = []; subtitleTracks = []; audioOptions = []; subtitleOptions = []
        }
    }

    private func header(_ name: String, headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func isSupportedURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    private static func clockString(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
}

#if os(iOS)
extension AVPlaybackSession: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.isPictureInPictureActive = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in self?.isPictureInPictureActive = false }
    }
}
#endif
