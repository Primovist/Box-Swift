import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @State private var detail: MediaItem?
    @State private var selectedLineID = ""
    @State private var preferredEpisodeID: String?
    @State private var playbackRequest: PlaybackRequest?
    @State private var isResolving = false
    @State private var errorMessage: String?
    @State private var isShowingFullDetails = false
    #if os(tvOS)
    @FocusState private var focusedEpisodeID: String?
    @State private var pendingEpisodeFocusID: String?
    #endif

    let item: MediaItem

    private var media: MediaItem { detail ?? item }
    private var selectedLine: PlaybackLine? { media.lines.first { $0.id == selectedLineID } ?? media.lines.first }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= geometry.size.height
            ZStack {
                ScreenBackground()
                if wide {
                    landscapeLayout(size: geometry.size)
                } else {
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            if catalog.alternateSources(for: media).count > 1 { sourcePicker }
                            if supportedParsers.count > 1 { parserPicker }
                            portraitOverview
                        }
                        .frame(maxWidth: 1350, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .frame(maxWidth: .infinity, alignment: .top)

                        Rectangle()
                            .fill(Color.primary.opacity(0.10))
                            .frame(height: 1)

                        playlist
                            .frame(maxWidth: 1350, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .task(id: item.id) {
            let loaded = await catalog.detail(for: item)
            detail = loaded
            let savedEpisodeID = catalog.historyRecord(for: loaded.id)?.episodeID
            preferredEpisodeID = savedEpisodeID
            selectedLineID = loaded.lines.first(where: { line in
                line.episodes.contains(where: { $0.id == savedEpisodeID })
            })?.id ?? loaded.lines.first?.id ?? ""
        }
        .fullScreenCover(item: $playbackRequest) { request in
            PlayerScreen(request: request)
        }
        .sheet(isPresented: $isShowingFullDetails) {
            fullDetailsSheet
        }
        .alert("无法开始播放", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func landscapeLayout(size: CGSize) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                if catalog.alternateSources(for: media).count > 1 { sourcePicker }
                if supportedParsers.count > 1 { parserPicker }
                wideOverview(availableHeight: size.height, availableWidth: min(max(size.width * 0.42, 220), 800))
            }
            .frame(width: min(max(size.width * 0.42, 220), 800), alignment: .topLeading)

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)

            playlist
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: 1800, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var sourcePicker: some View {
        Picker("同名片源", selection: Binding(
            get: { media.sourceKey },
            set: { sourceKey in
                if let source = catalog.alternateSources(for: media).first(where: { $0.sourceKey == sourceKey }) {
                    switchSource(to: source)
                }
            }
        )) {
            ForEach(catalog.alternateSources(for: media)) { source in
                Text(source.sourceName).tag(source.sourceKey)
            }
        }
        .pickerStyle(.menu)
        .disabled(isResolving)
    }

    private var supportedParsers: [TVBoxParser] {
        (catalog.configuration?.parsers ?? []).filter { [0, 1].contains($0.type) }
    }

    private var parserPicker: some View {
        Picker("解析方式", selection: Binding(
            get: { catalog.selectedParserName },
            set: { catalog.selectParser($0) }
        )) {
            Text("自动选择").tag("")
            ForEach(supportedParsers) { parser in
                Text(parser.name).tag(parser.name)
            }
        }
        .pickerStyle(.menu)
    }

    private func wideOverview(availableHeight: CGFloat, availableWidth: CGFloat? = nil) -> some View {
        #if os(tvOS)
        let compact = false
        let posterWidth = min(
            TVBoxTypography.readable(270, minimum: 360),
            min(max(220, (availableHeight - 160) * 0.74), (availableWidth ?? 800) * 0.46)
        )
        #else
        let compact = availableHeight < 900
        let posterWidth = compact
            ? max(90, min(150, (availableHeight - 260) * 0.74))
            : min(270, max(120, (availableHeight - 160) * 0.74))
        #endif
        return HStack(alignment: .top, spacing: compact ? 18 : 36) {
            MediaArtwork(item: media, wide: true, showsTitle: false)
                .aspectRatio(0.74, contentMode: .fit)
                .frame(width: posterWidth)
            overviewText(compact: compact)
        }
    }

    private var portraitOverview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                MediaArtwork(item: media, wide: true, showsTitle: false)
                    .aspectRatio(0.74, contentMode: .fit)
                    .frame(width: 122)
                VStack(alignment: .leading, spacing: 12) {
                    if !media.category.isEmpty {
                        SectionEyebrow(text: media.category)
                    }
                    Text(media.title)
                        .font(.system(size: TVBoxTypography.readable(23), weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !media.subtitle.isEmpty {
                        Text(media.subtitle).font(.system(size: TVBoxTypography.readable(13, minimum: 23), weight: .medium)).foregroundStyle(Color.tvboxCyan)
                    }
                    overviewActions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !media.summary.isEmpty {
                    Text(media.summary)
                        .font(.system(size: TVBoxTypography.readable(14)))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .lineSpacing(4)
                        .lineLimit(3)
            }
            metadata
        }
    }

    private func overviewText(compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            if !compact, !media.category.isEmpty {
                SectionEyebrow(text: media.category)
            }
            Text(media.title)
                .font(.system(size: TVBoxTypography.readable(compact ? 23 : 36), weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !compact, !media.subtitle.isEmpty {
                Text(media.subtitle).font(.system(size: TVBoxTypography.readable(16, minimum: 23), weight: .medium)).foregroundStyle(Color.tvboxCyan)
            }
            metadata
            if !media.summary.isEmpty {
                Text(media.summary)
                    .font(.system(size: TVBoxTypography.readable(compact ? 13 : 15)))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineSpacing(5)
                    .lineLimit(compact ? 2 : 3)
            }
            overviewActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var metadata: some View {
        let values = detailMetadata
        return Group {
            if !values.isEmpty {
                Text(values.joined(separator: " · "))
                    .font(.system(size: TVBoxTypography.readable(12, minimum: 23), weight: .medium))
                    .foregroundStyle(Color.tvboxMuted)
                    .lineSpacing(4)
                    .lineLimit(2)
            }
        }
    }

    private var favoriteButton: some View {
        Button {
            catalog.toggleFavorite(media)
        } label: {
            Label(catalog.isFavorite(media) ? "已收藏" : "收藏", systemImage: catalog.isFavorite(media) ? "heart.fill" : "heart")
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .fixedSize()
    }

    private var overviewActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                favoriteButton
                if hasAdditionalDetails { moreDetailsButton }
            }
            VStack(alignment: .leading, spacing: 8) {
                favoriteButton
                if hasAdditionalDetails { moreDetailsButton }
            }
        }
    }

    private var moreDetailsButton: some View {
        Button("更多信息") { isShowingFullDetails = true }
            .buttonStyle(.bordered)
            .fixedSize()
    }

    private var detailMetadata: [String] {
        [media.year, media.area, media.language, media.actor.isEmpty ? "" : "主演：\(media.actor)", media.director.isEmpty ? "" : "导演：\(media.director)"]
            .filter { !$0.isEmpty }
    }

    private var hasAdditionalDetails: Bool {
        !media.category.isEmpty || !media.sourceName.isEmpty || !media.subtitle.isEmpty
            || !media.summary.isEmpty || !detailMetadata.isEmpty
    }

    private var fullDetailsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionEyebrow(text: media.category.isEmpty ? media.sourceName : media.category)
                    Text(media.title)
                        .font(.system(size: TVBoxTypography.readable(28), weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !media.subtitle.isEmpty {
                        Text(media.subtitle)
                            .font(.system(size: TVBoxTypography.readable(16), weight: .medium))
                            .foregroundStyle(Color.tvboxCyan)
                    }
                    if !detailMetadata.isEmpty {
                        Text(detailMetadata.joined(separator: " · "))
                            .font(.system(size: TVBoxTypography.readable(14), weight: .medium))
                            .foregroundStyle(Color.tvboxMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !media.summary.isEmpty {
                        Text(media.summary)
                            .font(.system(size: TVBoxTypography.readable(16)))
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .navigationTitle("详细信息")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isShowingFullDetails = false }
                }
            }
        }
    }

    private var playlist: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("选集")
                    .font(.system(size: TVBoxTypography.readable(20), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 12)
                if let line = selectedLine {
                    Text("\(line.episodes.count) 集")
                        .font(.system(size: TVBoxTypography.readable(14), weight: .medium))
                        .foregroundStyle(Color.tvboxMuted)
                }
            }
            if media.lines.count > 1 {
                Picker("线路", selection: $selectedLineID) {
                    ForEach(media.lines) { line in
                        Text(line.flag).tag(line.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isResolving)
            }

            if let line = selectedLine, !line.episodes.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.flexible())], alignment: .leading, spacing: episodeRowSpacing) {
                            ForEach(line.episodes) { episode in
                                Button { play(episode) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: TVBoxTypography.readable(21)))
                                            .foregroundStyle(Color.tvboxAccent)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(episode.title)
                                                .font(.system(size: TVBoxTypography.readable(14), weight: .semibold))
                                                .foregroundStyle(Color.primary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                            #if os(tvOS)
                                            if episode.id == preferredEpisodeID {
                                                Text("继续观看")
                                                    .font(.system(size: TVBoxTypography.readable(11, minimum: 20), weight: .semibold))
                                                    .foregroundStyle(Color.tvboxAccent)
                                            }
                                            #endif
                                        }
                                        Spacer(minLength: 3)
                                        if isResolving { ProgressView().tint(Color.tvboxAccent) }
                                    }
                                    .padding(.horizontal, 18)
                                    .frame(maxWidth: .infinity, minHeight: TVBoxTypography.readable(56, minimum: 72), alignment: .leading)
                                    #if os(tvOS)
                                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    #else
                                    .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                                    #endif
                                }
                                .platformFocusableButtonStyle()
                                #if os(tvOS)
                                .onAppear { focusPendingEpisode(episode.id) }
                                .onChange(of: pendingEpisodeFocusID) { _, pendingID in
                                    if pendingID == episode.id { focusPendingEpisode(episode.id) }
                                }
                                .focused($focusedEpisodeID, equals: episode.id)
                                #endif
                                #if os(tvOS)
                                .accessibilityLabel(episode.id == preferredEpisodeID ? "继续观看，\(episode.title)" : episode.title)
                                #else
                                .accessibilityLabel(episode.title)
                                #endif
                                .disabled(isResolving)
                                .id(episode.id)
                            }
                        }
                        .padding(.horizontal, episodeFocusInset)
                        .padding(.vertical, episodeFocusInset)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    #if os(tvOS)
                    .focusSection()
                    .onAppear { focusPreferredEpisode(using: proxy, episodes: line.episodes) }
                    .onChange(of: selectedLineID) { _, _ in focusPreferredEpisode(using: proxy, episodes: selectedLine?.episodes ?? []) }
                    #endif
                }
            } else {
                Text("站点尚未返回播放线路。")
                    .font(.system(size: TVBoxTypography.readable(13)))
                    .foregroundStyle(Color.tvboxMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.vertical, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var episodeFocusInset: CGFloat {
        #if os(tvOS)
        20
        #else
        8
        #endif
    }

    private var episodeRowSpacing: CGFloat {
        #if os(tvOS)
        18
        #else
        10
        #endif
    }

    #if os(tvOS)
    private func focusPreferredEpisode(using proxy: ScrollViewProxy, episodes: [Episode]) {
        guard let targetID = preferredEpisodeID,
              episodes.contains(where: { $0.id == targetID }) else {
            pendingEpisodeFocusID = nil
            return
        }
        let targetLineID = selectedLineID
        let targetMediaID = media.id
        pendingEpisodeFocusID = targetID
        Task { @MainActor in
            await Task.yield()
            guard preferredEpisodeID == targetID,
                  selectedLineID == targetLineID,
                  media.id == targetMediaID else { return }
            proxy.scrollTo(targetID, anchor: .center)
            await Task.yield()
            guard preferredEpisodeID == targetID,
                  selectedLineID == targetLineID,
                  media.id == targetMediaID else { return }
            focusedEpisodeID = targetID
        }
    }

    private func focusPendingEpisode(_ episodeID: String) {
        guard pendingEpisodeFocusID == episodeID else { return }
        focusedEpisodeID = episodeID
        pendingEpisodeFocusID = nil
    }
    #endif

    private func play(_ episode: Episode) {
        guard !isResolving else { return }
        isResolving = true
        let queue = selectedLine?.episodes ?? media.episodes
        let queueIndex = queue.firstIndex(where: { $0.id == episode.id }) ?? 0
        Task {
            do {
                playbackRequest = try await catalog.playbackRequest(
                    for: media,
                    episode: episode,
                    queue: queue,
                    queueIndex: queueIndex
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isResolving = false
        }
    }

    private func switchSource(to source: MediaItem) {
        guard source.sourceKey != media.sourceKey, !isResolving else { return }
        isResolving = true
        Task {
            let loaded = await catalog.detail(for: source)
            detail = loaded
            selectedLineID = loaded.lines.first?.id ?? ""
            preferredEpisodeID = nil
            isResolving = false
        }
    }
}
