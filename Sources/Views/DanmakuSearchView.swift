import SwiftUI

struct DanmakuSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tvbox.danmakuAPIURL") private var apiAddress = ""
    @State private var query = ""
    @State private var animeResults: [DanmakuAnime] = []
    @State private var episodeResults: [DanmakuEpisode] = []
    @State private var selectedAnime: DanmakuAnime?
    @State private var isLoading = false
    @State private var message: String?
    @State private var requestGeneration = 0

    let initialQuery: String
    let onLoad: ([DanmakuComment], String) -> Void
    private let service = DanmakuService()

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                VStack(alignment: .leading, spacing: 16) {
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
                                    resultButton(title: anime.title, subtitle: "选择作品", icon: "film") {
                                        Task { await loadEpisodes(for: anime) }
                                    }
                                }
                            } else {
                                ForEach(episodeResults) { episode in
                                    resultButton(title: episode.title, subtitle: selectedAnime?.title ?? "", icon: "play.rectangle") {
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
        TextField("输入影片名称", text: $query)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit { Task { await search() } }
        #else
        TextField("输入影片名称", text: $query)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .onSubmit { Task { await search() } }
        #endif
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
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.tvboxMuted).lineLimit(1)
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
            message = results.isEmpty ? "此作品没有可选集数。" : "选择要加载弹幕的集数。"
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
        message = "正在下载《\(episode.title)》的弹幕…"
        do {
            let comments = try await service.comments(for: episode, apiAddress: apiAddress)
            guard generation == requestGeneration else { return }
            onLoad(comments, episode.title)
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
