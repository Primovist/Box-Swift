import SwiftUI
import Combine
import VLCKit

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

@MainActor
final class VLCPlaybackSession: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published private(set) var status = "准备连接"
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var elapsedText = "00:00"
    @Published private(set) var durationText = "--:--"
    @Published private(set) var currentMilliseconds = 0
    @Published private(set) var playbackGeneration = 0
    @Published private(set) var canSeek = false
    @Published private(set) var title = ""
    @Published private(set) var audioTracks: [VLCTrackOption] = []
    @Published private(set) var subtitleTracks: [VLCTrackOption] = []
    @Published private(set) var selectedAudioTrackIndex = -1
    @Published private(set) var selectedSubtitleTrackIndex = -1
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var didReachEnd = false
    @Published private(set) var aspectRatioLabel = "比例"

    let player: VLCMediaPlayer
    private(set) var request: PlaybackRequest
    private(set) var positionUpdatedAt = Date()
    private var progressTimer: Timer?
    private var didApplyResumePosition = false
    private var aspectRatio: String?
    private var ignoreNextStoppedEvent = false
    private var observedNearEnd = false

    init(request: PlaybackRequest) {
        self.request = request
        title = request.title
        player = VLCMediaPlayer(options: ["--hw-dec"])
        super.init()
        player.delegate = self
        player.media = makeMedia()
    }

    func play() {
        guard player.media != nil else {
            status = "播放失败"
            return
        }
        status = "正在连接…"
        player.play()
        startProgressUpdates()
    }

    func retry() {
        ignoreNextStoppedEvent = true
        observedNearEnd = false
        player.stop()
        player.media = makeMedia()
        setAspectRatio(aspectRatio, label: aspectRatioLabel)
        progress = 0
        currentMilliseconds = 0
        elapsedText = "00:00"
        didReachEnd = false
        didApplyResumePosition = false
        play()
    }

    func replace(with request: PlaybackRequest) {
        progressTimer?.invalidate()
        progressTimer = nil
        ignoreNextStoppedEvent = true
        observedNearEnd = false
        player.stop()
        self.request = request
        playbackGeneration += 1
        title = request.title
        status = "正在连接…"
        isPlaying = false
        progress = 0
        currentMilliseconds = 0
        elapsedText = "00:00"
        durationText = "--:--"
        canSeek = false
        didReachEnd = false
        audioTracks = []
        subtitleTracks = []
        didApplyResumePosition = false
        player.media = makeMedia()
        setAspectRatio(aspectRatio, label: aspectRatioLabel)
        play()
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
            status = "已暂停"
        } else {
            player.play()
            isPlaying = true
            status = "正在播放"
        }
        refreshProgress()
    }

    func seek(by seconds: Int) {
        guard canSeek else { return }
        let duration = max(0, Int(player.media?.length.intValue ?? 0))
        let target = min(duration, max(0, Int(player.time.intValue) + seconds * 1_000))
        player.time = VLCTime(int: Int32(clamping: target))
        refreshProgress()
    }

    func seek(to fraction: Double) {
        guard canSeek else { return }
        let duration = max(0, Int(player.media?.length.intValue ?? 0))
        let target = Int(Double(duration) * min(1, max(0, fraction)))
        player.time = VLCTime(int: Int32(clamping: target))
        refreshProgress()
    }

    func selectAudioTrack(_ index: Int) {
        let tracks = player.audioTracks as? [VLCMediaPlayerTrack] ?? []
        guard tracks.indices.contains(index) else { return }
        tracks[index].selectedExclusively = true
        selectedAudioTrackIndex = index
    }

    func selectSubtitleTrack(_ index: Int) {
        if index < 0 {
            player.deselectAllTextTracks()
        } else {
            let tracks = player.textTracks as? [VLCMediaPlayerTrack] ?? []
            guard tracks.indices.contains(index) else { return }
            tracks[index].selectedExclusively = true
        }
        selectedSubtitleTrackIndex = index
    }

    func setPlaybackRate(_ rate: Float) {
        refreshProgress()
        player.rate = rate
        playbackRate = rate
        positionUpdatedAt = Date()
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
        progressTimer?.invalidate()
        progressTimer = nil
        ignoreNextStoppedEvent = true
        player.stop()
        player.drawable = nil
    }

    func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            self?.refreshState(newState)
        }
    }

    func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let percentage = progress <= 1 ? progress * 100 : progress
            self.status = String(format: "正在缓冲 %.0f%%", percentage)
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            self?.refreshProgress()
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
            status = "正在播放"
            isPlaying = true
            ignoreNextStoppedEvent = false
            observedNearEnd = false
            refreshTracks()
        case .paused:
            status = "已暂停"
            isPlaying = false
        case .opening:
            status = "正在缓冲…"
        case .stopping:
            status = "正在停止…"
            isPlaying = false
        case .stopped:
            status = "已停止"
            isPlaying = false
            if ignoreNextStoppedEvent {
                ignoreNextStoppedEvent = false
            } else if !request.isLive && isAtEndOrObservedNearEnd {
                status = "播放结束"
                didReachEnd = true
            }
        case .error:
            status = "播放失败"
            isPlaying = false
        default:
            status = "准备连接"
        }
        refreshProgress()
    }

    private func refreshTracks() {
        let audio = player.audioTracks as? [VLCMediaPlayerTrack] ?? []
        audioTracks = audio.enumerated().map { index, track in
            VLCTrackOption(index: index, title: track.trackName)
        }
        selectedAudioTrackIndex = audio.firstIndex(where: \.isSelected) ?? -1

        let subtitles = player.textTracks as? [VLCMediaPlayerTrack] ?? []
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
                let duration = max(0, Int(player.media?.length.intValue ?? 0))
                let position = duration > 0 ? min(target, max(0, duration - 1_000)) : target
                player.time = VLCTime(int: Int32(clamping: position))
            }
        }
        let current = max(0, player.time.intValue)
        positionUpdatedAt = Date()
        let total = max(0, player.media?.length.intValue ?? 0)
        if isPlaying {
            observedNearEnd = !request.isLive && total > 0 && Int(current) >= Int(total) - 1_500
        }
        currentMilliseconds = Int(current)
        elapsedText = Self.clockString(milliseconds: current)
        durationText = total > 0 ? Self.clockString(milliseconds: total) : "LIVE"
        progress = total > 0 ? min(1, Double(current) / Double(total)) : 0
        canSeek = total > 0 && player.isSeekable
    }

    private var isAtEndOrObservedNearEnd: Bool {
        let duration = max(0, Int(player.media?.length.intValue ?? 0))
        let current = max(0, Int(player.time.intValue))
        return duration > 0 && (observedNearEnd || current >= duration - 1_000)
    }

    private static func clockString(milliseconds: Int32) -> String {
        let seconds = max(0, Int(milliseconds / 1_000))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct PlayerScreen: View {
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: VLCPlaybackSession
    @State private var isScrubbing = false
    @State private var seekValue: Double = 0
    @State private var isSwitchingEpisode = false
    @State private var errorMessage: String?
    @State private var playerMenuTitle = ""
    @State private var playerMenuOptions: [PlayerMenuOption] = []
    @State private var showingPlayerMenu = false
    @State private var danmakuComments: [DanmakuComment] = []
    @State private var danmakuGeneration = 0
    @State private var danmakuLoadError: String?
    @State private var danmakuTask: Task<Void, Never>?
    @State private var showingDanmakuSearch = false
    @State private var danmakuSearchPlaybackGeneration: Int?
    @State private var showingDanmakuSettings = false
    @AppStorage("tvbox.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("tvbox.autoNext") private var autoNextEpisode = true
    @AppStorage("tvbox.aspectRatio") private var savedAspectRatio = ""
    private let historySaveTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    #if os(tvOS)
    @FocusState private var playControlFocused: Bool
    @FocusState private var progressFocused: Bool
    #endif

    init(request: PlaybackRequest) {
        _session = StateObject(wrappedValue: VLCPlaybackSession(request: request))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                VLCVideoSurface(player: session.player)
                    .ignoresSafeArea()
                DanmakuOverlay(session: session, comments: danmakuComments, generation: danmakuGeneration)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 22)

                    if session.status == "播放失败" {
                        failureCard
                    }

                    Spacer(minLength: 22)
                    controlPanel(compact: geometry.size.width < 600)
                }
                .padding(.horizontal, playerPadding(compact: geometry.size.width < 600))
                .padding(.top, playerPadding(compact: geometry.size.width < 600))
                .padding(.bottom, playerPadding(compact: geometry.size.width < 600))
            }
            .foregroundStyle(.white)
        }
        .onAppear {
            let option = Self.aspectRatios.first { $0.value == savedAspectRatio }
            session.setAspectRatio(option?.value.isEmpty == false ? option?.value : nil, label: option?.label ?? "比例")
            session.play()
            loadEpisodeDanmaku()
            #if os(tvOS)
            playControlFocused = true
            #endif
        }
        .onDisappear {
            persistPlaybackPosition()
            danmakuTask?.cancel()
            session.stop()
        }
        .onReceive(historySaveTimer) { _ in persistPlaybackPosition() }
        .onChange(of: session.didReachEnd) { reachedEnd in
            guard reachedEnd, autoNextEpisode, !session.request.isLive,
                  session.request.queueIndex + 1 < session.request.queue.count else { return }
            moveToEpisode(1)
        }
        .onChange(of: session.playbackGeneration) { _ in loadEpisodeDanmaku() }
        .alert("无法开始播放", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showingDanmakuSearch) {
            DanmakuSearchView(initialQuery: session.request.item?.title ?? session.title) { comments, _ in
                guard danmakuSearchPlaybackGeneration == session.playbackGeneration else { return }
                danmakuTask?.cancel()
                danmakuGeneration += 1
                danmakuLoadError = nil
                danmakuComments = comments
                danmakuEnabled = true
            }
        }
        .sheet(isPresented: $showingDanmakuSettings) {
            DanmakuSettingsSheet()
        }
        #if os(tvOS)
        .confirmationDialog(playerMenuTitle, isPresented: $showingPlayerMenu, titleVisibility: .visible) {
            ForEach(playerMenuOptions) { option in
                Button(option.title, action: option.action)
            }
        }
        .onExitCommand { dismiss() }
        .onPlayPauseCommand { session.togglePlayback() }
        #endif
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
            }
            .buttonStyle(PlayerControlButtonStyle())
            .accessibilityHint("关闭播放器并返回详情")
            Spacer(minLength: 10)
            Text(session.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(.black.opacity(0.48), in: Capsule())
        }
    }

    private var failureCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
            Text("无法播放此地址")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(session.request.url.absoluteString)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Button("重试") { session.retry() }
                .buttonStyle(PrimaryActionStyle())
        }
        .padding(22)
        .frame(maxWidth: 520)
        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 22))
    }

    private func controlPanel(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 13) {
            HStack(spacing: compact ? 7 : 12) {
                if session.request.queueIndex > 0 {
                    controlButton(title: session.request.isLive ? "上一频道" : "上一集", systemImage: "backward.end.fill") { moveToEpisode(-1) }
                        .disabled(isSwitchingEpisode)
                }
                controlButton(title: "后退 15 秒", systemImage: "gobackward.15") { session.seek(by: -15) }
                    .disabled(!session.canSeek)
                Button { session.togglePlayback() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: compact ? 48 : 52, height: compact ? 48 : 52)
                }
                .buttonStyle(PlayerControlButtonStyle(isAccent: true))
                #if os(tvOS)
                .focused($playControlFocused)
                #endif
                .accessibilityLabel(session.isPlaying ? "暂停" : "播放")
                controlButton(title: "前进 15 秒", systemImage: "goforward.15") { session.seek(by: 15) }
                    .disabled(!session.canSeek)
                if session.request.queueIndex + 1 < session.request.queue.count {
                    controlButton(title: session.request.isLive ? "下一频道" : "下一集", systemImage: "forward.end.fill") { moveToEpisode(1) }
                        .disabled(isSwitchingEpisode)
                }
                Spacer(minLength: compact ? 0 : 12)
                if !compact {
                    Text(isSwitchingEpisode ? "正在切换剧集…" : session.status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }

            HStack(spacing: compact ? 8 : 12) {
                Text(isScrubbing ? Self.clockString(fraction: seekValue, duration: session.durationText) : session.elapsedText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize()
            }

            if compact {
                ScrollView(.horizontal, showsIndicators: false) { playbackOptions }
            } else {
                playbackOptions
            }
            if compact {
                Text(isSwitchingEpisode ? "正在切换剧集…" : session.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, compact ? 13 : 18)
        .padding(.vertical, compact ? 12 : 15)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: compact ? 18 : 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 18 : 22).strokeBorder(.white.opacity(0.09), lineWidth: 1))
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func controlButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(PlayerControlButtonStyle())
        .accessibilityLabel(title)
    }

    private var playbackOptions: some View {
        HStack(spacing: 9) {
            if session.request.availableLines.count > 1 {
                lineMenu
            }
            if !session.audioTracks.isEmpty {
                trackMenu(title: "音轨", systemImage: "waveform", options: session.audioTracks, selectedIndex: session.selectedAudioTrackIndex) {
                    session.selectAudioTrack($0)
                }
            }
            if !session.subtitleTracks.isEmpty {
                trackMenu(title: "字幕", systemImage: "captions.bubble", options: session.subtitleTracks, selectedIndex: session.selectedSubtitleTrackIndex) {
                    session.selectSubtitleTrack($0)
                }
            }
            aspectRatioMenu
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
            .buttonStyle(PlayerControlButtonStyle())
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
            .accessibilityLabel("播放速度")
            #endif
            Spacer(minLength: 0)
        }
    }

    private var playbackRateLabel: some View {
        Label(session.playbackRate == 1 ? "倍速" : Self.rateLabel(Double(session.playbackRate)), systemImage: "speedometer")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white.opacity(0.12), in: Capsule())
            .accessibilityLabel("播放速度")
    }

    private var danmakuMenu: some View {
        #if os(tvOS)
        Button {
            presentPlayerMenu(
                title: "弹幕",
                options: [
                    PlayerMenuOption(id: "search", title: "在线搜索弹幕", action: presentDanmakuSearch),
                    PlayerMenuOption(id: "toggle", title: danmakuEnabled ? "关闭弹幕" : "开启弹幕", action: { danmakuEnabled.toggle() }),
                    PlayerMenuOption(id: "settings", title: "弹幕设置", action: { showingDanmakuSettings = true })
                ]
            )
        } label: {
            danmakuMenuLabel
        }
        .buttonStyle(PlayerControlButtonStyle())
        #else
        Menu {
            Button("在线搜索弹幕", action: presentDanmakuSearch)
            Button(danmakuEnabled ? "关闭弹幕" : "开启弹幕") { danmakuEnabled.toggle() }
            Button("弹幕设置") { showingDanmakuSettings = true }
        } label: {
            danmakuMenuLabel
        }
        .accessibilityLabel("弹幕菜单")
        .accessibilityHint(danmakuLoadError ?? "在线搜索、切换显示或调整弹幕")
        #endif
    }

    private var danmakuMenuLabel: some View {
        trackMenuLabel(
            title: danmakuLoadError == nil ? (danmakuEnabled ? "弹幕" : "弹幕关") : "弹幕错误",
            systemImage: "captions.bubble"
        )
    }

    private func presentDanmakuSearch() {
        danmakuSearchPlaybackGeneration = session.playbackGeneration
        showingDanmakuSearch = true
    }

    private func loadEpisodeDanmaku() {
        danmakuTask?.cancel()
        danmakuGeneration += 1
        danmakuComments = []
        danmakuLoadError = nil
        guard let source = session.request.danmakuSource,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = danmakuGeneration
        let headers = session.request.headers
        danmakuTask = Task { @MainActor in
            do {
                let comments = try await DanmakuService().comments(from: source, headers: headers)
                guard !Task.isCancelled, generation == danmakuGeneration else { return }
                danmakuComments = comments
                danmakuGeneration += 1
            } catch {
                guard !Task.isCancelled, generation == danmakuGeneration else { return }
                danmakuLoadError = error.localizedDescription
            }
        }
    }

    private static let aspectRatios = [
        AspectRatioOption(label: "默认", value: ""),
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
        .buttonStyle(PlayerControlButtonStyle())
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
        .accessibilityLabel("画面比例")
        #endif
    }

    private func selectAspectRatio(_ option: AspectRatioOption) {
        savedAspectRatio = option.value
        session.setAspectRatio(option.value.isEmpty ? nil : option.value, label: option.label)
    }

    private func presentPlayerMenu(title: String, options: [PlayerMenuOption]) {
        playerMenuTitle = title
        playerMenuOptions = options
        showingPlayerMenu = true
    }

    #if os(tvOS)
    private var tvProgressControl: some View {
        Button {} label: {
            GeometryReader { geometry in
                let fraction = min(1, max(0, session.progress))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 6)
                    Capsule().fill(Color.tvboxAccent).frame(width: geometry.size.width * CGFloat(fraction), height: 6)
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, geometry.size.width * CGFloat(fraction) - 6))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .padding(.horizontal, 6)
            .background(progressFocused ? .white.opacity(0.12) : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(progressFocused ? .white.opacity(0.85) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .focused($progressFocused)
        .disabled(!session.canSeek)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(session.elapsedText) / \(session.durationText)")
        .onMoveCommand { direction in
            switch direction {
            case .left: session.seek(by: -15)
            case .right: session.seek(by: 15)
            default: break
            }
        }
    }
    #endif

    private func trackMenu(
        title: String,
        systemImage: String,
        options: [VLCTrackOption],
        selectedIndex: Int,
        select: @escaping (Int) -> Void
    ) -> some View {
        #if os(tvOS)
        Button {
            presentPlayerMenu(
                title: title,
                options: options.map { option in
                    PlayerMenuOption(
                        id: String(option.index),
                        title: option.index == selectedIndex ? "✓  \(option.title)" : option.title,
                        action: { select(option.index) }
                    )
                }
            )
        } label: {
            trackMenuLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(PlayerControlButtonStyle())
        #else
        Menu {
            ForEach(options) { option in
                Button {
                    select(option.index)
                } label: {
                    if option.index == selectedIndex {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            trackMenuLabel(title: title, systemImage: systemImage)
        }
        .accessibilityLabel(title)
        #endif
    }

    private func trackMenuLabel(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white.opacity(0.12), in: Capsule())
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
        .buttonStyle(PlayerControlButtonStyle())
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
        Task {
            do {
                let next = try await catalog.playbackRequest(
                    for: item,
                    episode: episode,
                    queue: line.episodes,
                    queueIndex: nextIndex
                )
                session.replace(with: next)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSwitchingEpisode = false
        }
    }

    private func moveToEpisode(_ offset: Int) {
        let current = session.request
        let targetIndex = current.queueIndex + offset
        guard current.queue.indices.contains(targetIndex) else { return }
        let episode = current.queue[targetIndex]
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
        guard let item = current.item else { return }
        isSwitchingEpisode = true
        persistPlaybackPosition()
        Task {
            do {
                let next = try await catalog.playbackRequest(
                    for: item,
                    episode: episode,
                    queue: current.queue,
                    queueIndex: targetIndex
                )
                session.replace(with: next)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSwitchingEpisode = false
        }
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
        return 54
        #else
        return compact ? 15 : 24
        #endif
    }

    private static func clockString(fraction: Double, duration: String) -> String {
        let parts = duration.split(separator: ":").compactMap { Int($0) }
        guard duration != "LIVE", !parts.isEmpty else { return "00:00" }
        let total = parts.reduce(0) { $0 * 60 + $1 }
        let seconds = Int(Double(total) * min(1, max(0, fraction)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func rateLabel(_ rate: Double) -> String {
        String(format: "%.2g×", rate)
    }
}

private struct PlayerControlButtonStyle: ButtonStyle {
    var isAccent = false
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background((isAccent || isFocused ? Color.tvboxAccent : Color.white.opacity(0.14)), in: Capsule())
            .overlay(Capsule().strokeBorder(isFocused ? .white.opacity(0.85) : .clear, lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.94 : (isFocused ? 1.06 : 1))
            .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}
