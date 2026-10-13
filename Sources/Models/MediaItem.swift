import Foundation

struct TVBoxConfiguration: Hashable {
    let sites: [TVBoxSite]
    let parsers: [TVBoxParser]
    let liveGroups: [TVBoxLiveGroup]
    let liveURLs: [String]
    let epgURL: String
    let liveHeaderRules: [TVBoxLiveHeaderRule]
    let wallpaperURL: URL?
    let flags: [String]
    let unsupportedSpiderCount: Int

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TVBoxConfigurationError.invalidRoot
        }

        let video = root["video"] as? [String: Any]
        let rawSites = (video?["sites"] as? [[String: Any]]) ?? (root["sites"] as? [[String: Any]]) ?? []
        guard !rawSites.isEmpty else { throw TVBoxConfigurationError.noSites }

        let parsedSites = rawSites.compactMap(TVBoxSite.init(json:))
        let spiderCount = parsedSites.filter { $0.type == 3 }.count
        unsupportedSpiderCount = spiderCount
        sites = parsedSites.filter { [0, 1, 4].contains($0.type) && $0.hide == 0 }
        guard !sites.isEmpty else {
            throw TVBoxConfigurationError.noSupportedSites(spiderCount: spiderCount)
        }

        parsers = (root["parses"] as? [[String: Any]] ?? []).compactMap(TVBoxParser.init(json:))
        flags = (root["flags"] as? [Any] ?? []).map { tvboxString($0) }.filter { !$0.isEmpty }

        let rawLives = root["lives"] as? [[String: Any]] ?? []
        liveGroups = rawLives.flatMap { TVBoxLiveGroup.decode(from: $0) }
        liveURLs = rawLives.map { tvboxString($0["url"]) }.filter { !$0.isEmpty }
        epgURL = rawLives.compactMap { value -> String? in
            let url = tvboxString(value["epg"])
            return url.isEmpty ? nil : url
        }.first ?? ""
        liveHeaderRules = (root["livePlayHeaders"] as? [[String: Any]] ?? []).compactMap(TVBoxLiveHeaderRule.init(json:))
        let wallpaper = tvboxString(root["wallpaper"])
        wallpaperURL = URL(string: wallpaper)
    }

    func liveHeaders(for address: String) -> [String: String] {
        liveHeaderRules.first(where: { rule in rule.flags.contains(where: { address.localizedCaseInsensitiveContains($0) }) })?.headers ?? [:]
    }
}

enum TVBoxConfigurationError: LocalizedError {
    case invalidRoot
    case noSites
    case noSupportedSites(spiderCount: Int)

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "tvbox.json 顶层必须是 JSON 对象。"
        case .noSites:
            return "tvbox.json 中没有找到 sites 或 video.sites。"
        case .noSupportedSites(let spiderCount):
            return spiderCount > 0
                ? "配置里只有 Spider 站点；当前版本暂不加载 Spider。"
                : "配置里没有可用的 XML 或 JSON API 站点。"
        }
    }
}

struct TVBoxSite: Identifiable, Hashable {
    let key: String
    let name: String
    let type: Int
    let api: String
    let searchable: Bool
    let quickSearch: Bool
    let filterable: Bool
    let hide: Int
    let playURL: String
    let ext: String
    let categories: [String]
    let playerType: Int

    var id: String { key }

    fileprivate init?(json: [String: Any]) {
        key = tvboxString(json["key"]).trimmingCharacters(in: .whitespacesAndNewlines)
        api = tvboxString(json["api"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !api.isEmpty else { return nil }
        type = tvboxInt(json["type"], default: -1)
        name = tvboxString(json["name"], default: key)
        searchable = tvboxInt(json["searchable"], default: 1) != 0
        quickSearch = tvboxInt(json["quickSearch"], default: 1) != 0
        filterable = tvboxInt(json["filterable"], default: 1) != 0
        hide = tvboxInt(json["hide"], default: 0)
        playURL = tvboxString(json["playUrl"])
        ext = tvboxJSONValue(json["ext"])
        categories = (json["categories"] as? [Any] ?? []).map { tvboxString($0) }
        playerType = tvboxInt(json["playerType"], default: -1)
    }
}

struct TVBoxParser: Identifiable, Hashable {
    let name: String
    let url: String
    let type: Int
    let ext: String

    var id: String { name }

    init(name: String, url: String, type: Int, ext: String) {
        self.name = name
        self.url = url
        self.type = type
        self.ext = ext
    }

    fileprivate init?(json: [String: Any]) {
        name = tvboxString(json["name"])
        url = tvboxString(json["url"])
        guard !name.isEmpty, !url.isEmpty else { return nil }
        type = tvboxInt(json["type"], default: 0)
        ext = tvboxJSONValue(json["ext"])
    }
}

struct TVBoxCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let flag: String
    var filters: [TVBoxFilter]
}

struct TVBoxFilter: Identifiable, Hashable {
    let key: String
    let name: String
    let options: [TVBoxFilterOption]

