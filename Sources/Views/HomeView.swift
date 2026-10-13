import SwiftUI

private enum HomeSection: String, CaseIterable, Identifiable {
    case video = "影视"
    case live = "直播"
    case search = "搜索"
    case settings = "设置"

    var id: String { rawValue }
}

#if os(iOS)
private struct HomeScrollMetrics: Equatable {
    let offsetFromTop: CGFloat
    let maximumOffset: CGFloat
}
#endif

struct HomeView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage("tvbox.searchAcrossSites") private var searchAcrossSites = true
    @State private var searchText = ""
    @State private var section: HomeSection = .video
    #if os(iOS)
    @State private var isSectionNavigationCollapsed = false
    @State private var downwardScrollDistance: CGFloat = 0
    @State private var upwardScrollDistance: CGFloat = 0
    #endif
    @State private var playbackRequest: PlaybackRequest?
    @State private var epgChannel: TVBoxLiveChannel?
    @State private var activeFilter: TVBoxFilter?
    @State private var activeLiveChannel: TVBoxLiveChannel?
    @State private var lockedGroup: TVBoxLiveGroup?
    @State private var unlockedLiveGroups: Set<String> = []

    private var currentItems: [MediaItem] {
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
            NavigationStack {
                ZStack {
                    ScreenBackground()
                    VStack(spacing: 0) {
                        #if os(tvOS)
                        VStack(alignment: .leading, spacing: 18) {
                            header(wide: wide)
                            sectionPicker(wide: wide)
                        }
                        .frame(maxWidth: 1500, alignment: .leading)
                        .padding(.horizontal, wide ? 72 : 20)
                        .padding(.top, wide ? 28 : 18)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                        #endif
                        if section == .settings {
                            SettingsView()
                        } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: wide ? 28 : 20) {
                                #if os(iOS)
                                header(wide: wide)
                                #endif

                                if section == .search {
                                    searchField
                                    searchHistorySection
                                    if catalog.isSearching {
                                        if !currentItems.isEmpty {
                                            contentGrid(currentItems, wide: wide, titleOverride: "搜索结果")
                                        } else if !catalog.isLoading {
                                            emptyState
                                        }
                                    }
                                    savedItemsSection("观看历史", items: catalog.historyItems.map(\.item), wide: wide, history: true)
                                    savedItemsSection("我的收藏", items: catalog.favoriteItems, wide: wide)
                                }

                                if section == .video {
                                    if !catalog.categories.isEmpty { categoryPicker(wide: wide) }
                                    if catalog.selectedSite?.filterable == true,
                                       let category = catalog.selectedCategory,
                                       !category.filters.isEmpty {
                                        filterPicker(category: category)
                                    }
                                    if wide, catalog.selectedCategoryID.isEmpty, searchText.isEmpty,
                                       let featured = currentItems.first {
                                        NavigationLink(value: featured) { featuredCard(featured, wide: wide) }
                                            .buttonStyle(FocusAwareButtonStyle())
                                    }
                                }

                                if section == .live {
                                    liveContent(wide: wide)
                                } else if section == .video && !currentItems.isEmpty {
                                    contentGrid(currentItems, wide: wide)
                                } else if section == .video && !catalog.isLoading {
                                    emptyState
                                }

                                if catalog.isLoading {
                                    HStack { ProgressView().tint(.white); Text("正在载入…").foregroundStyle(Color.tvboxMuted) }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 20)
                                }
                                if let message = catalog.loadMessage {
                                    Text(message)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Color.tvboxMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                footer
                            }
                            .frame(maxWidth: 1500)
                            .padding(.horizontal, wide ? 72 : 20)
                            .padding(.top, wide ? 28 : 18)
                            .padding(.bottom, 48)
                            .frame(maxWidth: .infinity)
                        }
                        .id(section)
                        #if os(iOS)
                        .onScrollGeometryChange(for: HomeScrollMetrics.self) { geometry in
                            HomeScrollMetrics(
                                offsetFromTop: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                                maximumOffset: max(0, geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom)
                            )
                        } action: { oldMetrics, newMetrics in
                            updateSectionNavigation(oldMetrics: oldMetrics, newMetrics: newMetrics)
                        }
                        #endif
                        }
                    }
                }
                .navigationDestination(for: MediaItem.self) { item in
                    DetailView(item: item)
                }
                .toolbar(.hidden, for: .navigationBar)
                #if os(iOS)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    sectionNavigationBar
                }
                #endif
            }
            .tint(Color.tvboxAccent)
            #if os(tvOS)
            .confirmationDialog(activeFilter?.name ?? "筛选", isPresented: Binding(
                get: { activeFilter != nil },
                set: { if !$0 { activeFilter = nil } }
            ), titleVisibility: .visible) {
                if let filter = activeFilter {
                    Button("全部") { searchText = ""; catalog.setFilter(filter.key, value: ""); activeFilter = nil }
                    ForEach(filter.options) { option in
                        Button(option.title) { searchText = ""; catalog.setFilter(filter.key, value: option.value); activeFilter = nil }
                    }
                }
            }
            .confirmationDialog(activeLiveChannel?.name ?? "直播线路", isPresented: Binding(
                get: { activeLiveChannel != nil },
                set: { if !$0 { activeLiveChannel = nil } }
            ), titleVisibility: .visible) {
                if let channel = activeLiveChannel {
                    if catalog.configuration?.epgURL.isEmpty == false {
                        Button("节目单") { epgChannel = channel; activeLiveChannel = nil }
                    }
                    ForEach(channel.sources) { source in
                        Button(source.name) { playLive(channel: channel, source: source); activeLiveChannel = nil }
                    }
                }
            }
            #endif
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
            #if os(iOS)
            isSectionNavigationCollapsed = false
            downwardScrollDistance = 0
            upwardScrollDistance = 0
            #endif
            if newValue == .live { catalog.loadLive() }
            if newValue == .video { searchText = "" }
        }
        .onChange(of: catalog.selectedSiteKey) { _, _ in
            searchText = ""
            #if os(iOS)
            isSectionNavigationCollapsed = false
            downwardScrollDistance = 0
            upwardScrollDistance = 0
            #endif
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

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.tvboxMuted)
            TextField("搜索片名", text: $searchText)
                .font(.system(size: 15))
                .foregroundStyle(Color.primary)
                .autocorrectionDisabled()
                .disabled(searchAcrossSites
                    ? !catalog.availableSites.contains(where: \.searchable)
                    : catalog.selectedSite?.searchable == false)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .onSubmit { submitSearch() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    catalog.search("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.tvboxMuted)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(FocusAwareButtonStyle())
                .accessibilityLabel("清除搜索")
            }
            Button {
                searchAcrossSites.toggle()
            } label: {
                Text(searchAcrossSites ? "全站" : "本站")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(searchAcrossSites ? Color.tvboxCyan : Color.tvboxMuted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color.tvboxSurface, in: Capsule())
            }
            .buttonStyle(FocusAwareButtonStyle())
            .accessibilityLabel(searchAcrossSites ? "全站搜索，切换本站" : "本站搜索，切换全站")
            Button(action: submitSearch) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.tvboxAccent, in: Circle())
            }
            .buttonStyle(FocusAwareButtonStyle())
            .accessibilityLabel("搜索")
        }
        .padding(.leading, 15)
        .padding(.trailing, 5)
        .frame(minHeight: 48)
        .background(Color.tvboxSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private func sectionPicker(wide: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(HomeSection.allCases) { value in
                Button {
                    section = value
                    if value == .video { searchText = ""; catalog.selectCategory("") }
                } label: {
                    Text(value.rawValue)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(section == value ? .white : Color.tvboxMuted)
                        .padding(.horizontal, wide ? 19 : 16)
                        .padding(.vertical, 11)
                        .background(section == value ? Color.tvboxAccent : Color.tvboxSurface, in: Capsule())
                }
                .buttonStyle(FocusAwareButtonStyle())
            }
            Spacer(minLength: 0)
            if section == .video, let site = catalog.selectedSite {
                Text(site.type == 0 ? "XML API" : site.type == 4 ? "HTTP API" : "JSON API")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tvboxMuted)
            }
        }
    }

    #if os(iOS)
    private var sectionNavigationBar: some View {
        Group {
            if isSectionNavigationCollapsed {
                HStack {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            isSectionNavigationCollapsed = false
                        }
                        downwardScrollDistance = 0
                        upwardScrollDistance = 0
                    } label: {
                        Image(systemName: sectionSymbol(for: section))
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Color.tvboxAccent)
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("展开导航，当前：\(section.rawValue)")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
            } else {
                HStack(spacing: 4) {
                    ForEach(HomeSection.allCases) { value in
                        Button { selectSection(value) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: sectionSymbol(for: value))
                                    .font(.system(size: 18, weight: section == value ? .semibold : .regular))
                                Text(value.rawValue)
                                    .font(.system(size: 11, weight: section == value ? .semibold : .medium))
                            }
                            .foregroundStyle(section == value ? Color.tvboxAccent : Color.tvboxMuted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(value.rawValue)
                        .accessibilityAddTraits(section == value ? .isSelected : [])
                    }
                }
                .padding(7)
                .background(.black.opacity(0.14), in: Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
                .padding(.horizontal, 18)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 78, alignment: .bottom)
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.25), value: isSectionNavigationCollapsed)
    }

    private func selectSection(_ value: HomeSection) {
        section = value
        isSectionNavigationCollapsed = false
        downwardScrollDistance = 0
        upwardScrollDistance = 0
        if value == .video { searchText = ""; catalog.selectCategory("") }
    }

    private func updateSectionNavigation(oldMetrics: HomeScrollMetrics, newMetrics: HomeScrollMetrics) {
        guard newMetrics.maximumOffset > 1 else {
            isSectionNavigationCollapsed = false
            downwardScrollDistance = 0
            upwardScrollDistance = 0
            return
        }
        if newMetrics.offsetFromTop <= 1 {
            isSectionNavigationCollapsed = false
            downwardScrollDistance = 0
            upwardScrollDistance = 0
            return
        }
        guard abs(newMetrics.maximumOffset - oldMetrics.maximumOffset) <= 2,
              newMetrics.offsetFromTop <= newMetrics.maximumOffset + 2,
              oldMetrics.offsetFromTop <= oldMetrics.maximumOffset + 2 else {
            downwardScrollDistance = 0
            upwardScrollDistance = 0
            return
        }
        let delta = newMetrics.offsetFromTop - oldMetrics.offsetFromTop

        if delta > 0, !isSectionNavigationCollapsed {
            downwardScrollDistance += delta
            upwardScrollDistance = 0
            if downwardScrollDistance >= 24 {
                withAnimation(.snappy(duration: 0.25)) { isSectionNavigationCollapsed = true }
                downwardScrollDistance = 0
            }
        } else if delta < 0, isSectionNavigationCollapsed {
            upwardScrollDistance += -delta
            downwardScrollDistance = 0
            if upwardScrollDistance >= 12 {
                withAnimation(.snappy(duration: 0.25)) { isSectionNavigationCollapsed = false }
                upwardScrollDistance = 0
            }
        } else if delta != 0 {
            downwardScrollDistance = 0
            upwardScrollDistance = 0
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
    #endif

    private func categoryPicker(wide: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(catalog.categories) { category in
                    Button {
                        searchText = ""
                        catalog.selectCategory(category.id)
                    } label: {
                        Text(category.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(catalog.selectedCategoryID == category.id ? .white : Color.tvboxMuted)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(catalog.selectedCategoryID == category.id ? Color.tvboxAccent : Color.tvboxSurface, in: Capsule())
                    }
                    .buttonStyle(FocusAwareButtonStyle())
                }
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func filterPicker(category: TVBoxCategory) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(category.filters) { filter in
                    #if os(tvOS)
                    Button { activeFilter = filter } label: {
                        filterPickerLabel(filter)
                    }
                    .buttonStyle(FocusAwareButtonStyle())
                    #else
                    Menu {
                        Button("全部") { searchText = ""; catalog.setFilter(filter.key, value: "") }
                        ForEach(filter.options) { option in
                            Button(option.title) { searchText = ""; catalog.setFilter(filter.key, value: option.value) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(filter.name)
                            if !catalog.selectedFilterValue(for: filter.key).isEmpty {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.tvboxCyan)
                            } else {
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(Color.tvboxSurface, in: Capsule())
                    }
                    .buttonStyle(FocusAwareButtonStyle())
                    #endif
                }
            }
        }
    }

    private func contentGrid(_ values: [MediaItem], wide: Bool, titleOverride: String? = nil) -> some View {
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
                            if section == .video || (section == .search && catalog.isSearching) {
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
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: wide ? 4 : 2), spacing: 12) {
                                ForEach(group.channels) { channel in
                                    liveChannelControl(channel)
                                        .accessibilityHint("选择直播线路并播放")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func liveChannelControl(_ channel: TVBoxLiveChannel) -> some View {
        #if os(tvOS)
        Button { activeLiveChannel = channel } label: {
            liveChannelLabel(channel)
        }
        .buttonStyle(FocusAwareButtonStyle())
        #else
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
        .buttonStyle(FocusAwareButtonStyle())
        #endif
    }

    private func liveChannelLabel(_ channel: TVBoxLiveChannel) -> some View {
        HStack(spacing: 12) {
            if let logoURL = channel.logoURL {
                AsyncImage(url: logoURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Color.tvboxCyan)
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
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "film").font(.system(size: 30, weight: .light)).foregroundStyle(Color.tvboxCyan)
            Text(section == .search ? "没有找到内容" : "没有找到内容")
                .font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(Color.primary)
            Text("检查 tvbox.json 站点或搜索条件。")
                .font(.system(size: 13)).foregroundStyle(Color.tvboxMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
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
        section = .search
        catalog.search(searchText, acrossAllSites: searchAcrossSites)
    }

    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionEyebrow(text: "最近搜索")
                Spacer()
                Button("清空") { catalog.clearRecentSearches() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.tvboxMuted)
                    .buttonStyle(FocusAwareButtonStyle())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(catalog.recentSearches, id: \.self) { query in
                        Button {
                            searchText = query
                            submitSearch()
                        } label: {
                            Label(query, systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.88))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 9)
                                .background(Color.tvboxSurface, in: Capsule())
                        }
                        .buttonStyle(FocusAwareButtonStyle())
                    }
                }
            }
        }
    }

    private func filterPickerLabel(_ filter: TVBoxFilter) -> some View {
        HStack(spacing: 6) {
            Text(filter.name)
            if !catalog.selectedFilterValue(for: filter.key).isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.tvboxCyan)
            } else {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.primary.opacity(0.8))
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Color.tvboxSurface, in: Capsule())
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
        ZStack {
            ScreenBackground()
            VStack(alignment: .leading, spacing: 18) {
                SectionEyebrow(text: "受限直播分组")
                Text(group.name).font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(Color.primary)
                SecureField("输入分组密码", text: $password)
                    #if os(iOS)
                    .textFieldStyle(.roundedBorder)
                    #else
                    .textFieldStyle(.plain)
                    #endif
                if isInvalid {
                    Text("密码不正确。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 12) {
                    Button("取消") { dismiss() }.buttonStyle(FocusAwareButtonStyle())
                    Button("解锁") {
                        guard password == group.password else { isInvalid = true; return }
                        onUnlock()
                        dismiss()
                    }
                    .buttonStyle(PrimaryActionStyle())
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(28)
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

    private var dateOptions: [Date] {
        let calendar = Calendar(identifier: .gregorian)
        return (-7...1).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: Date())) }
    }

    var body: some View {
        ZStack {
            ScreenBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            SectionEyebrow(text: "节目单")
                            Text(channel.name)
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.primary)
                        }
                        Spacer()
                        Button("完成") { dismiss() }
                            .buttonStyle(FocusAwareButtonStyle())
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(dateOptions, id: \.self) { date in
                                Button {
                                    selectedDate = date
                                    isLoading = true
                                } label: {
                                    Text(dateLabel(date))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Calendar.current.isDate(date, inSameDayAs: selectedDate) ? .white : Color.tvboxMuted)
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 9)
                                        .background(Calendar.current.isDate(date, inSameDayAs: selectedDate) ? Color.tvboxAccent : Color.tvboxSurface, in: Capsule())
                                }
                                .buttonStyle(FocusAwareButtonStyle())
                            }
                        }
                    }

                    if channel.sources.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(channel.sources) { source in
                                    Button {
                                        selectedSourceID = source.id
                                    } label: {
                                        Text(source.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(selectedSource?.id == source.id ? .white : Color.tvboxMuted)
                                            .padding(.horizontal, 13)
                                            .padding(.vertical, 9)
                                            .background(selectedSource?.id == source.id ? Color.tvboxCyan.opacity(0.72) : Color.tvboxSurface, in: Capsule())
                                    }
                                    .buttonStyle(FocusAwareButtonStyle())
                                }
                            }
                        }
                    }

                    if isLoading {
                        ProgressView("正在载入节目单…")
                            .tint(.white)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else if programs.isEmpty {
                        Text(message ?? "今天没有可用的节目单。")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.tvboxMuted)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(programs) { program in
                                Button {
                                    guard let target = playbackTarget(for: program),
                                          let source = selectedSource else { return }
                                    onPlay(PlaybackRequest(
                                        title: "\(channel.name) · \(program.title)",
                                        url: target.url,
                                        headers: source.headers.merging(headersForAddress(source.address)) { _, rule in rule },
                                        isLive: target.isLive
                                    ))
                                    dismiss()
                                } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(program.start).font(.system(size: 13, weight: .bold, design: .monospaced))
                                        Text(program.end).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Color.tvboxMuted)
                                    }
                                    .frame(width: 52, alignment: .leading)
                                    Text(program.title)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Color.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: playbackTarget(for: program) == nil ? "info.circle" : "play.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.tvboxCyan)
                                }
                                .padding(.vertical, 13)
                                .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(playbackTarget(for: program) == nil)
                                #if os(tvOS)
                                .focusable()
                                #endif
                                if let last = programs.last, program.id != last.id {
                                    Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
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
