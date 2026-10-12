import SwiftUI

struct DanmakuSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tvbox.danmakuAPIURL") private var apiAddress = ""
    @State private var query = ""
    @State private var animeResults: [DanmakuAnime] = []
    @State private var episodeResults: [DanmakuEpisode] = []
    @State private var selectedAnime: DanmakuAnime?
    @State private var suggestedEpisodeIDs: Set<String> = []
    @State private var isLoading = false
    @State private var message: String?
    @State private var requestGeneration = 0

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
            ZStack {
                ScreenBackground()
                VStack(alignment: .leading, spacing: 16) {
                    if !mediaTitle.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("当前播放")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tvboxCyan)
                            Text(playbackContext)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.tvboxMuted)
                                .lineLimit(2)
                        }
                    }
                    HStack(spacing: 10) {
                        searchField
                        Button {
                            Task { await search() }
                        } label: {
                            Label("搜索", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(PrimaryActionStyle())
                        .disabled(isLoading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiAddress.isEmpty)
                    }

                    if apiAddress.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "captions.bubble")
                                .font(.system(size: 28))
                                .foregroundStyle(Color.tvboxCyan)
                            Text("未配置弹幕源")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("请先在设置中填写 DandanPlay 兼容的 danmu_api 地址。")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.tvboxMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 140)
                    } else if isLoading {
                        ProgressView(message ?? "正在搜索…")
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 140)
                    } else if let message {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.tvboxMuted)
                            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                    }

                    ScrollView {
                        LazyVStack(spacing: 9) {
                            if let selectedAnime {
                                Button {
                                    self.selectedAnime = nil
                                    episodeResults = []
                                    message = animeResults.isEmpty ? nil : "选择作品后，再选择对应集数。"
                                } label: {
                                    Label("返回作品列表 · \(selectedAnime.title)", systemImage: "chevron.left")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(FocusAwareButtonStyle())
                            }

                            if selectedAnime == nil {
                                ForEach(animeResults) { anime in
                                    resultButton(title: anime.title, subtitle: animeSubtitle(anime), icon: "film") {
                                        Task { await loadEpisodes(for: anime) }
                                    }
                                }
                            } else {
                                if let selectedAnime {
                                    Text("已选择：\(selectedAnime.title) · \(animeSubtitle(selectedAnime))")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.tvboxCyan)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(2)
                                }
                                ForEach(orderedEpisodeResults) { episode in
                                    let suggested = suggestedEpisodeIDs.contains(episode.id)
                                    resultButton(
                                        title: episode.title,
                                        subtitle: suggested ? "与当前第 \(currentEpisodeNumber ?? 0) 集相符 · 点击确认" : "选择此集加载弹幕",
                                        icon: suggested ? "checkmark.circle.fill" : "play.rectangle"
                                    ) {
                                        Task { await loadComments(for: episode) }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationTitle("在线搜索弹幕")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                if query.isEmpty { query = initialQuery }
                if !apiAddress.isEmpty { await search() }
            }
            .onDisappear { requestGeneration += 1 }
        }
    }

    @ViewBuilder
    private var searchField: some View {
        #if os(iOS)
        TextField("搜索剧名或影片名", text: $query)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit { Task { await search() } }
        #else
        TextField("搜索剧名或影片名", text: $query)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .onSubmit { Task { await search() } }
        #endif
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

    private func resultButton(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.tvboxCyan)
                    .frame(width: 38, height: 38)
                    .background(Color.tvboxCyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.tvboxMuted).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.tvboxMuted)
            }
            .padding(12)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(FocusAwareButtonStyle())
    }

    @MainActor
    private func search() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !apiAddress.isEmpty else { return }
        let generation = nextGeneration()
        isLoading = true
        message = "正在搜索作品…"
        selectedAnime = nil
        episodeResults = []
        suggestedEpisodeIDs = []
        do {
            let results = try await service.searchAnime(keyword: keyword, apiAddress: apiAddress)
            guard generation == requestGeneration else { return }
            animeResults = results
            message = results.isEmpty ? "没有找到匹配作品。" : "找到 \(results.count) 个作品，选择作品后再选集。"
        } catch {
            guard generation == requestGeneration else { return }
            animeResults = []
            message = error.localizedDescription
        }
        if generation == requestGeneration { isLoading = false }
    }

    @MainActor
    private func loadEpisodes(for anime: DanmakuAnime) async {
        let generation = nextGeneration()
        isLoading = true
        message = "正在读取《\(anime.title)》的集数…"
        do {
            let results = try await service.episodes(for: anime, apiAddress: apiAddress)
            guard generation == requestGeneration else { return }
            selectedAnime = anime
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
        } catch {
            guard generation == requestGeneration else { return }
            message = error.localizedDescription
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
        }
        if generation == requestGeneration { isLoading = false }
    }

    @MainActor
    private func nextGeneration() -> Int {
        requestGeneration += 1
        return requestGeneration
    }
}