    var id: String { key }
}

struct TVBoxFilterOption: Identifiable, Hashable {
    let title: String
    let value: String

    var id: String { "\(title)|\(value)" }
}

struct TVBoxLiveGroup: Identifiable, Hashable {
    let name: String
    let password: String
    let channels: [TVBoxLiveChannel]

    var id: String { name }

    init(name: String, password: String = "", channels: [TVBoxLiveChannel]) {
        self.name = name
        self.password = password
        self.channels = channels
    }

    fileprivate static func decode(from object: [String: Any]) -> [TVBoxLiveGroup] {
        guard let rawChannels = object["channels"] as? [[String: Any]] else { return [] }
        let rawGroup = tvboxString(object["group"], default: "直播")
        let groupParts = rawGroup.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        let groupName = groupParts.first.map(String.init) ?? "直播"
        let password = groupParts.count > 1 ? String(groupParts[1]) : ""
        let channels = rawChannels.compactMap(TVBoxLiveChannel.init(json:))
        return channels.isEmpty ? [] : [TVBoxLiveGroup(name: groupName, password: password, channels: channels)]
    }
}

struct TVBoxLiveHeaderRule: Hashable {
    let flags: [String]
    let headers: [String: String]

    fileprivate init?(json: [String: Any]) {
        flags = (json["flag"] as? [Any] ?? []).map { tvboxString($0) }.filter { !$0.isEmpty }
        headers = (json["header"] as? [String: Any] ?? [:]).mapValues { tvboxString($0) }
        guard !flags.isEmpty, !headers.isEmpty else { return nil }
    }
}

struct TVBoxEPGProgram: Identifiable, Hashable {
    let title: String
    let start: String
    let end: String

    var id: String { "\(start)|\(end)|\(title)" }

    func interval(on date: Date) -> (start: Date, end: Date)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let day = formatter.string(from: date).components(separatedBy: " ").first ?? ""
        guard let startDate = formatter.date(from: "\(day) \(start)"),
              var endDate = formatter.date(from: "\(day) \(end)") else { return nil }
        if endDate < startDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        }
        return (startDate, endDate)
    }
}

struct TVBoxLiveChannel: Identifiable, Hashable {
    let name: String
    let sources: [TVBoxLiveSource]
    let catchupSources: [String]
    let logoURL: URL?

    var id: String { name }

    init(name: String, sources: [TVBoxLiveSource], catchupSources: [String] = [], logoURL: URL? = nil) {
        self.name = name
        self.sources = sources
        self.catchupSources = catchupSources
        self.logoURL = logoURL
    }

