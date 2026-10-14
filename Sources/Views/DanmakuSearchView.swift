import SwiftUI

private struct DanmakuFieldFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct DanmakuSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool
    @AppStorage("tvbox.danmakuAPIURL") private var apiAddress = ""
    @State private var query = ""
    @State private var animeResults: [DanmakuAnime] = []
    @State private var episodeResults: [DanmakuEpisode] = []
    @State private var selectedAnime: DanmakuAnime?
    @State private var suggestedEpisodeIDs: Set<String> = []
    @State private var autoMatchedTitle: String?
    @State private var isLoading = false
    @State private var message: String?
    @State private var requestGeneration = 0
    #if os(tvOS)
    @FocusState private var focusedResultID: String?
    @State private var pendingResultFocusID: String?
    @State private var resultFocusRequestVersion = 0
    #endif

    let initialQuery: String
    var mediaTitle: String = ""
    var mediaCategory: String = ""
    var mediaYear: String = ""
    var currentEpisodeTitle: String = ""
    var expectsEpisodeMatch = false
    let onLoad: ([DanmakuComment], String) -> Void
    private let service = DanmakuService()

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                #if os(tvOS)
                let compact = false
                #else
                let compact = geometry.size.height < 520
                #endif
                ZStack {
                    ScreenBackground()
                    resultsList(compact: compact, availableSize: geometry.size)
                    #if os(iOS)
                    .simultaneousGesture(TapGesture().onEnded { isSearchFocused = false })
                    #endif
                }
            }
            .navigationTitle("在线搜索弹幕")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "搜索剧名或影片名")
            #if os(iOS)
            .searchFocused($isSearchFocused)
            #endif
            .onSubmit(of: .search) {
                Task { await search() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                if query.isEmpty { query = initialQuery }
                guard !apiAddress.isEmpty else { return }
                if shouldAutoMatchEpisode {
                    await autoMatchCurrentEpisode()
                } else {
                    await search()
                }
            }
            .onDisappear { requestGeneration += 1 }
        }
    }

    private func resultsList(compact: Bool, availableSize: CGSize) -> some View {
        let horizontalPadding = compact ? 16 : searchHorizontalPadding
        let availableContentWidth = max(0, availableSize.width)
        let contentWidth = min(searchContentMaxWidth, availableContentWidth)
        let resultWidth = min(resultsMaxWidth, contentWidth)

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 8 : 16) {
                    if !mediaTitle.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("当前播放")
                                .font(contextLabelFont)
                                .foregroundStyle(Color.tvboxCyan)
                            Text(playbackContext)
                                .font(contextValueFont)
                                .foregroundStyle(Color.tvboxMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if apiAddress.isEmpty {
                        statusBanner("未配置弹幕源。请先在设置中填写 DandanPlay 兼容的 danmu_api 地址。")
                    } else if let message {
                        statusBanner(message, isLoading: isLoading)
                    } else if animeResults.isEmpty, selectedAnime == nil, autoMatchedTitle == nil {
                        statusBanner("输入作品名，搜索可用弹幕作品。")
                    }

                    LazyVStack(spacing: resultFocusSpacing) {
                        if autoMatchedTitle != nil {
                            resultActionButton(
                                title: "不满意？手动搜索其他作品或集数",
                                icon: "magnifyingglass",
                                focusID: "manualSearch",
                                isDisabled: isLoading
                            ) {
                                Task { await search() }
                            }
                        }

                        if let selectedAnime {
                            resultActionButton(
                                title: "返回作品列表 · \(selectedAnime.title)",
                                icon: "chevron.left",
                                focusID: "backToResults"
                            ) {
                                returnToAnimeResults()
                            }
                        }

                        if selectedAnime == nil {
                            ForEach(animeResults) { anime in
                                resultButton(
                                    title: anime.title,
                                    subtitle: animeSubtitle(anime),
                                    icon: "film",
                                    focusID: "anime:\(anime.id)"
                                ) {
                                    Task { await loadEpisodes(for: anime) }
                                }
                            }
                        } else {
                            ForEach(orderedEpisodeResults) { episode in
                                let suggested = suggestedEpisodeIDs.contains(episode.id)
                                resultButton(
                                    title: episode.title,
                                    subtitle: suggested ? "与当前第 \(currentEpisodeNumber ?? 0) 集相符 · 点击确认" : "选择此集加载弹幕",
                                    icon: suggested ? "checkmark.circle.fill" : "play.rectangle",
                                    focusID: "episode:\(episode.id)"
                                ) {
                                    Task { await loadComments(for: episode) }
                                }
                            }
                        }
                    }
                    .padding(.vertical, resultFocusPadding)
                    .frame(maxWidth: resultWidth)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, compact ? 10 : 22)
                .frame(maxWidth: contentWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            #if os(tvOS)
            .onChange(of: resultFocusRequestVersion) { _, version in
                guard let focusID = pendingResultFocusID else { return }
                proxy.scrollTo(focusID, anchor: .center)
                Task { @MainActor in
                    await Task.yield()
                    guard resultFocusRequestVersion == version else { return }
                    focusedResultID = focusID
                }
            }
            #endif
        }
    }

    private var contextLabelFont: Font {
        #if os(tvOS)
        .system(size: TVBoxTypography.readable(14, minimum: 23), weight: .semibold, design: .rounded)
        #else
        .caption.weight(.semibold)
        #endif
    }

    private var contextValueFont: Font {
        #if os(tvOS)
        .system(size: TVBoxTypography.readable(12, minimum: 23), weight: .medium)
        #else
        .subheadline
        #endif
    }

    private var statusFont: Font {
        #if os(tvOS)
        .system(size: TVBoxTypography.readable(12, minimum: 23), weight: .medium)
        #else
        .subheadline
        #endif
    }

    private var resultTitleFont: Font {
        #if os(tvOS)
        .system(size: TVBoxTypography.readable(14), weight: .semibold)
        #else
        .headline
        #endif
    }

    private var resultSubtitleFont: Font {
        #if os(tvOS)
        .system(size: TVBoxTypography.readable(11, minimum: 23))
        #else
        .subheadline
        #endif
    }

    private var searchActionFont: Font {
        #if os(tvOS)
        .system(size: TVBoxTypography.readable(16, minimum: 24), weight: .semibold)
        #else
        .body.weight(.medium)
        #endif
    }

    private var searchContentMaxWidth: CGFloat {
        #if os(tvOS)
        1_800
        #else
        920
        #endif
    }

    private var resultsMaxWidth: CGFloat {
        #if os(tvOS)
        1_680
        #else
        880
        #endif
    }

    private var searchHorizontalPadding: CGFloat {
        #if os(tvOS)
        64
        #else
        22
        #endif
    }

    private var resultFocusPadding: CGFloat {
        #if os(tvOS)
        24
        #else
        8
        #endif
    }

    private var resultRowMinimumHeight: CGFloat {
        #if os(tvOS)
        120
        #else
        72
        #endif
    }

    private var actionRowMinimumHeight: CGFloat {
        #if os(tvOS)
        88
        #else
        54
        #endif
    }

    private var resultFocusSpacing: CGFloat {
        #if os(tvOS)
        18
        #else
        10
        #endif
    }

    private func statusBanner(_ text: String, isLoading: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.tvboxAccent)
            } else {
                Image(systemName: "info.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.tvboxAccent)
            }
            Text(text)
                .font(statusFont)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var playbackContext: String {
        [mediaTitle, mediaCategory, mediaYear, currentEpisodeTitle]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var currentEpisodeNumber: Int? {
        DanmakuService.episodeNumber(in: currentEpisodeTitle)
    }

    private var shouldAutoMatchEpisode: Bool {
        expectsEpisodeMatch || ["电视剧", "连续剧", "剧集", "番剧", "动漫", "动画", "series", "tv"]
            .contains { mediaCategory.lowercased().contains($0) }
    }

    private var orderedEpisodeResults: [DanmakuEpisode] {
        guard let currentEpisodeNumber else { return episodeResults }
        let suggested = episodeResults.filter {
            DanmakuService.episodeNumber(in: $0.title) == currentEpisodeNumber
        }
        let remaining = episodeResults.filter {
            DanmakuService.episodeNumber(in: $0.title) != currentEpisodeNumber
        }
        return suggested + remaining
    }

    private func animeSubtitle(_ anime: DanmakuAnime) -> String {
        var details = [anime.typeDescription, anime.startYear]
        if let episodeCount = anime.episodeCount, episodeCount > 0 {
            details.append("\(episodeCount) 集")
        }
        details = details.filter { !$0.isEmpty }
        if let mismatch = typeMismatchLabel(for: anime) { details.append(mismatch) }
        return details.isEmpty ? "选择作品后再确认集数" : details.joined(separator: " · ")
    }

    private func typeMismatchLabel(for anime: DanmakuAnime) -> String? {
        let category = mediaCategory.lowercased()
        let currentIsMovie = ["电影", "movie", "film"].contains { category.contains($0) }
        let currentIsSeries = expectsEpisodeMatch || ["电视剧", "连续剧", "剧集", "番剧", "动漫", "动画", "series", "tv"]
            .contains { category.contains($0) }
        let type = anime.typeDescription.lowercased()
        let resultIsMovie = ["电影", "剧场版", "movie", "film"].contains { type.contains($0) }
        let resultIsSeries = ["电视剧", "连续剧", "剧集", "番剧", "动漫", "动画", "series", "tv"]
            .contains { type.contains($0) }
        if currentIsMovie && resultIsSeries { return "类型与当前条目不符" }
        if currentIsSeries && resultIsMovie { return "类型与当前条目不符" }
        return nil
    }

    private func resultButton(
        title: String,
        subtitle: String,
        icon: String,
        focusID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: TVBoxTypography.readable(16, minimum: 24), weight: .semibold))
                    .foregroundStyle(Color.tvboxCyan)
                    .frame(width: TVBoxTypography.readable(38, minimum: 60), height: TVBoxTypography.readable(38, minimum: 60))
                    .background(Color.tvboxCyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(resultTitleFont)
                        .foregroundStyle(Color.primary)
                        #if os(tvOS)
                        .lineLimit(2)
                        #else
                        .fixedSize(horizontal: false, vertical: true)
                        #endif
                    Text(subtitle)
                        .font(resultSubtitleFont)
                        .foregroundStyle(Color.tvboxMuted)
                        #if os(tvOS)
                        .lineLimit(2)
                        #else
                        .fixedSize(horizontal: false, vertical: true)
                        #endif
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: TVBoxTypography.readable(10, minimum: 20), weight: .bold)).foregroundStyle(Color.tvboxMuted)
            }
            .padding(TVBoxTypography.readable(12, minimum: 20))
            .frame(minHeight: resultRowMinimumHeight)
            .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 15))
        }
        .platformFocusableButtonStyle()
        #if os(tvOS)
        .focused($focusedResultID, equals: focusID)
        #endif
        .disabled(isLoading)
        .id(focusID)
    }

    private func resultActionButton(
        title: String,
        icon: String,
        focusID: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(searchActionFont)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: actionRowMinimumHeight, alignment: .leading)
                .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .platformFocusableButtonStyle()
        #if os(tvOS)
        .focused($focusedResultID, equals: focusID)
        #endif
        .disabled(isDisabled)
        .id(focusID)
    }

    @MainActor
    private func search() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !apiAddress.isEmpty else { return }
        let generation = nextGeneration()
        #if os(iOS)
        isSearchFocused = false
        #endif
        #if os(tvOS)
        focusedResultID = nil
        #endif
        isLoading = true
        message = "正在搜索作品…"
        autoMatchedTitle = nil
        selectedAnime = nil
        animeResults = []
        episodeResults = []
        suggestedEpisodeIDs = []
        do {
            let results = try await service.searchAnime(keyword: keyword, apiAddress: apiAddress)
            guard generation == requestGeneration else { return }
            animeResults = results
            message = results.isEmpty ? "没有找到匹配作品。" : "找到 \(results.count) 个作品，选择作品后再选集。"
            requestResultFocus(results.first.map { "anime:\($0.id)" })
        } catch {
            guard generation == requestGeneration else { return }
            animeResults = []
            message = error.localizedDescription
        }
        if generation == requestGeneration { isLoading = false }
    }

    @MainActor
    private func autoMatchCurrentEpisode() async {
        let generation = nextGeneration()
        isLoading = true
        message = currentEpisodeNumber.map { "正在自动匹配第 \($0) 集弹幕…" } ?? "正在自动匹配当前集弹幕…"
        do {
            let match = try await service.automaticMatch(
                title: initialQuery,
                category: mediaCategory,
                year: mediaYear,
                episodeTitle: currentEpisodeTitle,
                isSeries: shouldAutoMatchEpisode,
                apiAddress: apiAddress
            )
            guard generation == requestGeneration else { return }
            autoMatchedTitle = match.matchTitle
            message = "已自动匹配并加载：\(match.matchTitle)"
            onLoad(match.comments, match.matchTitle)
            requestResultFocus("manualSearch")
        } catch {
            guard generation == requestGeneration else { return }
            autoMatchedTitle = nil
            await search()
        }
        if generation == requestGeneration { isLoading = false }
    }

    @MainActor
    private func loadEpisodes(for anime: DanmakuAnime) async {
        let generation = nextGeneration()
        selectedAnime = anime
        episodeResults = []
        suggestedEpisodeIDs = []
        isLoading = true
        message = "正在读取《\(anime.title)》的集数…"
        requestResultFocus("backToResults")
        do {
            let results = try await service.episodes(for: anime, apiAddress: apiAddress)
            guard generation == requestGeneration else { return }
            episodeResults = results
            if let currentEpisodeNumber {
                suggestedEpisodeIDs = Set(results.filter {
                    DanmakuService.episodeNumber(in: $0.title) == currentEpisodeNumber
                }.map(\.id))
                message = results.isEmpty
                    ? "此作品没有可选集数。"
                    : (suggestedEpisodeIDs.isEmpty
                        ? "当前播放为第 \(currentEpisodeNumber) 集，但作品列表没有同集数候选；请手动确认。"
                        : "已将第 \(currentEpisodeNumber) 集候选置顶。加载前请核对作品和集数。")
            } else {
                suggestedEpisodeIDs = []
                message = results.isEmpty ? "此作品没有可选集数。" : "请核对作品信息后，选择对应集数。"
            }
            let recommendedEpisode = orderedEpisodeResults.first?.id
            requestResultFocus(recommendedEpisode.map { "episode:\($0)" } ?? "backToResults")
        } catch {
            guard generation == requestGeneration else { return }
            message = error.localizedDescription
            requestResultFocus("backToResults")
        }
        if generation == requestGeneration { isLoading = false }
    }

    @MainActor
    private func loadComments(for episode: DanmakuEpisode) async {
        let generation = nextGeneration()
        isLoading = true
        let animeTitle = selectedAnime?.title ?? "已选作品"
        let matchTitle = "\(animeTitle) · \(episode.title)"
        message = "正在下载《\(animeTitle)》\(episode.title)的弹幕…"
        do {
            let comments = try await service.comments(for: episode, apiAddress: apiAddress)
            guard generation == requestGeneration else { return }
            onLoad(comments, matchTitle)
            dismiss()
        } catch {
            guard generation == requestGeneration else { return }
            message = error.localizedDescription
            requestResultFocus("episode:\(episode.id)")
        }
        if generation == requestGeneration { isLoading = false }
    }

    @MainActor
    private func returnToAnimeResults() {
        let previousAnimeFocusID = selectedAnime.map { "anime:\($0.id)" }
        requestGeneration += 1
        isLoading = false
        selectedAnime = nil
        episodeResults = []
        suggestedEpisodeIDs = []
        message = animeResults.isEmpty ? nil : "选择作品后，再选择对应集数。"
        requestResultFocus(previousAnimeFocusID ?? animeResults.first.map { "anime:\($0.id)" })
    }

    @MainActor
    private func requestResultFocus(_ id: String?) {
        #if os(tvOS)
        guard let id else { return }
        pendingResultFocusID = id
        resultFocusRequestVersion += 1
        #endif
    }

    @MainActor
    private func nextGeneration() -> Int {
        requestGeneration += 1
        return requestGeneration
    }
}

