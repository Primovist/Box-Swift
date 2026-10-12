import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct TVBoxCategoryResponse {
    let categories: [TVBoxCategory]
    let featuredItems: [MediaItem]
}

struct TVBoxPage {
    let items: [MediaItem]
    let page: Int
    let pageCount: Int
    let total: Int
}

struct CatalogService {
    enum CatalogError: LocalizedError {
        case invalidURL
        case badResponse(Int)
        case malformedJSON
        case unsupportedSiteType(Int)
        case unsupportedParserType(Int)
        case noPlayableURL
        case webParserUnavailable
        case noJSONParser

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "请输入有效的 HTTP 或 HTTPS 地址。"
            case .badResponse(let status):
                return "服务器返回 HTTP \(status)。"
            case .malformedJSON:
                return "服务器返回的数据不是可识别的 TVBox JSON/XML。"
            case .unsupportedSiteType(let type):
                return "暂不支持此站点类型（type=\(type)）；当前支持 0、1、4。"
            case .unsupportedParserType(let type):
                return "暂不支持此解析器类型（type=\(type)）；当前支持网页静态地址提取和 JSON 解析。"
            case .noPlayableURL:
                return "没有解析到可播放的媒体地址。"
            case .webParserUnavailable:
                return "该地址需要动态网页嗅探；当前版本只提取静态页面中的媒体地址。"
            case .noJSONParser:
                return "此播放地址需要解析，但 tvbox.json 没有可用的解析器。"
            }
        }
    }

    func loadConfiguration(from address: String) async throws -> (TVBoxConfiguration, Data) {
        let data = try await requestData(address)
        return (try TVBoxConfiguration(data: data), data)
    }

    func loadCategories(for site: TVBoxSite) async throws -> TVBoxCategoryResponse {
        switch site.type {
        case 0, 1:
            let data = try await requestData(site.api)
            return try parseCategoryResponse(data, site: site)
        case 4:
            let extend = try await resolvedExtend(site.ext)
            let url = try makeURL(site.api, parameters: ["filter": "true", "extend": extend])
            return try parseCategoryResponse(await requestData(url), site: site)
        default:
            throw CatalogError.unsupportedSiteType(site.type)
        }
    }

    func loadPage(
        for site: TVBoxSite,
        category: TVBoxCategory?,
        page: Int,
        filters: [String: String] = [:]
    ) async throws -> TVBoxPage {
        switch site.type {
        case 0, 1:
            var parameters = [
                "ac": site.type == 0 ? "videolist" : "detail",
                "pg": String(page)
            ]
            if let category { parameters["t"] = category.id }
            for (key, value) in filters { parameters[key] = value }
            parameters["f"] = filters.isEmpty ? "" : jsonString(filters)
            let url = try makeURL(site.api, parameters: parameters)
            return try parsePage(await requestData(url), site: site)
        case 4:
            let encodedFilters = filters.isEmpty ? "" : Data(jsonString(filters).utf8).base64EncodedString()
            var parameters = ["ac": "detail", "filter": "true", "pg": String(page), "ext": encodedFilters]
            if let category { parameters["t"] = category.id }
            let url = try makeURL(site.api, parameters: parameters)
            return try parsePage(await requestData(url), site: site)
        default:
            throw CatalogError.unsupportedSiteType(site.type)
        }
    }

    func search(for site: TVBoxSite, query: String, page: Int = 1, quick: Bool = false) async throws -> TVBoxPage {
        guard site.searchable else { return TVBoxPage(items: [], page: 1, pageCount: 1, total: 0) }
        var parameters = ["wd": query, "pg": String(page)]
        if site.type == 1 || site.type == 4 { parameters["ac"] = "detail" }
        if site.type == 4 { parameters["quick"] = quick ? "true" : "false" }
        guard [0, 1, 4].contains(site.type) else { throw CatalogError.unsupportedSiteType(site.type) }
        let url = try makeURL(site.api, parameters: parameters)
        let data = try await requestData(url)
        return try parsePage(data, site: site)
    }

    func detail(for item: MediaItem, site: TVBoxSite) async throws -> MediaItem {
        guard [0, 1, 4].contains(site.type) else { throw CatalogError.unsupportedSiteType(site.type) }
        var parameters = [
            "ac": site.type == 0 ? "videolist" : "detail",
            "ids": item.vodID
        ]
        if site.type == 4 { parameters["extend"] = try await resolvedExtend(site.ext) }
        let url = try makeURL(site.api, parameters: parameters)
        let data = try await requestData(url)
        return try parsePage(data, site: site).items.first ?? item
    }

    func resolve(
        item: MediaItem,
        episode: Episode,
        site: TVBoxSite,
        configuration: TVBoxConfiguration,
        parserName: String? = nil
    ) async throws -> PlaybackResolution {
        if site.type == 4 {
            let extend = try await resolvedExtend(site.ext)
            let url = try makeURL(site.api, parameters: [
                "play": episode.address,
                "flag": episode.flag,
                "extend": extend
            ])
            let data = try await requestData(url)
            let response = try jsonObject(data)
            let rawAddress = nestedString(response, keys: ["url"])
            guard !rawAddress.isEmpty else { throw CatalogError.noPlayableURL }
            let playURL = nestedString(response, keys: ["playUrl"])
            let headers = responseHeaders(response)
            let rawDanmakuSource = nestedString(response, keys: ["danmaku"])
            let danmakuSource = rawDanmakuSource.isEmpty ? nil : rawDanmakuSource
            let nested = response["data"] as? [String: Any]
            let parse = intValue(response["parse"] ?? nested?["parse"], default: 1)
            let jx = intValue(response["jx"] ?? nested?["jx"], default: 0) != 0

            if parse == 0 && !jx && !playURL.hasPrefix("json:") && !playURL.hasPrefix("parse:") {
                let directAddress: String
                if playURL.contains("{url}") {
                    directAddress = playURL.replacingOccurrences(of: "{url}", with: rawAddress)
                } else {
                    directAddress = playURL + rawAddress
                }
                guard let mediaURL = validURL(directAddress) else { throw CatalogError.noPlayableURL }
                return PlaybackResolution(url: mediaURL, headers: headers, danmakuSource: danmakuSource)
            }

            let explicitParser: TVBoxParser?
            if playURL.hasPrefix("json:") {
                explicitParser = TVBoxParser(name: "站点 JSON 解析", url: String(playURL.dropFirst(5)), type: 1, ext: "")
            } else if playURL.hasPrefix("parse:") {
                let parserName = String(playURL.dropFirst(6))
                explicitParser = configuration.parsers.first { $0.name == parserName }
            } else if jx || playURL.isEmpty {
                explicitParser = nil
            } else {
                explicitParser = TVBoxParser(name: "网页解析", url: playURL, type: 0, ext: "")
            }
            let parsed = try await resolveWithParser(
                address: rawAddress,
                explicitParser: explicitParser,
                configuration: configuration,
                selectedParserName: parserName,
                extraHeaders: headers
            )
            return PlaybackResolution(
                url: parsed.url,
                headers: parsed.headers,
                danmakuSource: danmakuSource ?? parsed.danmakuSource
            )
        }

        guard [0, 1].contains(site.type) else { throw CatalogError.unsupportedSiteType(site.type) }
        let episodeURL = validURL(episode.address) ?? resolvedURL(episode.address, relativeTo: site.api)
        let parserRequiredByFlag = configuration.flags.contains { $0.caseInsensitiveCompare(episode.flag) == .orderedSame }
        if site.playURL.isEmpty, !parserRequiredByFlag, let direct = episodeURL, isLikelyMediaURL(direct) {
            return PlaybackResolution(url: direct, headers: episode.headers)
        }

        let explicitParser: TVBoxParser?
        if site.playURL.hasPrefix("json:") {
            explicitParser = TVBoxParser(name: "站点 JSON 解析", url: String(site.playURL.dropFirst(5)), type: 1, ext: "")
        } else if site.playURL.hasPrefix("parse:") {
            let parserName = String(site.playURL.dropFirst(6))
            explicitParser = configuration.parsers.first { $0.name == parserName }
        } else if site.playURL.isEmpty {
            explicitParser = nil
        } else {
            explicitParser = TVBoxParser(name: "网页解析", url: site.playURL, type: 0, ext: "")
        }
        return try await resolveWithParser(
            address: episode.address,
            explicitParser: explicitParser,
            configuration: configuration,
            selectedParserName: parserName,
            extraHeaders: episode.headers
        )
    }

    func loadLiveGroups(for configuration: TVBoxConfiguration) async throws -> [TVBoxLiveGroup] {
        var groups = configuration.liveGroups
        for address in configuration.liveURLs {
            let text = try await requestText(address)
            for remoteGroup in parseLiveText(text) {
                if let groupIndex = groups.firstIndex(where: { $0.name == remoteGroup.name }) {
                    let existingChannels = groups[groupIndex].channels
                    var mergedChannels = existingChannels
                    for remoteChannel in remoteGroup.channels {
                        if let channelIndex = mergedChannels.firstIndex(where: { $0.name == remoteChannel.name }) {
                            var channel = mergedChannels[channelIndex]
                            var sources = channel.sources
                            var catchup = channel.catchupSources
                            for (index, source) in remoteChannel.sources.enumerated() where !sources.contains(where: { $0.address == source.address }) {
                                sources.append(source)
                                catchup.append(index < remoteChannel.catchupSources.count ? remoteChannel.catchupSources[index] : "")
                            }
                            channel = TVBoxLiveChannel(name: channel.name, sources: sources, catchupSources: catchup, logoURL: channel.logoURL ?? remoteChannel.logoURL)
                            mergedChannels[channelIndex] = channel
                        } else {
                            mergedChannels.append(remoteChannel)
                        }
                    }
                    groups[groupIndex] = TVBoxLiveGroup(
                        name: remoteGroup.name,
                        password: groups[groupIndex].password,
                        channels: mergedChannels
                    )
                } else {
                    groups.append(remoteGroup)
                }
            }
        }
        return groups
    }

    func loadEPG(for channelName: String, template: String, date: Date = Date()) async throws -> [TVBoxEPGProgram] {
        guard !template.isEmpty else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateValue = formatter.string(from: date)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encodedName = channelName.addingPercentEncoding(withAllowedCharacters: allowed) ?? channelName

        let endpoint: String
        if template.contains("{name}") && template.contains("{date}") {
            endpoint = template
                .replacingOccurrences(of: "{name}", with: encodedName)
                .replacingOccurrences(of: "{date}", with: dateValue)
        } else {
            endpoint = try makeURL(template, parameters: ["ch": channelName, "date": dateValue]).absoluteString
        }

        let root = try jsonObject(await requestData(endpoint))
        let nested = root["data"] as? [String: Any]
        let records = (root["epg_data"] as? [[String: Any]]) ?? (nested?["epg_data"] as? [[String: Any]]) ?? []
        return records.compactMap { record in
            let title = valueString(record, keys: ["title", "name"])
            let start = valueString(record, keys: ["start", "startTime"])
            let end = valueString(record, keys: ["end", "endTime"])
            guard !title.isEmpty, !start.isEmpty, !end.isEmpty else { return nil }
            return TVBoxEPGProgram(title: title, start: start, end: end)
        }
    }

    private func parseCategoryResponse(_ data: Data, site: TVBoxSite) throws -> TVBoxCategoryResponse {
        if site.type == 0 {
            let tree = try parseXML(data)
            let classNode = tree.descendants(named: "class").first
            let categories = classNode?.descendants(named: "ty").compactMap { node -> TVBoxCategory? in
                let id = node.attributes["id"] ?? node.attributes["type_id"] ?? ""
                let name = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !name.isEmpty else { return nil }
                return TVBoxCategory(id: id, name: name, flag: node.attributes["flag"] ?? "", filters: [])
            } ?? []
            let items = parseXMLVideos(tree, site: site)
            return TVBoxCategoryResponse(categories: categories, featuredItems: items)
        }

        let root = try jsonObject(data)
        let payload = (root["data"] as? [String: Any]) ?? root
        let rawClasses = payload["class"] as? [[String: Any]] ?? []
        var categories = rawClasses.compactMap { value -> TVBoxCategory? in
            let id = valueString(value, keys: ["type_id", "id"])
            let name = valueString(value, keys: ["type_name", "name"])
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return TVBoxCategory(id: id, name: name, flag: valueString(value, keys: ["type_flag", "flag"]), filters: [])
        }
        if let filters = payload["filters"] as? [String: Any] {
            categories = categories.map { category in
                var updated = category
                updated.filters = parseFilters(filters[category.id])
                return updated
            }
        }
        if !site.categories.isEmpty {
            categories = categories.filter { category in
                site.categories.contains {
                    $0.caseInsensitiveCompare(category.name) == .orderedSame
                        || $0.caseInsensitiveCompare(category.id) == .orderedSame
                }
            }
        }
        let items = parseJSONVideos(payload, site: site)
        return TVBoxCategoryResponse(categories: categories, featuredItems: items)
    }

    private func parsePage(_ data: Data, site: TVBoxSite) throws -> TVBoxPage {
        if site.type == 0 {
            let tree = try parseXML(data)
            let listNode = tree.descendants(named: "list").first
            return TVBoxPage(
                items: parseXMLVideos(tree, site: site),
                page: intValue(listNode?.attributes["page"], default: 1),
                pageCount: intValue(listNode?.attributes["pagecount"], default: 1),
                total: intValue(listNode?.attributes["recordcount"], default: 0)
            )
        }
        let root = try jsonObject(data)
        let payload = (root["data"] as? [String: Any]) ?? root
        return TVBoxPage(
            items: parseJSONVideos(payload, site: site),
            page: intValue(payload["page"], default: 1),
            pageCount: intValue(payload["pagecount"], default: 1),
            total: intValue(payload["total"] ?? payload["recordcount"], default: 0)
        )
    }

    private func parseJSONVideos(_ root: [String: Any], site: TVBoxSite) -> [MediaItem] {
        let records = (root["list"] as? [[String: Any]]) ?? (root["videos"] as? [[String: Any]]) ?? []
        return records.compactMap { value in
            let vodID = valueString(value, keys: ["vod_id", "id"])
            let title = valueString(value, keys: ["vod_name", "name", "title"])
            guard !vodID.isEmpty, !title.isEmpty else { return nil }
            let lineFlags = valueString(value, keys: ["vod_play_from"]).components(separatedBy: "$$$")
            let playURLs = valueString(value, keys: ["vod_play_url"]).components(separatedBy: "$$$")
            let danmakuSource = valueString(value, keys: ["vod_danmaku", "danmaku", "vod_danmu"])
            let lines = playURLs.enumerated().compactMap { index, block -> PlaybackLine? in
                guard !block.isEmpty else { return nil }
                let flag = index < lineFlags.count && !lineFlags[index].isEmpty ? lineFlags[index] : "线路\(index + 1)"
                return PlaybackLine(flag: flag, episodes: parseEpisodes(block, flag: flag, identity: vodID, danmakuSource: danmakuSource))
            }
            let poster = valueString(value, keys: ["vod_pic", "pic", "poster"])
            return MediaItem(
                sourceKey: site.key,
                sourceName: site.name,
                vodID: vodID,
                title: title,
                category: valueString(value, keys: ["type_name", "vod_class", "type"]),
                subtitle: valueString(value, keys: ["vod_remarks", "remarks", "vod_year"]),
                summary: plainText(valueString(value, keys: ["vod_content", "vod_blurb", "summary", "des"])),
                year: valueString(value, keys: ["vod_year", "year"]),
                area: valueString(value, keys: ["vod_area", "area"]),
                language: valueString(value, keys: ["vod_lang", "lang"]),
                actor: valueString(value, keys: ["vod_actor", "actor"]),
                director: valueString(value, keys: ["vod_director", "director"]),
                remarks: valueString(value, keys: ["vod_remarks", "remarks"]),
                posterURL: resolvedURL(poster, relativeTo: site.api),
                lines: lines
            )
        }
    }

    private func parseXMLVideos(_ root: TVBoxXMLNode, site: TVBoxSite) -> [MediaItem] {
        guard let list = root.descendants(named: "list").first else { return [] }
        return list.children.filter { $0.name == "video" }.compactMap { video in
            let vodID = video.value("id", "vod_id")
            let title = video.value("name", "vod_name")
            guard !vodID.isEmpty, !title.isEmpty else { return nil }
            let lineNodes = video.descendants(named: "dd")
            var lines = lineNodes.enumerated().compactMap { index, node -> PlaybackLine? in
                let flag = node.attributes["flag"] ?? "线路\(index + 1)"
                let episodes = parseEpisodes(node.text, flag: flag, identity: vodID, danmakuSource: video.value("danmaku", "danmu"))
                return episodes.isEmpty ? nil : PlaybackLine(flag: flag, episodes: episodes)
            }
            if lines.isEmpty {
                let address = video.value("url", "play_url", "vod_play_url")
                if !address.isEmpty {
                    lines = [PlaybackLine(flag: "默认线路", episodes: parseEpisodes(address, flag: "默认线路", identity: vodID, danmakuSource: video.value("danmaku", "danmu")))]
                }
            }
            let poster = video.value("pic", "vod_pic")
            return MediaItem(
                sourceKey: site.key,
                sourceName: site.name,
                vodID: vodID,
                title: title,
                category: video.value("type", "type_name"),
                subtitle: video.value("note", "vod_remarks"),
                summary: plainText(video.value("des", "content", "vod_content")),
                year: video.value("year", "vod_year"),
                area: video.value("area", "vod_area"),
                language: video.value("lang", "vod_lang"),
                actor: video.value("actor", "vod_actor"),
                director: video.value("director", "vod_director"),
                remarks: video.value("note", "vod_remarks"),
                posterURL: resolvedURL(poster, relativeTo: site.api),
                lines: lines
            )
        }
    }

    private func parseFilters(_ value: Any?) -> [TVBoxFilter] {
        let values: [[String: Any]]
        if let array = value as? [[String: Any]] {
            values = array
        } else if let object = value as? [String: Any] {
            values = [object]
        } else {
            return []
        }
        return values.compactMap { filter in
            let key = valueString(filter, keys: ["key"])
            let name = valueString(filter, keys: ["name"])
            guard !key.isEmpty, !name.isEmpty else { return nil }
            let options = (filter["value"] as? [[String: Any]] ?? []).map {
                TVBoxFilterOption(title: valueString($0, keys: ["n", "name"]), value: valueString($0, keys: ["v", "value"]))
            }
            return TVBoxFilter(key: key, name: name, options: options)
        }
    }

    private func resolveWithParser(
        address: String,
        explicitParser: TVBoxParser?,
        configuration: TVBoxConfiguration,
        selectedParserName: String?,
        extraHeaders: [String: String]
    ) async throws -> PlaybackResolution {
        guard let parser = explicitParser
            ?? configuration.parsers.first(where: { $0.name == selectedParserName })
            ?? configuration.parsers.first else {
            throw CatalogError.noJSONParser
        }
        switch parser.type {
        case 0:
            return try await resolveWithWebParser(address: address, parser: parser, extraHeaders: extraHeaders)
        case 1:
            return try await resolveWithJSONParser(address: address, parser: parser, extraHeaders: extraHeaders)
        default:
            throw CatalogError.unsupportedParserType(parser.type)
        }
    }

    private func resolveWithJSONParser(
        address: String,
        parser: TVBoxParser,
        extraHeaders: [String: String]
    ) async throws -> PlaybackResolution {
        var queryAllowed = CharacterSet.urlQueryAllowed
        queryAllowed.remove(charactersIn: "&+=?#")
        let encodedAddress = address.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? address
        let endpoint = parserEndpoint(parser.url, encodedAddress: encodedAddress)
        let parserHeaders = headersFromExt(parser.ext).merging(extraHeaders) { _, new in new }
        let object = try jsonObject(await requestData(endpoint, headers: parserHeaders))
        let resolved = nestedString(object, keys: ["url"])
        guard let url = validURL(resolved) else { throw CatalogError.noPlayableURL }
        let parse = intValue(object["parse"] ?? (object["data"] as? [String: Any])?["parse"], default: 0)
        let response = responseHeaders(object)
        if parse != 0 {
            let webParser = TVBoxParser(name: parser.name, url: url.absoluteString, type: 0, ext: parser.ext)
            return try await resolveWithWebParser(address: "", parser: webParser, extraHeaders: extraHeaders.merging(response) { _, new in new })
        }
        return PlaybackResolution(url: url, headers: extraHeaders.merging(response) { _, new in new })
    }

    private func resolveWithWebParser(
        address: String,
        parser: TVBoxParser,
        extraHeaders: [String: String]
    ) async throws -> PlaybackResolution {
        var queryAllowed = CharacterSet.urlQueryAllowed
        queryAllowed.remove(charactersIn: "&+=?#")
        let encodedAddress = address.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? address
        let pageAddress = address.isEmpty ? parser.url : parserEndpoint(parser.url, encodedAddress: encodedAddress)
        guard let pageURL = URL(string: pageAddress), ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else {
            throw CatalogError.invalidURL
        }
        let pageHeaders = headersFromExt(parser.ext).merging(extraHeaders) { _, new in new }
        let data = try await requestData(pageURL, headers: pageHeaders)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CatalogError.noPlayableURL
        }
        let normalized = html
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\\"", with: "\"")
        let patterns = [
            #"(?i)(?:https?:)?//[^\s\"'<>\\]+?\.(?:m3u8|mpd|mp4|m4v|mov|flv|ts|mkv|avi)(?:\?[^\s\"'<>\\]*)?"#,
            #"(?i)(?:file|playurl|video_url)\s*[:=]\s*[\"']([^\"']+)[\"']"#,
            #"(?i)<video\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"'][^>]*>"#
        ]
        var candidates: [String] = []
        for (index, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalized.startIndex..., in: normalized)
            for match in expression.matches(in: normalized, range: range) {
                let resultRange = index == 0 ? match.range(at: 0) : match.range(at: 1)
                guard let swiftRange = Range(resultRange, in: normalized) else { continue }
                var value = String(normalized[swiftRange])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'`),;"))
                if value.hasPrefix("//") { value = "https:\(value)" }
                let extensionName = URL(string: value, relativeTo: pageURL)?.pathExtension.lowercased() ?? ""
                if ["js", "mjs", "css", "json", "html", "htm", "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "woff", "woff2", "ttf"].contains(extensionName) {
                    continue
                }
                if let candidate = URL(string: value, relativeTo: pageURL)?.absoluteURL,
                   validURL(candidate.absoluteString) != nil,
                   !candidates.contains(candidate.absoluteString) {
                    candidates.append(candidate.absoluteString)
                }
            }
        }
        let preferred = candidates.first { $0.localizedCaseInsensitiveContains(".m3u8") }
            ?? candidates.first { $0.localizedCaseInsensitiveContains(".mpd") }
            ?? candidates.first
        guard let preferred, let url = validURL(preferred) else { throw CatalogError.webParserUnavailable }
        return PlaybackResolution(url: url, headers: pageHeaders)
    }

    private func parserEndpoint(_ template: String, encodedAddress: String) -> String {
        if template.contains("{url}") {
            return template.replacingOccurrences(of: "{url}", with: encodedAddress)
        }
        if template.contains("%s") {
            return template.replacingOccurrences(of: "%s", with: encodedAddress)
        }
        return template + encodedAddress
    }

    private func resolvedExtend(_ value: String) async throws -> String {
        guard value.hasPrefix("http://") || value.hasPrefix("https://") else { return value }
        let data = try await requestData(value)
        if let object = try? JSONSerialization.jsonObject(with: data), JSONSerialization.isValidJSONObject(object),
           let compact = try? JSONSerialization.data(withJSONObject: object),
           let string = String(data: compact, encoding: .utf8) {
            return string
        }
        return String(data: data, encoding: .utf8) ?? value
    }

    private func parseLiveText(_ content: String) -> [TVBoxLiveGroup] {
        if content.contains("#EXTM3U") {
            var groups: [(String, [TVBoxLiveChannel])] = []
            var currentName: String?
            var currentGroup = "直播"
            var currentCatchupSource = ""
            var currentLogoURL: URL?
            var currentHeaders: [String: String] = [:]
            for line in content.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !line.isEmpty {
                if line.hasPrefix("#EXTINF") {
                    let info = line.components(separatedBy: ",").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    currentName = info.isEmpty ? nil : info
                    currentGroup = "直播"
                    let parsedGroup = attribute("group-title", in: line)
                    if !parsedGroup.isEmpty { currentGroup = parsedGroup }
                    currentCatchupSource = attribute("catchup-source", in: line)
                    let logo = attribute("tvg-logo", in: line)
                    currentLogoURL = logo.isEmpty ? nil : URL(string: logo)
                    currentHeaders = [:]
                } else if line.hasPrefix("#EXTVLCOPT:http-user-agent=") {
                    currentHeaders["User-Agent"] = String(line.dropFirst("#EXTVLCOPT:http-user-agent=".count))
                } else if line.hasPrefix("#EXTVLCOPT:http-referrer=") || line.hasPrefix("#EXTVLCOPT:http-referer=") {
                    if let separator = line.firstIndex(of: "=") {
                        currentHeaders["Referer"] = String(line[line.index(after: separator)...])
                    }
                } else if line.hasPrefix("#EXTVLCOPT:http-cookie=") {
                    currentHeaders["Cookie"] = String(line.dropFirst("#EXTVLCOPT:http-cookie=".count))
                } else if !line.hasPrefix("#"), let name = currentName {
                    let source = TVBoxLiveSource(name: "线路 1", address: line, headers: currentHeaders)
                    if let groupIndex = groups.firstIndex(where: { $0.0 == currentGroup }) {
                        if let channelIndex = groups[groupIndex].1.firstIndex(where: { $0.name == name }) {
                            var channel = groups[groupIndex].1[channelIndex]
                            if !channel.sources.contains(where: { $0.address == source.address }) {
                                channel = TVBoxLiveChannel(
                                    name: channel.name,
                                    sources: channel.sources + [source],
                                    catchupSources: channel.catchupSources + [currentCatchupSource],
                                    logoURL: channel.logoURL ?? currentLogoURL
                                )
                            }
                            groups[groupIndex].1[channelIndex] = channel
                        } else {
                            groups[groupIndex].1.append(TVBoxLiveChannel(name: name, sources: [source], catchupSources: [currentCatchupSource], logoURL: currentLogoURL))
                        }
                    } else {
                        groups.append((currentGroup, [TVBoxLiveChannel(name: name, sources: [source], catchupSources: [currentCatchupSource], logoURL: currentLogoURL)]))
                    }
                    currentName = nil
                }
            }
            return groups.map { TVBoxLiveGroup(name: $0.0, channels: $0.1) }
        }

        var groups: [(String, [TVBoxLiveChannel])] = []
        var groupName = "直播"
        var channels: [TVBoxLiveChannel] = []
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasSuffix(",#genre#") {
                if !channels.isEmpty { groups.append((groupName, channels)); channels = [] }
                groupName = String(line.dropLast(",#genre#".count))
                continue
            }
            let fields = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let name = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceFields = String(fields[1]).components(separatedBy: "#")
            let sources = sourceFields.enumerated().compactMap { index, raw -> TVBoxLiveSource? in
                let split = raw.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
                guard let address = split.first, !address.isEmpty else { return nil }
                return TVBoxLiveSource(name: split.count > 1 ? String(split[1]) : "线路\(index + 1)", address: String(address))
            }
            if !name.isEmpty, !sources.isEmpty {
                let catchupSources = Array(repeating: "", count: sources.count)
                if let channelIndex = channels.firstIndex(where: { $0.name == name }) {
                    var channel = channels[channelIndex]
                    var mergedSources = channel.sources
                    var mergedCatchup = channel.catchupSources
                    for source in sources where !mergedSources.contains(where: { $0.address == source.address }) {
                        mergedSources.append(source)
                        mergedCatchup.append("")
                    }
                    channel = TVBoxLiveChannel(name: name, sources: mergedSources, catchupSources: mergedCatchup, logoURL: channel.logoURL)
                    channels[channelIndex] = channel
                } else {
                    channels.append(TVBoxLiveChannel(name: name, sources: sources, catchupSources: catchupSources))
                }
            }
        }
        if !channels.isEmpty { groups.append((groupName, channels)) }
        return groups.map { TVBoxLiveGroup(name: $0.0, channels: $0.1) }
    }

    private func attribute(_ name: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?:^|\\s)\(escaped)=\"([^\"]*)\""
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return "" }
        return String(text[range])
    }

    private func requestData(_ address: String, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw CatalogError.invalidURL
        }
        return try await requestData(url, headers: headers)
    }

    private func requestData(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else { throw CatalogError.badResponse(http.statusCode) }
        return data
    }

    private func requestText(_ address: String) async throws -> String {
        let data = try await requestData(address)
        guard let text = String(data: data, encoding: .utf8) else { throw CatalogError.malformedJSON }
        return text
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw CatalogError.malformedJSON
        }
        return object
    }

    private func makeURL(_ address: String, parameters: [String: String]) throws -> URL {
        guard var components = URLComponents(string: address),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            throw CatalogError.invalidURL
        }
        var queryItems = components.queryItems ?? []
        for (name, value) in parameters {
            queryItems.removeAll { $0.name == name }
            queryItems.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw CatalogError.invalidURL }
        return url
    }

    private func parseXML(_ data: Data) throws -> TVBoxXMLNode {
        let delegate = TVBoxXMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = delegate.root else { throw CatalogError.malformedJSON }
        return root
    }

    private func validURL(_ text: String) -> URL? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = normalized.hasPrefix("//") ? "https:\(normalized)" : normalized
        guard let url = URL(string: candidate), ["http", "https", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func resolvedURL(_ text: String, relativeTo base: String) -> URL? {
        guard !text.isEmpty else { return nil }
        if let absolute = URL(string: text), absolute.scheme != nil { return absolute }
        guard let baseURL = URL(string: base) else { return nil }
        return URL(string: text, relativeTo: baseURL)?.absoluteURL
    }

    private func isLikelyMediaURL(_ url: URL) -> Bool {
        if ["rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "") { return true }
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        let extensions = [
            ".m3u8", ".m3u", ".mp4", ".m4v", ".mov", ".mkv", ".avi", ".ts", ".m2ts", ".mts", ".flv", ".mpd", ".webm",
            ".mp3", ".aac", ".m4a", ".wav", ".flac", ".ape", ".wma", ".mpeg", ".mpg", ".wmv", ".asf", ".3gp", ".vob", ".ogv", ".ogg", ".rm", ".rmvb"
        ]
        return extensions.contains { path.hasSuffix($0) } || extensions.contains { query.contains($0) }
    }

    private func responseHeaders(_ object: [String: Any]) -> [String: String] {
        var headers: [String: String] = [:]
        let nested = object["data"] as? [String: Any]
        if let raw = headerDictionary(object["header"])
            ?? headerDictionary(object["headers"])
            ?? headerDictionary(nested?["header"])
            ?? headerDictionary(nested?["headers"]) {
            raw.forEach { headers[$0.key] = scalarString($0.value) }
        }
        if let userAgent = object["user-agent"] as? String ?? nested?["user-agent"] as? String, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
        if let referer = object["referer"] as? String ?? nested?["referer"] as? String, !referer.isEmpty { headers["Referer"] = referer }
        return headers
    }

    private func headerDictionary(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func headersFromExt(_ ext: String) -> [String: String] {
        guard let data = ext.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let headers = object["header"] as? [String: Any] else { return [:] }
        return headers.mapValues(scalarString)
    }

    private func nestedString(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = object[key] { return scalarString(value) }
        }
        if let data = object["data"] as? [String: Any] {
            for key in keys {
                if let value = data[key] { return scalarString(value) }
            }
        }
        return ""
    }

    private func valueString(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = object[key], !(value is NSNull) { return scalarString(value) }
        }
        return ""
    }

    private func scalarString(_ value: Any) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func intValue(_ value: Any?, default fallback: Int) -> Int {
        guard let value else { return fallback }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let parsed = Int(string) { return parsed }
        return fallback
    }

    private func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private func plainText(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseEpisodes(_ raw: String, flag: String, identity: String, danmakuSource: String = "") -> [Episode] {
        raw.components(separatedBy: "#").enumerated().compactMap { index, segment in
            guard !segment.isEmpty else { return nil }
            let splitIndex = segment.firstIndex(of: "$" )
            let title: String
            let address: String
            if let splitIndex {
                title = String(segment[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                address = String(segment[segment.index(after: splitIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                title = "第 \(index + 1) 集"
                address = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !address.isEmpty else { return nil }
            let id = "\(identity)::\(flag)::\(index)::\(title)"
            return Episode(
                id: id,
                title: title.isEmpty ? "第 \(index + 1) 集" : title,
                address: address,
                flag: flag,
                danmakuSource: danmakuSource.isEmpty ? nil : danmakuSource
            )
        }
    }
}

private final class TVBoxXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [TVBoxXMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ names: [String]) -> TVBoxXMLNode? {
        children.first { names.contains($0.name) }
    }

    func value(_ names: String...) -> String {
        child(names)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func descendants(named target: String) -> [TVBoxXMLNode] {
        var result: [TVBoxXMLNode] = []
        if name == target { result.append(self) }
        for child in children { result.append(contentsOf: child.descendants(named: target)) }
        return result
    }
}

private final class TVBoxXMLTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [TVBoxXMLNode] = []
    var root: TVBoxXMLNode?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = TVBoxXMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { stack.last?.text.append(text) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}