    fileprivate init?(json: [String: Any]) {
        name = tvboxString(json["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let rawSources = (json["urls"] as? [Any] ?? []).map { tvboxString($0) }
        sources = rawSources.enumerated().compactMap { index, raw in
            let pieces = raw.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
            guard let address = pieces.first, !address.isEmpty else { return nil }
            let sourceName = pieces.count > 1 && !pieces[1].isEmpty ? String(pieces[1]) : "线路\(index + 1)"
            return TVBoxLiveSource(name: sourceName, address: String(address))
        }
        catchupSources = (json["catchupSources"] as? [Any] ?? []).map { tvboxString($0) }
        let logo = tvboxString(json["logo"] ?? json["tvg-logo"])
        logoURL = URL(string: logo)
    }
}

struct TVBoxLiveSource: Identifiable, Hashable {
    let name: String
    let address: String
    let headers: [String: String]

    var id: String { "\(name)|\(address)" }

    init(name: String, address: String, headers: [String: String] = [:]) {
        self.name = name
        self.address = address
        self.headers = headers
    }
}

struct PlaybackLine: Identifiable, Hashable, Codable {
    let flag: String
    var episodes: [Episode]

    var id: String { flag }
}

struct MediaItem: Identifiable, Hashable, Codable {
    let id: String
    let sourceKey: String
    let sourceConfigurationURL: String?
    let sourceName: String
    let vodID: String
    let title: String
    let category: String
    let subtitle: String
    let summary: String
    let year: String
    let area: String
    let language: String
    let actor: String
    let director: String
    let remarks: String
    let posterURL: URL?
    let lines: [PlaybackLine]

    var episodes: [Episode] { lines.flatMap(\.episodes) }

    init(
        sourceKey: String,
        sourceName: String,
        vodID: String,
        title: String,
        sourceConfigurationURL: String? = nil,
        category: String = "",
        subtitle: String = "",
        summary: String = "",
        year: String = "",
        area: String = "",
        language: String = "",
        actor: String = "",
        director: String = "",
        remarks: String = "",
        posterURL: URL? = nil,
        lines: [PlaybackLine] = []
    ) {
        self.sourceKey = sourceKey
        self.sourceConfigurationURL = sourceConfigurationURL
        self.sourceName = sourceName
        self.vodID = vodID
        self.id = sourceConfigurationURL.map { "\(sourceKey)::\(vodID)::\($0)" } ?? "\(sourceKey)::\(vodID)"
        self.title = title
        self.category = category
        self.subtitle = subtitle
        self.summary = summary
        self.year = year
        self.area = area
        self.language = language
        self.actor = actor
        self.director = director
        self.remarks = remarks
        self.posterURL = posterURL
        self.lines = lines
    }

    init(id: String, title: String, category: String, subtitle: String, summary: String, posterURL: URL?, episodes: [Episode]) {
        self.init(
            sourceKey: "demo",
            sourceName: "演示",
            vodID: id,
            title: title,
            category: category,
            subtitle: subtitle,
            summary: summary,
            posterURL: posterURL,
            lines: [PlaybackLine(flag: "演示线路", episodes: episodes)]
        )
    }

    func withSourceConfigurationURL(_ address: String) -> MediaItem {
        MediaItem(
            sourceKey: sourceKey,
            sourceName: sourceName,
            vodID: vodID,
            title: title,
            sourceConfigurationURL: address,
            category: category,
            subtitle: subtitle,
            summary: summary,
            year: year,
            area: area,
            language: language,
            actor: actor,
            director: director,
            remarks: remarks,
            posterURL: posterURL,
            lines: lines
        )
    }
}

struct Episode: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let address: String
    let flag: String
    let headers: [String: String]
    let danmakuSource: String?

    var url: URL? { URL(string: address) }

    init(id: String, title: String, address: String, flag: String, headers: [String: String] = [:], danmakuSource: String? = nil) {
        self.id = id
        self.title = title
        self.address = address
        self.flag = flag
        self.headers = headers
        self.danmakuSource = danmakuSource
    }

    init(id: String, title: String, url: URL, headers: [String: String] = [:], danmakuSource: String? = nil) {
        self.init(id: id, title: title, address: url.absoluteString, flag: "演示线路", headers: headers, danmakuSource: danmakuSource)
    }
}

struct PlaybackHistory: Identifiable, Hashable, Codable {
    var id: String { item.id }
    var item: MediaItem
    var episodeID: String
    var positionMilliseconds: Int
    var updatedAt: Date
}

struct LivePlaybackContext {
    let groups: [TVBoxLiveGroup]
    let groupID: String
    let channelID: String
    let sourceID: String
    let epgURL: String
    let headerRules: [TVBoxLiveHeaderRule]

    var currentGroup: TVBoxLiveGroup? { groups.first { $0.id == groupID } }
    var currentChannel: TVBoxLiveChannel? { currentGroup?.channels.first { $0.id == channelID } }
    var currentSource: TVBoxLiveSource? { currentChannel?.sources.first { $0.id == sourceID } ?? currentChannel?.sources.first }

    func headers(for address: String) -> [String: String] {
        headerRules.first { rule in rule.flags.contains { address.localizedCaseInsensitiveContains($0) } }?.headers ?? [:]
    }

