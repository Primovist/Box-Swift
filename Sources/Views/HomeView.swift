import SwiftUI

private struct HomeFieldFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private enum HomeSection: String, CaseIterable, Identifiable {
    case video = "影视"
    case live = "直播"
    case search = "搜索"
    case settings = "设置"

    var id: String { rawValue }
}

struct HomeView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage("tvbox.searchAcrossSites") private var searchAcrossSites = true
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var section: HomeSection = .video
    @State private var playbackRequest: PlaybackRequest?
    @State private var epgChannel: TVBoxLiveChannel?
    @State private var lockedGroup: TVBoxLiveGroup?
    @State private var unlockedLiveGroups: Set<String> = []
    @State private var selectedLiveGroupID = ""

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
                catalog.restoreVideoCatalog()
            }
        }
        .onChange(of: catalog.selectedSiteKey) { _, _ in
            searchText = ""
        }
        .onChange(of: catalog.liveGroups.map(\.id)) { _, groupIDs in
            if !groupIDs.contains(selectedLiveGroupID) {
                selectedLiveGroupID = ""
            }
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
                if tab == .search {
                    titledSectionContent(for: tab, wide: wide)
                        .searchable(text: $searchText, prompt: "搜索片名")
                        #if os(iOS)
                        .searchFocused($isSearchFocused)
                        #endif
                        .searchScopes($searchAcrossSites) {
                            Text("全站").tag(true)
                            Text("本站").tag(false)
                        }
                        .onSubmit(of: .search, submitSearch)
                } else {
                    titledSectionContent(for: tab, wide: wide)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationDestination(for: MediaItem.self) { item in
                    DetailView(item: item)
                        #if os(tvOS)
                        .toolbar(.hidden, for: .navigationBar)
                        #else
                        .toolbar(.visible, for: .navigationBar)
                        #endif
                        .toolbar(.hidden, for: .tabBar)
                }
                #if os(tvOS)
                .toolbar(.hidden, for: .navigationBar)
                #else
                .toolbar(.visible, for: .navigationBar)
                #endif
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

    @ViewBuilder
    private func titledSectionContent(for tab: HomeSection, wide: Bool) -> some View {
        #if os(tvOS)
        selectedSectionContent(for: tab, wide: wide)
            .navigationTitle("")
        #else
        selectedSectionContent(for: tab, wide: wide)
            .navigationTitle(tab.rawValue)
        #endif
    }

    private func scrollableSectionContent(for selectedSection: HomeSection, wide: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: wide ? 28 : 20) {
                searchSectionContent(for: selectedSection, wide: wide)
                videoSectionContent(for: selectedSection, wide: wide)
                primarySectionContent(for: selectedSection, wide: wide)
                statusSectionContent
            }
            .frame(maxWidth: 1500)
            .padding(.horizontal, wide ? 72 : 20)
            .padding(.top, wide ? 10 : 18)
            .frame(maxWidth: .infinity)
        }
        .id(selectedSection)
        #if os(iOS)
        .refreshable {
            guard selectedSection == .video else { return }
            await catalog.refreshSelectedSite()
        }
        #endif
        #if os(tvOS)
        .scrollBounceBehavior(.basedOnSize)
        #endif
        #if os(iOS)
        .simultaneousGesture(TapGesture().onEnded {
            if selectedSection == .search { isSearchFocused = false }
        })
        .scrollDismissesKeyboard(.interactively)
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
            contentGrid(values, wide: wide, section: selectedSection)
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
                    .platformFocusableButtonStyle()
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
                .font(.system(size: TVBoxTypography.readable(12, minimum: 23), weight: .medium))
                .foregroundStyle(Color.tvboxMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(catalog.categories) { category in
                    let isSelected = catalog.selectedCategoryID == category.id
                    Button {
                        guard !isSelected else { return }
                        searchText = ""
                        catalog.selectCategory(category.id)
                    } label: {
                        Text(category.name)
                            .font(.system(size: TVBoxTypography.readable(16, minimum: 29), weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, 20)
                            .frame(minHeight: TVBoxTypography.readable(48, minimum: 76))
                            .background(isSelected ? Color.tvboxAccent : Color.tvboxSurface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.10), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .platformFocusableButtonStyle()
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .scrollClipDisabled()
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func filterPicker(category: TVBoxCategory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(category.filters) { filter in
                VStack(alignment: .leading, spacing: 7) {
                    Text(filter.name)
                        .font(.system(size: TVBoxTypography.readable(12, minimum: 23), weight: .semibold))
                        .foregroundStyle(Color.tvboxMuted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            choiceChip(title: "全部", isSelected: catalog.selectedFilterValue(for: filter.key).isEmpty) {
                                searchText = ""
                                catalog.setFilter(filter.key, value: "")
                            }
                            ForEach(filter.options) { option in
                                choiceChip(title: option.title, isSelected: catalog.selectedFilterValue(for: filter.key) == option.value) {
                                    searchText = ""
                                    catalog.setFilter(filter.key, value: option.value)
                                }
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

    private func choiceChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: TVBoxTypography.readable(14, minimum: 25), weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: TVBoxTypography.readable(42, minimum: 66))
                .background(isSelected ? Color.tvboxAccent : Color.tvboxSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(isSelected ? 0 : 0.10), lineWidth: 1))
                .contentShape(Capsule())
        }
        .platformFocusableButtonStyle()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func contentGrid(_ values: [MediaItem], wide: Bool, section: HomeSection) -> some View {
        #if os(tvOS)
        let columnCount = wide ? 4 : 2
        #else
        let columnCount = wide ? 5 : 2
        #endif
        let columns = Array(repeating: GridItem(.flexible(), spacing: wide ? 28 : 13), count: columnCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: wide ? 36 : 18) {
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

    private func savedItemsSection(_ title: String, items: [MediaItem], wide: Bool, history: Bool = false) -> some View {
        #if os(tvOS)
        let columnCount = wide ? 4 : 2
        #else
        let columnCount = wide ? 5 : 2
        #endif
        let columns = Array(repeating: GridItem(.flexible(), spacing: wide ? 28 : 13), count: columnCount)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionEyebrow(text: title)
                Spacer()
                if history {
                    Button("清空") { catalog.clearHistory() }
                        .font(.system(size: TVBoxTypography.readable(12, minimum: 23), weight: .medium))
                        .platformFocusableButtonStyle()
                }
                Text("\(items.count) 个条目")
                    .font(.system(size: TVBoxTypography.readable(12, minimum: 23), weight: .medium))
                    .foregroundStyle(Color.tvboxMuted)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: wide ? 36 : 18) {
                if items.isEmpty {
                    Text(history ? "还没有观看记录。" : "还没有收藏内容。")
                        .font(.system(size: TVBoxTypography.readable(13)))
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
                .contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 13) {
                SectionEyebrow(text: item.category.isEmpty ? "推荐" : item.category)
                Text(item.title)
                    .font(.system(size: TVBoxTypography.readable(36), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                Text(item.summary.isEmpty ? item.subtitle : item.summary)
                    .font(.system(size: TVBoxTypography.readable(14)))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(3)
                HStack(spacing: 12) {
                    if !item.year.isEmpty { Label(item.year, systemImage: "calendar") }
                    if !item.remarks.isEmpty { Label(item.remarks, systemImage: "sparkles") }
                    if !item.lines.isEmpty { Label("\(item.lines.count) 条线路", systemImage: "rectangle.stack") }
                }
                .font(.system(size: TVBoxTypography.readable(12, minimum: 23), weight: .medium))
                .foregroundStyle(Color.tvboxMuted)
                Label("查看详情", systemImage: "arrow.right")
                    .font(.system(size: TVBoxTypography.readable(13), weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 11)
                    .background(Color.tvboxSelection, in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 25)
        }
        .padding(14)
        .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func liveContent(wide: Bool) -> some View {
        if catalog.isLoadingLive && catalog.liveGroups.isEmpty {
            ProgressView("正在载入直播频道…").tint(.white).frame(maxWidth: .infinity).padding(40)
        } else if catalog.liveGroups.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 32)).foregroundStyle(Color.tvboxCyan)
                Text("tvbox.json 没有可用的直播频道").font(.system(size: TVBoxTypography.readable(18), weight: .bold)).foregroundStyle(Color.primary)
                Text("支持配置内 lives 分组，或在 lives[].url 中提供 TXT/M3U 地址。")
                    .font(.system(size: TVBoxTypography.readable(13))).foregroundStyle(Color.tvboxMuted).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                if catalog.liveGroups.count > 1 {
                    liveGroupPicker
                }
                ForEach(visibleLiveGroups) { group in
                    if !group.password.isEmpty && !unlockedLiveGroups.contains(group.id) {
                        Button { lockedGroup = group } label: {
                            Label("\(group.name) · 需要密码", systemImage: "lock.fill")
                                .font(.system(size: TVBoxTypography.readable(15), weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .platformFocusableButtonStyle()
                    } else {
                        VStack(alignment: .leading, spacing: 13) {
                            SectionEyebrow(text: group.name)
                            liveChannelGrid(group, wide: wide)
                        }
                    }
                }
            }
        }
    }

    private var visibleLiveGroups: [TVBoxLiveGroup] {
        guard !selectedLiveGroupID.isEmpty else { return catalog.liveGroups }
        return catalog.liveGroups.filter { $0.id == selectedLiveGroupID }
    }

    private var liveGroupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                choiceChip(title: "全部", isSelected: selectedLiveGroupID.isEmpty) {
                    selectedLiveGroupID = ""
                }
                ForEach(catalog.liveGroups) { group in
                    choiceChip(title: group.name, isSelected: selectedLiveGroupID == group.id) {
                        selectedLiveGroupID = group.id
                    }
                }
            }
        }
        .scrollClipDisabled()
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func liveChannelGrid(_ group: TVBoxLiveGroup, wide: Bool) -> some View {
        let channels = group.channels
        #if os(tvOS)
        let columnCount = wide ? 4 : 2
        #else
        let columnCount = wide ? 3 : 2
        #endif
        let rowCount = (channels.count + columnCount - 1) / columnCount
        let cellHeight = TVBoxTypography.readable(64, minimum: 112)
        let gridHeight = CGFloat(rowCount) * cellHeight + CGFloat(max(0, rowCount - 1) * 16)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(channels) { channel in
                liveChannelControl(channel, group: group)
            }
        }
        .frame(height: gridHeight, alignment: .top)
    }

    private func liveChannelControl(_ channel: TVBoxLiveChannel, group: TVBoxLiveGroup) -> some View {
        Button {
            playLive(channel: channel, group: group)
        } label: {
            liveChannelLabel(channel)
        }
        .platformFocusableButtonStyle()
        .frame(maxWidth: .infinity)
        .frame(height: TVBoxTypography.readable(64, minimum: 112))
        .accessibilityHint("立即播放")
    }

    private func liveChannelLabel(_ channel: TVBoxLiveChannel) -> some View {
        HStack(spacing: 12) {
            if let logoURL = channel.logoURL {
                CachedArtworkImage(url: logoURL, contentMode: .fit)
                .frame(width: TVBoxTypography.readable(34, minimum: 52), height: TVBoxTypography.readable(34, minimum: 52))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.tvboxCyan)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.system(size: TVBoxTypography.readable(14), weight: .bold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("\(channel.sources.count) 条线路").font(.system(size: TVBoxTypography.readable(11, minimum: 23))).foregroundStyle(Color.tvboxMuted)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill").font(.system(size: TVBoxTypography.readable(11, minimum: 20))).foregroundStyle(Color.tvboxAccent)
        }
        .padding(TVBoxTypography.readable(15, minimum: 22))
        .frame(maxWidth: .infinity, minHeight: TVBoxTypography.readable(64, minimum: 112), maxHeight: TVBoxTypography.readable(64, minimum: 112), alignment: .leading)
        .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "没有找到内容",
            systemImage: "film",
            description: Text("检查 tvbox.json 站点或搜索条件。")
        )
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

    private func playLive(channel: TVBoxLiveChannel, group: TVBoxLiveGroup) {
        let accessibleGroups = catalog.liveGroups.filter { $0.password.isEmpty || unlockedLiveGroups.contains($0.id) }
        guard accessibleGroups.contains(where: { $0.id == group.id }),
              let source = channel.sources.first(where: { source in
                  guard let url = URL(string: source.address) else { return false }
                  return ["http", "https", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "")
              }),
              let configuration = catalog.configuration else { return }
        let context = LivePlaybackContext(
            groups: accessibleGroups,
            groupID: group.id,
            channelID: channel.id,
            sourceID: source.id,
            epgURL: configuration.epgURL,
            headerRules: configuration.liveHeaderRules
        )
        playbackRequest = context.request(groupID: group.id, channelID: channel.id, sourceID: source.id)
    }
}

private struct LiveGroupPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isPasswordFocused: Bool
    let group: TVBoxLiveGroup
    let onUnlock: () -> Void
    @State private var password = ""
    @State private var isInvalid = false
    @State private var passwordFieldFrame = CGRect.zero

    var body: some View {
        NavigationStack {
            Form {
                Section(group.name) {
                    SecureField("输入分组密码", text: $password)
                        .focused($isPasswordFocused)
                        #if os(iOS)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: HomeFieldFrameKey.self, value: proxy.frame(in: .global))
                            }
                        }
                        #endif
                    if isInvalid {
                        Text("密码不正确。")
                            .foregroundStyle(.orange)
                    }
                }
            }
            #if os(iOS)
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .global)
                    .onEnded { tap in
                        guard !passwordFieldFrame.contains(tap.location) else { return }
                        isPasswordFocused = false
                    }
            )
            .onPreferenceChange(HomeFieldFrameKey.self) { passwordFieldFrame = $0 }
            .scrollDismissesKeyboard(.interactively)
            #endif
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
    let durationMilliseconds: Int
    let catchupWindow: LiveCatchupWindow?
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
            return EPGPlaybackTarget(url: liveURL, isLive: true, durationMilliseconds: 0, catchupWindow: nil)
        }

        guard let sourceIndex = channel.sources.firstIndex(of: source) else { return nil }
        let template = sourceIndex < channel.catchupSources.count ? channel.catchupSources[sourceIndex] : ""
        let durationMilliseconds = max(0, Int(interval.end.timeIntervalSince(interval.start) * 1_000))
        let catchupWindow = LiveCatchupWindow(
            sourceAddress: source.address,
            template: template,
            start: interval.start,
            end: interval.end
        )
        guard let candidate = catchupWindow.url() else { return nil }
        return EPGPlaybackTarget(url: candidate, isLive: false, durationMilliseconds: durationMilliseconds, catchupWindow: catchupWindow)
    }

    private func play(_ program: TVBoxEPGProgram) {
        guard let target = playbackTarget(for: program),
              let source = selectedSource else { return }
        onPlay(PlaybackRequest(
            title: "\(channel.name) · \(program.title)",
            url: target.url,
            headers: source.headers.merging(headersForAddress(source.address)) { _, rule in rule },
            isLive: target.isLive,
            durationMilliseconds: target.durationMilliseconds,
            catchupWindow: target.catchupWindow
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
