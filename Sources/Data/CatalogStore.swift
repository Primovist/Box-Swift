import Foundation
import Combine
import CryptoKit

@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var items = SampleCatalog.items
    @Published private(set) var favoriteItems: [MediaItem]
    @Published private(set) var historyItems: [PlaybackHistory]
    @Published private(set) var favoriteIDs: Set<String>
    @Published private(set) var historyIDs: [String]
    @Published private(set) var configuration: TVBoxConfiguration?
    @Published private(set) var removedSiteKeys: Set<String> = []
    @Published private(set) var categories: [TVBoxCategory] = []
    @Published private(set) var selectedCategoryID = ""
    @Published private(set) var selectedSiteKey = ""
    @Published private(set) var selectedParserName: String
    @Published private(set) var isLoading = false
    @Published private(set) var isSearching = false
    @Published private(set) var isSearchingAllSites = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var loadMessage: String?
    @Published private(set) var sourceURL: String
    @Published private(set) var savedSourceURLs: [String]
    @Published private(set) var liveGroups: [TVBoxLiveGroup] = []
    @Published private(set) var isLoadingLive = false
    @Published private(set) var hasLoadedLive = false
    @Published private(set) var recentSearches: [String]

    private let service = CatalogService()
    private var configurationTask: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var liveGeneration = 0
    private var currentPage = 1
    private var pageCount = 1
    private var searchQuery = ""
    private var selectedFilters: [String: String] = [:]
    private var globalSearchResults: [MediaItem] = []
    private var globalSearchSites: [TVBoxSite] = []
    private var globalSearchPageBySite: [String: Int] = [:]
    private var globalSearchPageCountBySite: [String: Int] = [:]

    var selectedSite: TVBoxSite? {
        availableSites.first { $0.key == selectedSiteKey } ?? availableSites.first
    }

    var availableSites: [TVBoxSite] {
        configuration?.sites.filter { !removedSiteKeys.contains($0.key) } ?? []
    }

    var selectedCategory: TVBoxCategory? {
        categories.first { $0.id == selectedCategoryID && !$0.id.isEmpty }
    }

    func selectedFilterValue(for key: String) -> String {
        selectedFilters[key] ?? ""
    }

    init() {
        let favorites = Self.decode([MediaItem].self, key: "tvbox.favoriteItems") ?? []
        let history = Self.decode([PlaybackHistory].self, key: "tvbox.playbackHistory") ?? []
        let searches = UserDefaults.standard.stringArray(forKey: "tvbox.recentSearches") ?? []
        let savedSourceURL = UserDefaults.standard.string(forKey: "tvbox.sourceURL") ?? ""
        let storedSourceURLs = UserDefaults.standard.stringArray(forKey: "tvbox.savedSourceURLs") ?? []
        let migratedFavorites = savedSourceURL.isEmpty ? favorites : favorites.map { item in
            item.sourceConfigurationURL == nil ? item.withSourceConfigurationURL(savedSourceURL) : item
        }
        let migratedHistory = savedSourceURL.isEmpty ? history : history.map { record in
            var migrated = record
            if migrated.item.sourceConfigurationURL == nil {
                migrated.item = migrated.item.withSourceConfigurationURL(savedSourceURL)
            }
            return migrated
        }
        favoriteItems = migratedFavorites
        historyItems = migratedHistory
        favoriteIDs = Set(migratedFavorites.map(\.id))
        historyIDs = migratedHistory.map { $0.item.id }
        recentSearches = Array(searches.prefix(12))
        sourceURL = savedSourceURL
        var uniqueSourceURLs: [String] = []
        for address in [savedSourceURL] + storedSourceURLs where !address.isEmpty && !uniqueSourceURLs.contains(address) {
            uniqueSourceURLs.append(address)
        }
        savedSourceURLs = uniqueSourceURLs
        selectedSiteKey = UserDefaults.standard.string(forKey: Self.siteKey(for: savedSourceURL))
            ?? UserDefaults.standard.string(forKey: "tvbox.selectedSite") ?? ""
        selectedParserName = UserDefaults.standard.string(forKey: Self.parserKey(for: savedSourceURL))
            ?? UserDefaults.standard.string(forKey: "tvbox.selectedParser") ?? ""
        let cacheMigrationKey = "tvbox.configurationCacheMigration.v2"
        if !UserDefaults.standard.bool(forKey: cacheMigrationKey) {
            if !savedSourceURL.isEmpty,
               UserDefaults.standard.data(forKey: Self.configurationKey(for: savedSourceURL)) == nil,
               let legacyConfiguration = UserDefaults.standard.data(forKey: "tvbox.cachedConfiguration") {
                UserDefaults.standard.set(legacyConfiguration, forKey: Self.configurationKey(for: savedSourceURL))
            }
            UserDefaults.standard.removeObject(forKey: "tvbox.cachedConfiguration")
            UserDefaults.standard.set(true, forKey: cacheMigrationKey)
        }
        if migratedFavorites != favorites { persist(migratedFavorites, key: "tvbox.favoriteItems") }
        if migratedHistory != history { persist(migratedHistory, key: "tvbox.playbackHistory") }

        if !savedSourceURL.isEmpty {
            let persistedAddress = savedSourceURL
            Task { [weak self] in await self?.loadConfiguration(from: persistedAddress) }
        }
    }

    func isFavorite(_ item: MediaItem) -> Bool {
        favoriteIDs.contains(item.id)
    }

    func toggleFavorite(_ item: MediaItem) {
        if favoriteIDs.contains(item.id) {
            favoriteIDs.remove(item.id)
            favoriteItems.removeAll { $0.id == item.id }
        } else {
            favoriteIDs.insert(item.id)
            favoriteItems.removeAll { $0.id == item.id }
            favoriteItems.insert(item, at: 0)
        }
        persist(favoriteItems, key: "tvbox.favoriteItems")
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "tvbox.favorites")
    }

    func markPlayed(_ item: MediaItem, episode: Episode) {
        let old = historyItems.first { $0.item.id == item.id && $0.episodeID == episode.id }
        historyItems.removeAll { $0.item.id == item.id }
        historyItems.insert(
            PlaybackHistory(item: item, episodeID: episode.id, positionMilliseconds: old?.positionMilliseconds ?? 0, updatedAt: Date()),
            at: 0
        )
        historyItems = Array(historyItems.prefix(30))
        historyIDs = historyItems.map { $0.item.id }
        persist(historyItems, key: "tvbox.playbackHistory")
        UserDefaults.standard.set(historyIDs, forKey: "tvbox.history")
    }

    func savePlaybackPosition(itemID: String?, episodeID: String?, milliseconds: Int) {
        guard let itemID, let episodeID,
              let index = historyItems.firstIndex(where: { $0.item.id == itemID && $0.episodeID == episodeID }) else { return }
        historyItems[index].positionMilliseconds = max(0, milliseconds)
        historyItems[index].updatedAt = Date()
        persist(historyItems, key: "tvbox.playbackHistory")
    }

    func resumePosition(itemID: String?, episodeID: String?) -> Int {
        guard let itemID, let episodeID else { return 0 }
        return historyItems.first { $0.item.id == itemID && $0.episodeID == episodeID }?.positionMilliseconds ?? 0
    }

    func historyRecord(for itemID: String) -> PlaybackHistory? {
        historyItems.first { $0.item.id == itemID }
    }

    func removeHistory(_ itemID: String) {
        historyItems.removeAll { $0.item.id == itemID }
        historyIDs = historyItems.map { $0.item.id }
        persist(historyItems, key: "tvbox.playbackHistory")
        UserDefaults.standard.set(historyIDs, forKey: "tvbox.history")
    }

    func clearHistory() {
        historyItems = []
        historyIDs = []
        persist(historyItems, key: "tvbox.playbackHistory")
        UserDefaults.standard.set([], forKey: "tvbox.history")
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: "tvbox.recentSearches")
    }

    func alternateSources(for item: MediaItem) -> [MediaItem] {
        let key = Self.normalizedTitle(item.title)
        var seen = Set<String>()
        return globalSearchResults.filter { Self.normalizedTitle($0.title) == key }
            .filter { seen.insert($0.sourceKey).inserted }
    }

    func saveSourceURL(_ value: String) {
        sourceURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(sourceURL, forKey: "tvbox.sourceURL")
        if !sourceURL.isEmpty {
            savedSourceURLs.removeAll { $0 == sourceURL }
            savedSourceURLs.insert(sourceURL, at: 0)
            savedSourceURLs = Array(savedSourceURLs.prefix(20))
            UserDefaults.standard.set(savedSourceURLs, forKey: "tvbox.savedSourceURLs")
        }
    }

    func selectParser(_ name: String) {
        selectedParserName = name
        if name.isEmpty {
            UserDefaults.standard.removeObject(forKey: "tvbox.selectedParser")
            UserDefaults.standard.removeObject(forKey: Self.parserKey(for: sourceURL))
        } else {
            UserDefaults.standard.set(name, forKey: "tvbox.selectedParser")
            UserDefaults.standard.set(name, forKey: Self.parserKey(for: sourceURL))
        }
    }

    func loadRemoteCatalog() {
        Task { await loadConfiguration(from: sourceURL) }
    }

    func loadConfiguration(from address: String, restoreRemovedSites: Bool = false) async {
        let previousAddress = UserDefaults.standard.string(forKey: "tvbox.sourceURL") ?? ""
        let requestAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        saveSourceURL(address)
        if restoreRemovedSites {
            removedSiteKeys = []
            UserDefaults.standard.removeObject(forKey: Self.removedSitesKey(for: requestAddress))
        } else {
            removedSiteKeys = Set(UserDefaults.standard.stringArray(forKey: Self.removedSitesKey(for: requestAddress)) ?? [])
        }
        selectedSiteKey = UserDefaults.standard.string(forKey: Self.siteKey(for: requestAddress))
            ?? (previousAddress == requestAddress ? (UserDefaults.standard.string(forKey: "tvbox.selectedSite") ?? "") : "")
        selectedParserName = UserDefaults.standard.string(forKey: Self.parserKey(for: requestAddress))
            ?? (previousAddress == requestAddress ? (UserDefaults.standard.string(forKey: "tvbox.selectedParser") ?? "") : "")
        configuration = nil
        categories = []
        items = []
        configurationTask?.cancel()
        contentTask?.cancel()
        invalidateLiveLoad()
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        loadMessage = nil

        configurationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (loaded, data) = try await service.loadConfiguration(from: requestAddress)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                invalidateLiveLoad()
                configuration = loaded
                if !loaded.parsers.contains(where: { $0.name == self.selectedParserName }) {
                    selectParser("")
                }
                UserDefaults.standard.set(data, forKey: Self.configurationKey(for: requestAddress))
                if !availableSites.contains(where: { $0.key == self.selectedSiteKey }) {
                    selectedSiteKey = availableSites.first?.key ?? ""
                }
                UserDefaults.standard.set(selectedSiteKey, forKey: "tvbox.selectedSite")
                UserDefaults.standard.set(selectedSiteKey, forKey: Self.siteKey(for: requestAddress))
                liveGroups = loaded.liveGroups
                hasLoadedLive = false
                loadMessage = "已载入 tvbox.json：\(loaded.sites.count) 个 API 站点\(loaded.unsupportedSpiderCount > 0 ? "；已跳过 \(loaded.unsupportedSpiderCount) 个 Spider" : "")."
                await loadSiteData(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard generation == requestGeneration else { return }
                loadMessage = error.localizedDescription
                let cachedConfiguration = UserDefaults.standard.data(forKey: Self.configurationKey(for: requestAddress))
                if configuration == nil,
                   let cached = cachedConfiguration,
                   let fallback = try? TVBoxConfiguration(data: cached) {
                    invalidateLiveLoad()
                    configuration = fallback
                    if !fallback.parsers.contains(where: { $0.name == self.selectedParserName }) {
                        selectParser("")
                    }
                    liveGroups = fallback.liveGroups
                    if !availableSites.contains(where: { $0.key == self.selectedSiteKey }) {
                        selectedSiteKey = availableSites.first?.key ?? ""
                    }
                    loadMessage = "配置拉取失败，已使用上次保存的 tvbox.json。\n\(error.localizedDescription)"
                    await loadSiteData(generation: generation)
                }
            }
            if generation == requestGeneration { isLoading = false }
        }
    }

    func selectSite(_ key: String) {
        guard availableSites.contains(where: { $0.key == key }) else { return }
        selectedSiteKey = key
        UserDefaults.standard.set(key, forKey: "tvbox.selectedSite")
        UserDefaults.standard.set(key, forKey: Self.siteKey(for: sourceURL))
        searchQuery = ""
        isSearchingAllSites = false
        globalSearchResults = []
        selectedFilters = [:]
        requestGeneration += 1
        let generation = requestGeneration
        contentTask?.cancel()
        isLoading = true
        contentTask = Task { [weak self] in
            await self?.loadSiteData(generation: generation)
        }
    }

    func removeSelectedSite() {
        guard let site = selectedSite, !sourceURL.isEmpty else { return }
        removedSiteKeys.insert(site.key)
        UserDefaults.standard.set(removedSiteKeys.sorted(), forKey: Self.removedSitesKey(for: sourceURL))

        if let nextSite = availableSites.first {
            selectSite(nextSite.key)
            return
        }

        selectedSiteKey = ""
        UserDefaults.standard.set("", forKey: "tvbox.selectedSite")
        UserDefaults.standard.set("", forKey: Self.siteKey(for: sourceURL))
        requestGeneration += 1
        contentTask?.cancel()
        contentTask = nil
        categories = []
        selectedCategoryID = ""
        items = []
        isLoading = false
        isSearching = false
        isSearchingAllSites = false
        canLoadMore = false
        globalSearchResults = []
        globalSearchSites = []
        globalSearchPageBySite = [:]
        globalSearchPageCountBySite = [:]
        selectedFilters = [:]
        loadMessage = "此配置的所有视频源已移除；重新载入配置可恢复。"
    }

    func selectCategory(_ categoryID: String) {
        selectedCategoryID = categoryID
        selectedFilters = [:]
        searchQuery = ""
        isSearchingAllSites = false
        globalSearchResults = []
        loadCurrentCategory(reset: true)
    }

    func setFilter(_ key: String, value: String) {
        searchQuery = ""
        isSearchingAllSites = false
        globalSearchResults = []
        if value.isEmpty { selectedFilters.removeValue(forKey: key) }
        else { selectedFilters[key] = value }
        loadCurrentCategory(reset: true)
    }

    func search(_ query: String, acrossAllSites: Bool = false) {
        searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty, let site = selectedSite else {
            isSearching = false
            isSearchingAllSites = false
            globalSearchResults = []
            loadCurrentCategory(reset: true)
            return
        }
        rememberSearch(searchQuery)
        requestGeneration += 1
        let generation = requestGeneration
        let query = searchQuery
        contentTask?.cancel()
        isLoading = true
        isSearching = true
        if acrossAllSites, let configuration {
            let sites = availableSites.filter(\.searchable)
            globalSearchSites = sites
            globalSearchPageBySite = [:]
            globalSearchPageCountBySite = [:]
            isSearchingAllSites = true
            globalSearchResults = []
            guard !sites.isEmpty else {
                items = []
                loadMessage = "tvbox.json 没有启用搜索的站点。"
                isLoading = false
                return
            }
            contentTask = Task { [weak self] in
                await self?.loadAllSearchResults(query: query, sites: sites, generation: generation)
            }
            return
        }
        isSearchingAllSites = false
        globalSearchResults = []
        contentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.search(for: site, query: query)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                items = scoped(result.items)
                currentPage = result.page
                pageCount = result.pageCount
                canLoadMore = currentPage < pageCount
                loadMessage = "搜索到 \(result.total > 0 ? result.total : result.items.count) 个结果。"
            } catch {
                guard generation == requestGeneration else { return }
                items = []
                loadMessage = error.localizedDescription
            }
            if generation == requestGeneration { isLoading = false }
        }
    }

    func loadMoreIfNeeded(current item: MediaItem) {
        guard item.id == items.last?.id, canLoadMore, !isLoading else { return }
        if !searchQuery.isEmpty {
            loadMoreSearchResults()
        } else {
            loadCurrentCategory(reset: false)
        }
    }

    func detail(for item: MediaItem) async -> MediaItem {
        let configurationAddress = item.sourceConfigurationURL ?? sourceURL
        guard await selectConfiguration(for: item),
              sourceURL == configurationAddress,
              let configuration,
              let site = configuration.sites.first(where: { $0.key == item.sourceKey }) else { return item }
        do { return try await service.detail(for: item, site: site).withSourceConfigurationURL(configurationAddress) }
        catch {
            loadMessage = error.localizedDescription
            return item
        }
    }

    func playbackRequest(
        for item: MediaItem,
        episode: Episode,
        queue requestedQueue: [Episode] = [],
        queueIndex requestedIndex: Int? = nil,
        parserName: String? = nil
    ) async throws -> PlaybackRequest {
        guard await selectConfiguration(for: item) else {
            throw CatalogService.CatalogError.noPlayableURL
        }
        let selectedConfiguration = configuration
        if let itemAddress = item.sourceConfigurationURL, sourceURL != itemAddress {
            throw CatalogService.CatalogError.noPlayableURL
        }
        let site = selectedConfiguration?.sites.first { $0.key == item.sourceKey }
        let resolution: PlaybackResolution
        if let site, let configuration = selectedConfiguration {
            resolution = try await service.resolve(
                item: item,
                episode: episode,
                site: site,
                configuration: configuration,
                parserName: parserName ?? selectedParserName
            )
        } else if item.sourceConfigurationURL != nil {
            throw CatalogService.CatalogError.noPlayableURL
        } else if let url = URL(string: episode.address), ["http", "https", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "") {
            resolution = PlaybackResolution(url: url, headers: episode.headers)
        } else {
            throw CatalogService.CatalogError.noPlayableURL
        }
        let queue = requestedQueue.isEmpty ? [episode] : requestedQueue
        let index = requestedIndex ?? queue.firstIndex(where: { $0.id == episode.id }) ?? 0
        markPlayed(item, episode: episode)
        return PlaybackRequest(
            title: "\(item.title) · \(episode.title)",
            url: resolution.url,
            headers: resolution.headers,
            itemID: item.id,
            siteKey: item.sourceKey,
            episodeID: episode.id,
            resumeMilliseconds: resumePosition(itemID: item.id, episodeID: episode.id),
            item: item,
            queue: queue,
            queueIndex: index,
            skipOpeningMilliseconds: UserDefaults.standard.integer(forKey: "tvbox.skipOpeningSeconds") * 1_000,
            availableLines: item.lines,
            lineID: item.lines.first(where: { $0.episodes.contains(where: { $0.id == episode.id }) })?.id,
            danmakuSource: resolution.danmakuSource ?? episode.danmakuSource
        )
    }

    func loadLive() {
        guard !hasLoadedLive, !isLoadingLive, let configuration else { return }
        liveGeneration += 1
        let generation = liveGeneration
        isLoadingLive = true
        liveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loadedGroups = try await service.loadLiveGroups(for: configuration)
                guard !Task.isCancelled, generation == liveGeneration else { return }
                liveGroups = loadedGroups
                hasLoadedLive = true
                loadMessage = liveGroups.isEmpty ? "tvbox.json 没有可用的直播频道。" : "已载入 \(liveGroups.reduce(0) { $0 + $1.channels.count }) 个直播频道。"
            } catch is CancellationError {
                return
            } catch {
                guard generation == liveGeneration else { return }
                loadMessage = error.localizedDescription
            }
            if generation == liveGeneration { isLoadingLive = false }
        }
    }

    func restoreSamples() {
        configurationTask?.cancel()
        contentTask?.cancel()
        invalidateLiveLoad()
        requestGeneration += 1
        sourceURL = ""
        selectedSiteKey = ""
        removedSiteKeys = []
        selectParser("")
        configuration = nil
        categories = []
        selectedCategoryID = ""
        liveGroups = []
        hasLoadedLive = false
        items = SampleCatalog.items
        isLoading = false
        isSearching = false
        canLoadMore = false
        isLoadingLive = false
        searchQuery = ""
        isSearchingAllSites = false
        globalSearchResults = []
        globalSearchSites = []
        globalSearchPageBySite = [:]
        globalSearchPageCountBySite = [:]
        selectedFilters = [:]
        currentPage = 1
        pageCount = 1
        loadMessage = "已恢复内置演示目录。"
        UserDefaults.standard.removeObject(forKey: "tvbox.sourceURL")
        UserDefaults.standard.removeObject(forKey: "tvbox.cachedConfiguration")
        UserDefaults.standard.removeObject(forKey: "tvbox.selectedSite")
    }

    private func loadSiteData(generation: Int) async {
        guard let site = selectedSite else {
            isLoading = false
            return
        }
        do {
            let response = try await service.loadCategories(for: site)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            let all = TVBoxCategory(id: "", name: "全部", flag: "", filters: [])
            categories = [all] + response.categories
            selectedCategoryID = ""
            currentPage = 1
            pageCount = 1
            if !response.featuredItems.isEmpty {
                items = scoped(response.featuredItems)
                canLoadMore = false
            } else if !response.categories.isEmpty {
                let first = response.categories[0]
                selectedCategoryID = first.id
                let page = try await service.loadPage(for: site, category: first, page: 1)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                items = scoped(page.items)
                currentPage = page.page
                pageCount = page.pageCount
                canLoadMore = page.page < page.pageCount
            } else {
                items = []
                canLoadMore = false
            }
            isSearching = false
            isSearchingAllSites = false
            loadMessage = "\(site.name)：\(items.count) 个条目。"
        } catch {
            guard generation == requestGeneration else { return }
            items = []
            loadMessage = error.localizedDescription
        }
        if generation == requestGeneration { isLoading = false }
    }

    private func loadCurrentCategory(reset: Bool) {
        guard let site = selectedSite else { return }
        if reset {
            currentPage = 1
            items = []
            canLoadMore = false
        }
        let requestedPage = reset ? 1 : currentPage + 1
        requestGeneration += 1
        let generation = requestGeneration
        contentTask?.cancel()
        isLoading = true
        isSearching = false
        let category = selectedCategory
        let filters = selectedFilters
        contentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.loadPage(for: site, category: category, page: requestedPage, filters: filters)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                if reset { items = scoped(result.items) }
                else {
                    let existing = Set(items.map(\.id))
                    items.append(contentsOf: scoped(result.items).filter { !existing.contains($0.id) })
                }
                currentPage = requestedPage
                pageCount = result.pageCount
                canLoadMore = requestedPage < result.pageCount && !result.items.isEmpty
                loadMessage = "\(site.name)：\(items.count) 个条目。"
            } catch {
                guard generation == requestGeneration else { return }
                if reset { items = [] }
                loadMessage = error.localizedDescription
            }
            if generation == requestGeneration { isLoading = false }
        }
    }

    private func loadMoreSearchResults() {
        if isSearchingAllSites {
            loadMoreAllSearchResults()
            return
        }
        guard let site = selectedSite, !searchQuery.isEmpty else { return }
        requestGeneration += 1
        let generation = requestGeneration
        let requestedPage = currentPage + 1
        let query = searchQuery
        contentTask?.cancel()
        isLoading = true
        contentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.search(for: site, query: query, page: requestedPage)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                var knownIDs = Set(items.map(\.id))
                items.append(contentsOf: scoped(result.items).filter { knownIDs.insert($0.id).inserted })
                currentPage = requestedPage
                pageCount = result.pageCount
                canLoadMore = requestedPage < result.pageCount && !result.items.isEmpty
                loadMessage = "搜索到 \(result.total > 0 ? result.total : items.count) 个结果。"
            } catch {
                guard generation == requestGeneration else { return }
                loadMessage = error.localizedDescription
            }
            if generation == requestGeneration { isLoading = false }
        }
    }

    private func loadAllSearchResults(query: String, sites: [TVBoxSite], generation: Int) async {
        let service = self.service
        let indexedPages = await withTaskGroup(of: (Int, TVBoxPage?).self, returning: [TVBoxPage?].self) { group in
            for (index, site) in sites.enumerated() {
                group.addTask {
                    (index, try? await service.search(for: site, query: query))
                }
            }
            var pages = Array<TVBoxPage?>(repeating: nil, count: sites.count)
            for await (index, page) in group { pages[index] = page }
            return pages
        }
        guard !Task.isCancelled, generation == requestGeneration else { return }

        var results: [MediaItem] = []
        var failedCount = 0
        for (index, page) in indexedPages.enumerated() {
            guard let page else { failedCount += 1; continue }
            let site = sites[index]
            globalSearchPageBySite[site.key] = max(1, page.page)
            globalSearchPageCountBySite[site.key] = max(page.page, page.pageCount)
            results.append(contentsOf: scoped(page.items))
        }
        items = results
        globalSearchResults = results
        canLoadMore = globalSearchSites.contains {
            (globalSearchPageBySite[$0.key] ?? 1) < (globalSearchPageCountBySite[$0.key] ?? 1)
        }
        loadMessage = failedCount == sites.count
            ? "所有可搜索站点都没有响应。"
            : "全站搜索到 \(results.count) 个结果\(failedCount > 0 ? "；\(failedCount) 个站点请求失败" : "")。"
        if generation == requestGeneration { isLoading = false }
    }

    private func loadMoreAllSearchResults() {
        guard !searchQuery.isEmpty else { return }
        let pending = globalSearchSites.compactMap { site -> (TVBoxSite, Int)? in
            let nextPage = (globalSearchPageBySite[site.key] ?? 1) + 1
            guard nextPage <= (globalSearchPageCountBySite[site.key] ?? 1) else { return nil }
            return (site, nextPage)
        }
        guard !pending.isEmpty else { canLoadMore = false; return }
        requestGeneration += 1
        let generation = requestGeneration
        let query = searchQuery
        let service = self.service
        contentTask?.cancel()
        isLoading = true
        contentTask = Task { [weak self] in
            let pages = await withTaskGroup(of: (String, Int, TVBoxPage?).self, returning: [(String, Int, TVBoxPage?)].self) { group in
                for (site, nextPage) in pending {
                    group.addTask {
                        (site.key, nextPage, try? await service.search(for: site, query: query, page: nextPage))
                    }
                }
                var values: [(String, Int, TVBoxPage?)] = []
                for await value in group { values.append(value) }
                return values
            }
            guard let self, !Task.isCancelled, generation == self.requestGeneration else { return }
            var knownIDs = Set(self.items.map(\.id))
            for (siteKey, requestedPage, page) in pages {
                guard let page else { continue }
                self.globalSearchPageBySite[siteKey] = max(requestedPage, page.page)
                self.globalSearchPageCountBySite[siteKey] = max(page.page, page.pageCount)
                self.items.append(contentsOf: self.scoped(page.items).filter { knownIDs.insert($0.id).inserted })
            }
            self.globalSearchResults = self.items
            self.canLoadMore = self.globalSearchSites.contains {
                (self.globalSearchPageBySite[$0.key] ?? 1) < (self.globalSearchPageCountBySite[$0.key] ?? 1)
            }
            self.loadMessage = "全站搜索到 \(self.items.count) 个结果。"
            if generation == self.requestGeneration { self.isLoading = false }
        }
    }

    private func rememberSearch(_ query: String) {
        recentSearches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        recentSearches.insert(query, at: 0)
        recentSearches = Array(recentSearches.prefix(12))
        UserDefaults.standard.set(recentSearches, forKey: "tvbox.recentSearches")
    }

    private static func normalizedTitle(_ title: String) -> String {
        String(title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber })
    }

    private func scoped(_ items: [MediaItem]) -> [MediaItem] {
        items.map { $0.withSourceConfigurationURL(sourceURL) }
    }

    private func selectConfiguration(for item: MediaItem) async -> Bool {
        guard let address = item.sourceConfigurationURL,
              !address.isEmpty else { return true }
        if address != sourceURL || configuration == nil {
            if address != sourceURL {
                await loadConfiguration(from: address)
            }
            let task = configurationTask
            await task?.value
        }
        return sourceURL == address && configuration != nil
    }

    private static func storageSuffix(for address: String) -> String {
        SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func configurationKey(for address: String) -> String {
        "tvbox.cachedConfiguration.\(storageSuffix(for: address))"
    }

    private static func siteKey(for address: String) -> String {
        "tvbox.selectedSite.\(storageSuffix(for: address))"
    }

    private static func removedSitesKey(for address: String) -> String {
        "tvbox.removedSites.\(storageSuffix(for: address))"
    }

    private static func parserKey(for address: String) -> String {
        "tvbox.selectedParser.\(storageSuffix(for: address))"
    }

    private func invalidateLiveLoad() {
        liveTask?.cancel()
        liveTask = nil
        liveGeneration += 1
        isLoadingLive = false
        hasLoadedLive = false
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