struct DanmakuPreferencesForm: View {
    @FocusState private var isAddressFocused: Bool
    @AppStorage("tvbox.danmakuAPIURL") private var apiAddress = ""
    @AppStorage("tvbox.danmakuEnabled") private var isEnabled = true
    @AppStorage("tvbox.danmakuOpacity") private var opacity = 0.9
    @AppStorage("tvbox.danmakuSpeed") private var speed = 1.5
    @AppStorage("tvbox.danmakuSize") private var sizeScale = 0.8
    @AppStorage("tvbox.danmakuLines") private var maxLines = 3
    @AppStorage("tvbox.danmakuRandomColor") private var randomColor = false
    @State private var addressFieldFrame = CGRect.zero

    var body: some View {
        Form {
            Section("弹幕源") {
                urlField("DandanPlay 兼容的 danmu_api 地址", text: $apiAddress)
                Text("填写服务根地址；支持服务端将 Token 放在 URL 路径中。搜索作品后选择集数加载 XML 弹幕。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("显示") {
                Toggle("显示弹幕", isOn: $isEnabled)
                Toggle("随机弹幕颜色", isOn: $randomColor)
            }

            Section("弹幕外观") {
                sliderRow(title: "弹幕透明度", value: $opacity, range: 0.1...1, suffix: "%", percent: true)
                sliderRow(title: "弹幕速度", value: $speed, range: 0.5...2.4, suffix: "×")
                sliderRow(title: "弹幕字号", value: $sizeScale, range: 0.6...2.0, suffix: "×")
                sliderRow(title: "最大行数", value: Binding(
                    get: { Double(maxLines) },
                    set: { maxLines = Int($0.rounded()) }
                ), range: 1...15, suffix: " 行", integer: true)
            }
        }
        #if os(iOS)
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .global)
                .onEnded { tap in
                    guard !addressFieldFrame.contains(tap.location) else { return }
                    isAddressFocused = false
                }
        )
        .onPreferenceChange(DanmakuFieldFrameKey.self) { addressFieldFrame = $0 }
        .scrollDismissesKeyboard(.interactively)
        #endif
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func urlField(_ title: String, text: Binding<String>) -> some View {
        #if os(iOS)
        TextField(title, text: text)
            .focused($isAddressFocused)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: DanmakuFieldFrameKey.self, value: proxy.frame(in: .global))
                }
            }
        #else
        TextField(title, text: text)
            .focused($isAddressFocused)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
        #endif
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String, percent: Bool = false, integer: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(displayValue(value.wrappedValue, suffix: suffix, percent: percent, integer: integer))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            #if os(tvOS)
            HStack {
                Button {
                    adjust(value, by: -(integer ? 1 : 0.1), in: range, integer: integer)
                } label: {
                    Label("减少\(title)", systemImage: "minus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("减少\(title)")
                .disabled(value.wrappedValue <= range.lowerBound)

                Spacer()

                Button {
                    adjust(value, by: integer ? 1 : 0.1, in: range, integer: integer)
                } label: {
                    Label("增加\(title)", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("增加\(title)")
                .disabled(value.wrappedValue >= range.upperBound)
            }
            #else
            Slider(value: value, in: range, step: integer ? 1 : 0.1)
            #endif
        }
    }

    private func adjust(_ value: Binding<Double>, by amount: Double, in range: ClosedRange<Double>, integer: Bool) {
        let next = min(range.upperBound, max(range.lowerBound, value.wrappedValue + amount))
        value.wrappedValue = integer ? next.rounded() : (next * 10).rounded() / 10
    }

    private func displayValue(_ value: Double, suffix: String, percent: Bool, integer: Bool) -> String {
        if percent { return "\(Int((value * 100).rounded()))\(suffix)" }
        if integer { return "\(Int(value.rounded()))\(suffix)" }
        return String(format: "%.1f", value) + suffix
    }
}

struct DanmakuSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DanmakuPreferencesForm()
            .navigationTitle("弹幕设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
