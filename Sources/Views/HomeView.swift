import SwiftUI
#if os(iOS)
import UIKit
#endif

private enum HomeSection: String, CaseIterable, Identifiable {
    case video = "影视"
    case live = "直播"
    case search = "搜索"
    case settings = "设置"

    var id: String { rawValue }
}

#if os(iOS)
private struct ScrollBounceConfigurator: UIViewRepresentable {
    let isDisabled: Bool

    func makeUIView(context: Context) -> ScrollBounceProbeView {
        ScrollBounceProbeView(isDisabled: isDisabled)
    }

    func updateUIView(_ uiView: ScrollBounceProbeView, context: Context) {
        uiView.isDisabled = isDisabled
        uiView.updateScrollView()
    }

    final class ScrollBounceProbeView: UIView {
        var isDisabled: Bool

        init(isDisabled: Bool) {
            self.isDisabled = isDisabled
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            updateScrollView()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateScrollView()
        }

        func updateScrollView() {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    scrollView.bounces = !isDisabled
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
#endif

struct HomeView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage("tvbox.searchAcrossSites") private var searchAcrossSites = true
    @State private var searchText = ""
    @State private var section: HomeSection = .video
    @State private var playbackRequest: PlaybackRequest?
    @State private var epgChannel: TVBoxLiveChannel?
    @State private var lockedGroup: TVBoxLiveGroup?
    @State private var unlockedLiveGroups: Set<String> = []

    private func items(for section: HomeSection) -> [MediaItem] {
        switch section {
        case .video: return catalog.items
        case .live: return []
        case .search: return catalog.isSearching ? catalog.items : []
        case .settings: return []
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= geometry.size.height
            rootContent(wide: wide)
        }
        .fullScreenCover(item: $playbackRequest) { request in
            PlayerScreen(request: request)
        }
        #if os(tvOS)
        .fullScreenCover(item: $epgChannel) { channel in
            LiveEPGSheet(channel: channel, template: catalog.configuration?.epgURL ?? "", headersForAddress: {
                catalog.configuration?.liveHeaders(for: $0) ?? [:]
            }) { request in
                playbackRequest = request
            }
        }
        #else
        .sheet(item: $epgChannel) { channel in
            LiveEPGSheet(channel: channel, template: catalog.configuration?.epgURL ?? "", headersForAddress: {
                catalog.configuration?.liveHeaders(for: $0) ?? [:]
            }) { request in
                playbackRequest = request
            }
        }
        #endif
        #if os(tvOS)
        .fullScreenCover(item: $lockedGroup) { group in
            LiveGroupPasswordSheet(group: group) { unlockedLiveGroups.insert(group.id) }
        }
        #else
        .sheet(item: $lockedGroup) { group in
            LiveGroupPasswordSheet(group: group) { unlockedLiveGroups.insert(group.id) }
        }
        #endif
        .onChange(of: section) { _, newValue in
            if newValue == .live { catalog.loadLive() }
            if newValue == .video {
                searchText = ""
                catalog.selectCategory("")
            }
        }
        .onChange(of: catalog.selectedSiteKey) { _, _ in
            searchText = ""
        }
        .onChange(of: searchAcrossSites) { _, _ in
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                submitSearch()
            }
        }
        .onChange(of: searchText) { _, value in
            if section == .search,
               catalog.isSearching,
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                catalog.search("")
            }
        }
    }

    @ViewBuilder
    private func rootContent(wide: Bool) -> some View {
        ZStack {
            ScreenBackground()
            TabView(selection: $section) {
                navigationTab(.video, wide: wide)
                navigationTab(.live, wide: wide)
                navigationTab(.search, wide: wide)
                navigationTab(.settings, wide: wide)
            }
            #if os(iOS)
            .tabBarMinimizeBehavior(.onScrollDown)
            #endif
            .tint(Color.tvboxAccent)
        }
    }