struct DanmakuPreferencesForm: View {
    @AppStorage("tvbox.danmakuAPIURL") private var apiAddress = ""
    @AppStorage("tvbox.danmakuEnabled") private var isEnabled = true
    @AppStorage("tvbox.danmakuOpacity") private var opacity = 0.9
    @AppStorage("tvbox.danmakuSpeed") private var speed = 1.5
    @AppStorage("tvbox.danmakuSize") private var sizeScale = 0.8
    @AppStorage("tvbox.danmakuLines") private var maxLines = 3
    @AppStorage("tvbox.danmakuRandomColor") private var randomColor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("弹幕源", systemImage: "server.rack")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            urlField("DandanPlay 兼容的 danmu_api 地址", text: $apiAddress)
            Text("填写服务根地址；支持服务端将 Token 放在 URL 路径中。搜索作品后选择集数加载 XML 弹幕。")
                .font(.system(size: 11))
                .foregroundStyle(Color.tvboxMuted)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(.white.opacity(0.12))
            Toggle("显示弹幕", isOn: $isEnabled).tint(Color.tvboxAccent)
            Toggle("随机弹幕颜色", isOn: $randomColor).tint(Color.tvboxAccent)
            sliderRow(title: "弹幕透明度", value: $opacity, range: 0.1...1, suffix: "%", percent: true)
            sliderRow(title: "弹幕速度", value: $speed, range: 0.5...2.4, suffix: "×")
            sliderRow(title: "弹幕字号", value: $sizeScale, range: 0.6...2.0, suffix: "×")
            sliderRow(title: "最大行数", value: Binding(
                get: { Double(maxLines) },
                set: { maxLines = Int($0.rounded()) }
            ), range: 1...15, suffix: " 行", integer: true)
        }
    }

    @ViewBuilder
    private func urlField(_ title: String, text: Binding<String>) -> some View {
        #if os(iOS)
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        #else
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
        #endif
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String, percent: Bool = false, integer: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Text(displayValue(value.wrappedValue, suffix: suffix, percent: percent, integer: integer))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.tvboxMuted)
            }
            #if os(tvOS)
            HStack(spacing: 14) {
                Button {
                    adjust(value, by: -(integer ? 1 : 0.1), in: range, integer: integer)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(Color.tvboxCyan)
                }
                .buttonStyle(FocusAwareButtonStyle())
                .accessibilityLabel("减少\(title)")
                .disabled(value.wrappedValue <= range.lowerBound)

                Button {
                    adjust(value, by: integer ? 1 : 0.1, in: range, integer: integer)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 25))
                        .foregroundStyle(Color.tvboxCyan)
                }
                .buttonStyle(FocusAwareButtonStyle())
                .accessibilityLabel("增加\(title)")
                .disabled(value.wrappedValue >= range.upperBound)
                Spacer(minLength: 0)
            }
            #else
            Slider(value: value, in: range, step: integer ? 1 : 0.1).tint(Color.tvboxAccent)
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
            ZStack {
                ScreenBackground()
                ScrollView {
                    DanmakuPreferencesForm()
                        .padding(22)
                        .frame(maxWidth: 800, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
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
