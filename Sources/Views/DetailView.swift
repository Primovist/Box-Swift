import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @State private var detail: MediaItem?
    @State private var selectedLineID = ""
    @State private var preferredEpisodeID: String?
    @State private var playbackRequest: PlaybackRequest?
    @State private var isResolving = false
    @State private var errorMessage: String?

    let item: MediaItem

    private var media: MediaItem { detail ?? item }
    private var selectedLine: PlaybackLine? { media.lines.first { $0.id == selectedLineID } ?? media.lines.first }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= geometry.size.height
            ZStack {
                ScreenBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: wide ? 28 : 22) {
                        if catalog.alternateSources(for: media).count > 1 {
                            sourcePicker
                        }
                        if supportedParsers.count > 1 {
                            parserPicker
                        }
                        if wide {
                            wideOverview
                        } else {
                            portraitOverview
                        }
                        playlist(wide: wide)
                    }
                    .frame(maxWidth: 1350, alignment: .leading)
                    .padding(.horizontal, wide ? 72 : 20)
                    .padding(.top, wide ? 25 : 16)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(media.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar(.visible, for: .navigationBar)
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
        .alert("无法开始播放", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
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

    private var wideOverview: some View {
        HStack(alignment: .top, spacing: 36) {
            MediaArtwork(item: media, wide: true)
                .aspectRatio(0.74, contentMode: .fit)
                .frame(width: 270)
            overviewText(isWide: true)
        }
    }

    private var portraitOverview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                MediaArtwork(item: media, wide: true)
                    .aspectRatio(0.74, contentMode: .fit)
                    .frame(width: 122)
                VStack(alignment: .leading, spacing: 12) {
                    SectionEyebrow(text: media.category.isEmpty ? media.sourceName : media.category)
                    Text(media.title)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !media.subtitle.isEmpty {
                        Text(media.subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.tvboxCyan)
                    }
                    actionButtons(compact: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !media.summary.isEmpty {
                Text(media.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            metadata(compact: true)
        }
    }

    private func overviewText(isWide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionEyebrow(text: media.category.isEmpty ? media.sourceName : media.category)
            Text(media.title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !media.subtitle.isEmpty {
                Text(media.subtitle).font(.system(size: 16, weight: .medium)).foregroundStyle(Color.tvboxCyan)
            }
            metadata(compact: false)
            if !media.summary.isEmpty {
                Text(media.summary)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineSpacing(5)
                    .lineLimit(5)
            }
            actionButtons(compact: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private func metadata(compact: Bool) -> some View {
        let values = [media.year, media.area, media.language, media.actor.isEmpty ? "" : "主演：\(media.actor)", media.director.isEmpty ? "" : "导演：\(media.director)"]
            .filter { !$0.isEmpty }
        return Group {
            if !values.isEmpty {
                if compact {
                    Text(values.joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.tvboxMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    FlowMetadata(values: values)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 9) {
                actionButtonContent
            }
        } else {
            HStack(spacing: 10) {
                actionButtonContent
            }
        }
    }

    @ViewBuilder
    private var actionButtonContent: some View {
            Button {
                guard let episode = selectedLine?.episodes.first(where: { $0.id == preferredEpisodeID })
                    ?? selectedLine?.episodes.first else {
                    errorMessage = "这个条目暂时没有可播放线路。"
                    return
                }
                play(episode)
            } label: {
                if isResolving {
                    ProgressView().tint(.white).frame(minWidth: 44, minHeight: 44)
                } else {
                    Label("立即播放", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isResolving || media.episodes.isEmpty)

            Button {
                catalog.toggleFavorite(media)
            } label: {
                Label(catalog.isFavorite(media) ? "已收藏" : "收藏", systemImage: catalog.isFavorite(media) ? "heart.fill" : "heart")
            }
            .buttonStyle(.bordered)
    }

    private func playlist(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            SectionEyebrow(text: "播放列表")
            HStack(alignment: .lastTextBaseline) {
                Text("选择线路与剧集")
                    .font(.system(size: wide ? 24 : 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary)
                Spacer()
                if !media.remarks.isEmpty {
                    Text(media.remarks).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.tvboxMuted)
                }
            }

            if media.lines.count > 1 {
                Picker("线路", selection: $selectedLineID) {
                    ForEach(media.lines) { line in
                        Text(line.flag).tag(line.id)
                    }
                }
                .pickerStyle(.menu)
            }

            if let line = selectedLine, !line.episodes.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: wide ? 3 : 1), alignment: .leading, spacing: 11) {
                    ForEach(line.episodes) { episode in
                        Button { play(episode) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 21))
                                    .foregroundStyle(Color.tvboxAccent)
                                Text(episode.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 3)
                                if isResolving { ProgressView().tint(.white) }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                        }
                        .buttonStyle(FocusAwareButtonStyle())
                        .disabled(isResolving)
                    }
                }
                #if os(tvOS)
                .focusSection()
                #endif
            } else {
                Text("站点尚未返回播放线路。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.tvboxMuted)
                    .padding(.vertical, 18)
            }
        }
        .padding(.bottom, 30)
    }

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

private struct FlowMetadata: View {
    let values: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { ForEach(values.indices, id: \.self) { metadataChip(values[$0]) } }
            VStack(alignment: .leading, spacing: 8) { ForEach(values.indices, id: \.self) { metadataChip(values[$0]) } }
        }
    }

    private func metadataChip(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.tvboxMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.05), in: Capsule())
    }
}