    private func navigationTab(_ tab: HomeSection, wide: Bool) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(tvOS)
                header(wide: wide)
                    .frame(maxWidth: 1500, alignment: .leading)
                    .padding(.horizontal, wide ? 72 : 20)
                    .padding(.top, wide ? 28 : 18)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                #endif

                if tab == .search {
                    selectedSectionContent(for: tab, wide: wide)
                        .navigationTitle("搜索")
                        .searchable(text: $searchText, prompt: "搜索片名")
                        .searchScopes($searchAcrossSites) {
                            Text("全站").tag(true)
                            Text("本站").tag(false)
                        }
                        .onSubmit(of: .search, submitSearch)
                } else if tab == .settings {
                    selectedSectionContent(for: tab, wide: wide)
                        .navigationTitle("设置")
                } else {
                    selectedSectionContent(for: tab, wide: wide)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationDestination(for: MediaItem.self) { item in
                    DetailView(item: item)
                        .toolbar(.visible, for: .navigationBar)
                        .toolbar(.hidden, for: .tabBar)
                }
                .toolbar(tab == .search || tab == .settings ? .visible : .hidden, for: .navigationBar)
        }
        .tabItem { Label(tab.rawValue, systemImage: sectionSymbol(for: tab)) }
        .tag(tab)
    }

    @ViewBuilder
    private func selectedSectionContent(for selectedSection: HomeSection, wide: Bool) -> some View {
        if selectedSection == .settings {
            SettingsView()
        } else {
            scrollableSectionContent(for: selectedSection, wide: wide)
        }
    }

    private func scrollableSectionContent(for selectedSection: HomeSection, wide: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: wide ? 28 : 20) {
                #if os(iOS)
                if selectedSection != .search {
                    header(wide: wide)
                }
                #endif
                searchSectionContent(for: selectedSection, wide: wide)
                videoSectionContent(for: selectedSection, wide: wide)
                primarySectionContent(for: selectedSection, wide: wide)
                statusSectionContent
                footer
            }
            .frame(maxWidth: 1500)
            .padding(.horizontal, wide ? 72 : 20)
            .padding(.top, wide ? 28 : 18)
            .frame(maxWidth: .infinity)
            #if os(iOS)
            .background {
                ScrollBounceConfigurator(isDisabled: selectedSection == .live)
            }
            #endif
        }
        .id(selectedSection)
        #if os(tvOS)
        .scrollBounceBehavior(.basedOnSize)
        #endif
        .transition(.opacity)
    }

    @ViewBuilder
    private func searchSectionContent(for selectedSection: HomeSection, wide: Bool) -> some View {
        if selectedSection == .search {
            searchHistorySection
            if catalog.isSearching {
                searchResultsContent(for: selectedSection, wide: wide)
            }
            savedItemsSection("观看历史", items: catalog.historyItems.map(\.item), wide: wide, history: true)
            savedItemsSection("我的收藏", items: catalog.favoriteItems, wide: wide)
        }
    }

    @ViewBuilder
    private func searchResultsContent(for selectedSection: HomeSection, wide: Bool) -> some View {
        let values = items(for: selectedSection)
        if !values.isEmpty {
            contentGrid(values, wide: wide, titleOverride: "搜索结果", section: selectedSection)
        } else if !catalog.isLoading {
            emptyState
        }
    }

    @ViewBuilder
    private func videoSectionContent(for selectedSection: HomeSection, wide: Bool) -> some View {
        if selectedSection == .video {
            if !catalog.categories.isEmpty {
                categoryPicker()
            }
            if let category = catalog.selectedCategory,
               catalog.selectedSite?.filterable == true,
               !category.filters.isEmpty {
                filterPicker(category: category)
            }
            if wide, catalog.selectedCategoryID.isEmpty, searchText.isEmpty,
               let featured = items(for: selectedSection).first {
                NavigationLink(value: featured) { featuredCard(featured, wide: wide) }
                    .buttonStyle(FocusAwareButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func primarySectionContent(for selectedSection: HomeSection, wide: Bool) -> some View {
        switch selectedSection {
        case .live:
            liveContent(wide: wide)
        case .video where !items(for: selectedSection).isEmpty:
            contentGrid(items(for: selectedSection), wide: wide, section: selectedSection)
        case .video where !catalog.isLoading:
            emptyState
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusSectionContent: some View {
        if catalog.isLoading {
            HStack {
                ProgressView().tint(.white)
                Text("正在载入…").foregroundStyle(Color.tvboxMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        if let message = catalog.loadMessage {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.tvboxMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func header(wide: Bool) -> some View {
        if wide {
            HStack(spacing: 18) {
                brand
                Spacer(minLength: 8)
            }
        } else {
            HStack(spacing: 10) {
                brand
                Spacer(minLength: 0)
            }
        }
    }

    private var brand: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Color.tvboxAccent, Color(red: 0.78, green: 0.12, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(catalog.selectedSite?.name ?? "选择片源")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 180, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionSymbol(for value: HomeSection) -> String {
        switch value {
        case .video: return "play.rectangle.on.rectangle"
        case .live: return "dot.radiowaves.left.and.right"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }

    private func categoryPicker() -> some View {
        Menu {
            Picker("分类", selection: Binding(
                get: { catalog.selectedCategoryID },
                set: {
                    searchText = ""
                    catalog.selectCategory($0)
                }
            )) {
                Text("全部").tag("")
                ForEach(catalog.categories) { category in
                    Text(category.name).tag(category.id)
                }
            }
        } label: {
            Label(catalog.selectedCategory?.name ?? "全部分类", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.automatic)
    }

    private func filterPicker(category: TVBoxCategory) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(category.filters) { filter in
                    Picker(filter.name, selection: Binding(
                        get: { catalog.selectedFilterValue(for: filter.key) },
                        set: {
                            searchText = ""
                            catalog.setFilter(filter.key, value: $0)
                        }
                    )) {
                        Text("全部").tag("")
                        ForEach(filter.options) { option in
                            Text(option.title).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private func contentGrid(_ values: [MediaItem], wide: Bool, titleOverride: String? = nil, section: HomeSection) -> some View {
        let columnCount = wide ? 5 : 2
        let columns = Array(repeating: GridItem(.flexible(), spacing: wide ? 22 : 13), count: columnCount)
        return VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionEyebrow(text: titleOverride ?? (catalog.isSearchingAllSites ? "全站搜索" : (catalog.selectedCategory?.name ?? "影视内容")))
                    Text(titleOverride ?? (catalog.isSearching ? "搜索结果" : "正在探索"))
                        .font(.system(size: wide ? 26 : 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                }
                Spacer()
                Text("\(values.count) 个条目")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tvboxMuted)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: wide ? 24 : 18) {
                ForEach(values) { item in
                        MediaCard(item: item)
                            .onAppear {
                            if self.section == section,
                               section == .video || (section == .search && catalog.isSearching) {
                                catalog.loadMoreIfNeeded(current: item)
                            }
                        }
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func savedItemsSection(_ title: String, items: [MediaItem], wide: Bool, history: Bool = false) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: wide ? 22 : 13), count: wide ? 5 : 2)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionEyebrow(text: title)
                Spacer()
                if history {
                    Button("清空") { catalog.clearHistory() }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(FocusAwareButtonStyle())
                }
                Text("\(items.count) 个条目")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tvboxMuted)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: wide ? 24 : 18) {
                if items.isEmpty {
                    Text(history ? "还没有观看记录。" : "还没有收藏内容。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.tvboxMuted)
                        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                } else {
                    ForEach(items) { item in
                        MediaCard(item: item)
                            .contextMenu {
                                if history {
                                    Button(role: .destructive) { catalog.removeHistory(item.id) } label: {
                                        Label("从历史记录移除", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    private func featuredCard(_ item: MediaItem, wide: Bool) -> some View {
        HStack(spacing: 26) {
            MediaArtwork(item: item, wide: true)
                .frame(width: 410, height: 250)
            VStack(alignment: .leading, spacing: 13) {
                SectionEyebrow(text: item.category.isEmpty ? "推荐" : item.category)
                Text(item.title)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Text(item.summary.isEmpty ? item.subtitle : item.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(3)
                HStack(spacing: 12) {
                    if !item.year.isEmpty { Label(item.year, systemImage: "calendar") }
                    if !item.remarks.isEmpty { Label(item.remarks, systemImage: "sparkles") }
                    if !item.lines.isEmpty { Label("\(item.lines.count) 条线路", systemImage: "rectangle.stack") }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.tvboxMuted)
                Label("查看详情", systemImage: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 11)
                    .background(Color.tvboxAccent, in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 25)
        }
        .padding(14)
        .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private func liveContent(wide: Bool) -> some View {
        if catalog.isLoadingLive && catalog.liveGroups.isEmpty {
            ProgressView("正在载入直播频道…").tint(.white).frame(maxWidth: .infinity).padding(40)
        } else if catalog.liveGroups.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 32)).foregroundStyle(Color.tvboxCyan)
                Text("tvbox.json 没有可用的直播频道").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.primary)
                Text("支持配置内 lives 分组，或在 lives[].url 中提供 TXT/M3U 地址。")
                    .font(.system(size: 13)).foregroundStyle(Color.tvboxMuted).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(catalog.liveGroups) { group in
                    if !group.password.isEmpty && !unlockedLiveGroups.contains(group.id) {
                        Button { lockedGroup = group } label: {
                            Label("\(group.name) · 需要密码", systemImage: "lock.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(FocusAwareButtonStyle())
                    } else {
                        VStack(alignment: .leading, spacing: 13) {
                            SectionEyebrow(text: group.name)
                            liveChannelGrid(group.channels, wide: wide)
                        }
                    }
                }
            }
        }
    }

    private func liveChannelGrid(_ channels: [TVBoxLiveChannel], wide: Bool) -> some View {
        let columnCount = wide ? 4 : 2
        let rowCount = (channels.count + columnCount - 1) / columnCount
        let gridHeight = CGFloat(rowCount * 64 + max(0, rowCount - 1) * 12)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(channels) { channel in
                liveChannelControl(channel)
                    .accessibilityHint("选择直播线路并播放")
            }
        }
        .frame(height: gridHeight, alignment: .top)
    }

    private func liveChannelControl(_ channel: TVBoxLiveChannel) -> some View {
        Menu {
            if catalog.configuration?.epgURL.isEmpty == false {
                Button("节目单 · \(channel.name)") { epgChannel = channel }
            }
            ForEach(channel.sources) { source in
                Button(source.name) {
                    playLive(channel: channel, source: source)
                }
            }
        } label: {
            liveChannelLabel(channel)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
    }

    private func liveChannelLabel(_ channel: TVBoxLiveChannel) -> some View {
        HStack(spacing: 12) {
            if let logoURL = channel.logoURL {
                ZStack {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Color.tvboxCyan)
                    CachedArtworkImage(url: logoURL, contentMode: .fit)
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.tvboxCyan)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text("\(channel.sources.count) 条线路").font(.system(size: 11)).foregroundStyle(Color.tvboxMuted)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(Color.tvboxAccent)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .leading)
        .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "没有找到内容",
            systemImage: "film",
            description: Text("检查 tvbox.json 站点或搜索条件。")
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.tvboxCyan).frame(width: 7, height: 7)
            Text("iOS / tvOS")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.tvboxMuted)
    }

    private func submitSearch() {
        let hasSearchableSource = searchAcrossSites
            ? catalog.availableSites.contains(where: \.searchable)
            : catalog.selectedSite?.searchable == true
        guard hasSearchableSource else { return }
        section = .search
        catalog.search(searchText, acrossAllSites: searchAcrossSites)
    }

    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionEyebrow(text: "最近搜索")
                Spacer()
                Button("清空") { catalog.clearRecentSearches() }
                    .buttonStyle(.bordered)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(catalog.recentSearches, id: \.self) { query in
                        Button {
                            searchText = query
                            submitSearch()
                        } label: {
                            Label(query, systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func playLive(channel: TVBoxLiveChannel, source: TVBoxLiveSource) {
        guard let url = URL(string: source.address),
              ["http", "https", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "") else { return }
        let currentGroup = catalog.liveGroups.first { $0.channels.contains(channel) }
        let queue: [Episode] = catalog.liveGroups.flatMap { group in
            group.channels.compactMap { value -> Episode? in
                guard let primarySource = value.sources.first else { return nil }
                let selected = group.id == currentGroup?.id && value.id == channel.id ? source : primarySource
                let headers = selected.headers.merging(catalog.configuration?.liveHeaders(for: selected.address) ?? [:]) { _, rule in rule }
                return Episode(
                    id: "live::\(group.id)::\(value.id)",
                    title: "\(group.name) · \(value.name)",
                    address: selected.address,
                    flag: "直播",
                    headers: headers
                )
            }
        }
        let currentEpisodeID = "live::\(currentGroup?.id ?? "")::\(channel.id)"
        let queueIndex = queue.firstIndex(where: { $0.id == currentEpisodeID }) ?? 0
        let headers = source.headers.merging(catalog.configuration?.liveHeaders(for: source.address) ?? [:]) { _, rule in rule }
        playbackRequest = PlaybackRequest(
            title: "\(channel.name) · \(source.name)",
            url: url,
            headers: headers,
            queue: queue,
            queueIndex: queueIndex,
            isLive: true
        )
    }
}

private struct LiveGroupPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: TVBoxLiveGroup
    let onUnlock: () -> Void
    @State private var password = ""
    @State private var isInvalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section(group.name) {
                    SecureField("输入分组密码", text: $password)
                    if isInvalid {
                        Text("密码不正确。")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("受限直播分组")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解锁") {
                        guard password == group.password else { isInvalid = true; return }
                        onUnlock()
                        dismiss()
                    }
                    .disabled(password.isEmpty)
                }
            }
            .onChange(of: password) { _, _ in isInvalid = false }
        }
    }
}

private struct EPGPlaybackTarget: Equatable {
    let url: URL
    let isLive: Bool
}

private struct LiveEPGSheet: View {
    @Environment(\.dismiss) private var dismiss
    let channel: TVBoxLiveChannel
    let template: String
    let headersForAddress: (String) -> [String: String]
    let onPlay: (PlaybackRequest) -> Void
    @State private var programs: [TVBoxEPGProgram] = []
    @State private var isLoading = true
    @State private var message: String?
    @State private var selectedDate = Calendar(identifier: .gregorian).startOfDay(for: Date())
    @State private var selectedSourceID = ""

    private var selectedSource: TVBoxLiveSource? {
        channel.sources.first { $0.id == selectedSourceID } ?? channel.sources.first
    }

    private var selectedSourceBinding: Binding<String> {
        Binding(
            get: { selectedSource?.id ?? "" },
            set: { selectedSourceID = $0 }
        )
    }

    private var dateOptions: [Date] {
        let calendar = Calendar(identifier: .gregorian)
        return (-6...1).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: Date())) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(channel.name) {
                    Picker("日期", selection: $selectedDate) {
                        ForEach(dateOptions, id: \.self) { date in
                            Text(dateLabel(date)).tag(date)
                        }
                    }
                    .pickerStyle(.menu)

                    if channel.sources.count > 1 {
                        Picker("线路", selection: selectedSourceBinding) {
                            ForEach(channel.sources) { source in
                                Text(source.name).tag(source.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                if isLoading {
                    Section {
                        ProgressView("正在载入节目单…")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else if programs.isEmpty {
                    Section {
                        ContentUnavailableView(
                            message ?? "没有可用的节目单",
                            systemImage: "calendar",
                            description: Text("选择其他日期，或检查节目单配置。")
                        )
                    }
                } else {
                    Section("节目") {
                        ForEach(programs) { program in
                            Button {
                                play(program)
                            } label: {
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(program.start).monospacedDigit()
                                        Text(program.end)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    Text(program.title)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if playbackTarget(for: program) == nil {
                                        Image(systemName: "info.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(playbackTarget(for: program) == nil)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("节目单")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task(id: "\(channel.id)|\(selectedDate.timeIntervalSince1970)") {
            isLoading = true
            programs = []
            message = nil
            guard !template.isEmpty else {
                message = "配置没有提供节目单地址。"
                isLoading = false
                return
            }
            do {
                let loaded = try await CatalogService().loadEPG(for: channel.name, template: template, date: selectedDate)
                guard !Task.isCancelled else { return }
                programs = loaded
                message = programs.isEmpty ? "这一天没有可用的节目单。" : nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            isLoading = false
        }
    }

    private func playbackTarget(for program: TVBoxEPGProgram) -> EPGPlaybackTarget? {
        guard let source = selectedSource, let interval = program.interval(on: selectedDate) else { return nil }
        let now = Date()
        if now < interval.start { return nil }
        if now < interval.end {
            guard let liveURL = URL(string: source.address),
                  ["http", "https", "rtsp", "rtmp"].contains(liveURL.scheme?.lowercased() ?? "") else { return nil }
            return EPGPlaybackTarget(url: liveURL, isLive: true)
        }

        guard let sourceIndex = channel.sources.firstIndex(of: source) else { return nil }
        let template = sourceIndex < channel.catchupSources.count ? channel.catchupSources[sourceIndex] : ""
        let begin = Int(interval.start.timeIntervalSince1970)
        let end = Int(interval.end.timeIntervalSince1970)
        let startTokens = ["${(b)timestamp}", "{start}", "${start}"]
        let endTokens = ["${(e)timestamp}", "{end}", "${end}"]
        var address: String
        if startTokens.contains(where: { template.contains($0) }),
           endTokens.contains(where: { template.contains($0) }) {
            let replacements = [
                ("${(b)timestamp}", String(begin)),
                ("${(e)timestamp}", String(end)),
                ("${duration}", String(max(0, end - begin))),
                ("${start}", String(begin)),
                ("${end}", String(end)),
                ("{duration}", String(max(0, end - begin))),
                ("{start}", String(begin)),
                ("{end}", String(end))
            ]
            address = template
            for (token, value) in replacements {
                address = address.replacingOccurrences(of: token, with: value)
            }
        } else if source.address.contains("PLTV/8888") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyyMMddHHmmss"
            let start = formatter.string(from: interval.start.addingTimeInterval(30))
            let end = formatter.string(from: interval.end.addingTimeInterval(30))
            address = source.address + (source.address.contains("?") ? "&" : "?") + "playseek=\(start)-\(end)"
        } else {
            return nil
        }
        guard !address.isEmpty else { return nil }
        let candidate = URL(string: address, relativeTo: URL(string: source.address))?.absoluteURL
        guard let candidate, ["http", "https", "rtsp", "rtmp"].contains(candidate.scheme?.lowercased() ?? "") else { return nil }
        return EPGPlaybackTarget(url: candidate, isLive: false)
    }

    private func play(_ program: TVBoxEPGProgram) {
        guard let target = playbackTarget(for: program),
              let source = selectedSource else { return }
        onPlay(PlaybackRequest(
            title: "\(channel.name) · \(program.title)",
            url: target.url,
            headers: source.headers.merging(headersForAddress(source.address)) { _, rule in rule },
            isLive: target.isLive
        ))
        dismiss()
    }

    private func dateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}