    func selecting(groupID: String, channelID: String, sourceID: String) -> LivePlaybackContext {
        LivePlaybackContext(
            groups: groups,
            groupID: groupID,
            channelID: channelID,
            sourceID: sourceID,
            epgURL: epgURL,
            headerRules: headerRules
        )
    }

    func request(groupID: String, channelID: String, sourceID: String, title: String? = nil, url overrideURL: URL? = nil, isLive: Bool = true) -> PlaybackRequest? {
        guard let group = groups.first(where: { $0.id == groupID }),
              let channel = group.channels.first(where: { $0.id == channelID }),
              let source = channel.sources.first(where: { $0.id == sourceID }) ?? channel.sources.first,
              let url = overrideURL ?? URL(string: source.address),
              ["http", "https", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "") else { return nil }

        let queue = groups.flatMap { value in
            value.channels.compactMap { candidate -> Episode? in
                guard let primarySource = candidate.sources.first(where: { source in
                    guard let sourceURL = URL(string: source.address) else { return false }
                    return ["http", "https", "rtsp", "rtmp"].contains(sourceURL.scheme?.lowercased() ?? "")
                }) else { return nil }
                return Episode(
                    id: "live::\(value.id)::\(candidate.id)",
                    title: "\(value.name) · \(candidate.name)",
                    address: primarySource.address,
                    flag: "直播",
                    headers: primarySource.headers.merging(headers(for: primarySource.address)) { _, rule in rule }
                )
            }
        }
        let episodeID = "live::\(group.id)::\(channel.id)"
        let queueIndex = queue.firstIndex(where: { $0.id == episodeID }) ?? 0
        let selectedContext = selecting(groupID: group.id, channelID: channel.id, sourceID: source.id)
        return PlaybackRequest(
            title: title ?? "\(channel.name) · \(source.name)",
            url: url,
            headers: source.headers.merging(headers(for: source.address)) { _, rule in rule },
            queue: queue,
            queueIndex: queueIndex,
            isLive: isLive,
            liveContext: selectedContext
        )
    }
}

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let headers: [String: String]
    let itemID: String?
    let siteKey: String?
    let episodeID: String?
    let resumeMilliseconds: Int
    let item: MediaItem?
    let queue: [Episode]
    let queueIndex: Int
    let isLive: Bool
    let skipOpeningMilliseconds: Int
    let availableLines: [PlaybackLine]
    let lineID: String?
    let danmakuSource: String?
    let liveContext: LivePlaybackContext?

    init(
        title: String,
        url: URL,
        headers: [String: String] = [:],
        itemID: String? = nil,
        siteKey: String? = nil,
        episodeID: String? = nil,
        resumeMilliseconds: Int = 0,
        item: MediaItem? = nil,
        queue: [Episode] = [],
        queueIndex: Int = 0,
        isLive: Bool = false,
        skipOpeningMilliseconds: Int = 0,
        availableLines: [PlaybackLine] = [],
        lineID: String? = nil,
        danmakuSource: String? = nil,
        liveContext: LivePlaybackContext? = nil
    ) {
        self.title = title
        self.url = url
        self.headers = headers
        self.itemID = itemID
        self.siteKey = siteKey
        self.episodeID = episodeID
        self.resumeMilliseconds = resumeMilliseconds
        self.item = item
        self.queue = queue
        self.queueIndex = queueIndex
        self.isLive = isLive
        self.skipOpeningMilliseconds = skipOpeningMilliseconds
        self.availableLines = availableLines
        self.lineID = lineID
        self.danmakuSource = danmakuSource
        self.liveContext = liveContext
    }
}

struct PlaybackResolution {
    let url: URL
    let headers: [String: String]
    let danmakuSource: String?

    init(url: URL, headers: [String: String], danmakuSource: String? = nil) {
        self.url = url
        self.headers = headers
        self.danmakuSource = danmakuSource
    }
}

private func tvboxString(_ value: Any?, default fallback: String = "") -> String {
    guard let value, !(value is NSNull) else { return fallback }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return fallback
}

private func tvboxInt(_ value: Any?, default fallback: Int) -> Int {
    guard let value, !(value is NSNull) else { return fallback }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String, let number = Int(string) { return number }
    return fallback
}

private func tvboxJSONValue(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    if let string = value as? String { return string }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let string = String(data: data, encoding: .utf8) else { return "" }
    return string
}
