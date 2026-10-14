import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct DanmakuComment: Identifiable, Hashable {
    enum Mode: Int, Hashable {
        case scrollRightToLeft = 1
        case scrollLeftToRight = 2
        case fixedBottom = 4
        case fixedTop = 5
        case reverse = 6
        case special = 7
        case unknown = 0
    }

    struct Motion: Hashable {
        let startX: Double
        let startY: Double
        let endX: Double
        let endY: Double
        let startAlpha: Double
        let endAlpha: Double
        let duration: Double
        let delay: Double
    }

    let id: Int
    let time: Double
    let mode: Mode
    let fontSize: Double
    let color: UInt32
    let text: String
    let motion: Motion?

    var displayDuration: Double {
        if mode == .fixedTop || mode == .fixedBottom { return 4 }
        if let motion { return motion.duration + motion.delay }
        return 8
    }
}

struct DanmakuAnime: Identifiable, Hashable {
    let id: String
    let title: String
    let searchTitle: String
    let typeDescription: String
    let startYear: String
    let episodeCount: Int?
}

struct DanmakuEpisode: Identifiable, Hashable {
    let id: String
    let title: String
}

enum DanmakuServiceError: LocalizedError {
    case missingAPI
    case invalidURL
    case http(Int)
    case api(String)
    case invalidXML

    var errorDescription: String? {
        switch self {
        case .missingAPI:
            return "请先在设置中填写 DandanPlay 兼容的弹幕 API 地址。"
        case .invalidURL:
            return "弹幕 API 地址无效，请使用 HTTP 或 HTTPS 地址。"
        case .http(let status) where status == 401 || status == 403:
            return "弹幕 API 认证失败，请检查服务地址中的 Token。"
        case .http(let status):
            return "弹幕 API 请求失败（HTTP \(status)）。"
        case .api(let message):
            return message
        case .invalidXML:
            return "弹幕接口没有返回有效的 XML 弹幕数据。"
        }
    }
}

struct DanmakuService {
    private struct EpisodeReference: Equatable {
        let season: Int?
        let number: Int
    }

    private static func episodeReference(in title: String) -> EpisodeReference? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 3, let number = Int(trimmed), number > 0 {
            return EpisodeReference(season: nil, number: number)
        }

        let seasonPatterns = [
            #"(?i)\bS0*(\d{1,2})\s*E(?:P)?0*(\d{1,3})\b"#,
            #"第\s*([0-9]{1,2}|[零〇一二两三四五六七八九十百]+)\s*[季部][^\n]{0,12}?第\s*([0-9]{1,3}|[零〇一二两三四五六七八九十百]+)\s*[集话話期回]"#
        ]
        let titleRange = NSRange(title.startIndex..<title.endIndex, in: title)
        for pattern in seasonPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: title, range: titleRange),
                  let seasonRange = Range(match.range(at: 1), in: title),
                  let numberRange = Range(match.range(at: 2), in: title),
                  let season = Self.episodeComponent(String(title[seasonRange])),
                  let number = Self.episodeComponent(String(title[numberRange])),
                  season > 0, number > 0 else { continue }
            return EpisodeReference(season: season, number: number)
        }

        let patterns = [
            #"(?i)\b(?:EP?|Episode)\s*0*(\d{1,3})\b"#,
            #"第\s*([0-9]{1,3})\s*[集话話期回]"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: title, range: titleRange),
                  let range = Range(match.range(at: 1), in: title),
                  let number = Int(title[range]), number > 0 else { continue }
            return EpisodeReference(season: nil, number: number)
        }

        let chinesePattern = #"第\s*([零〇一二两三四五六七八九十百]+)\s*[集话話期回]"#
        guard let expression = try? NSRegularExpression(pattern: chinesePattern),
              let match = expression.firstMatch(in: title, range: titleRange),
              let range = Range(match.range(at: 1), in: title) else { return nil }
        guard let number = Self.chineseEpisodeNumber(String(title[range])) else { return nil }
        return EpisodeReference(season: nil, number: number)
    }

    private static func seasonNumber(in title: String) -> Int? {
        let patterns = [
            #"(?i)\bS0*(\d{1,2})(?:E0*\d{1,3})?\b"#,
            #"(?i)\bSeason\s*0*(\d{1,2})\b"#,
            #"第\s*([0-9]{1,2}|[零〇一二两三四五六七八九十百]+)\s*[季部]"#
        ]
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: title, range: range),
                  let valueRange = Range(match.range(at: 1), in: title),
                  let season = Self.episodeComponent(String(title[valueRange])), season > 0 else { continue }
            return season
        }
        return nil
    }

    private static func yearNumber(in title: String) -> String? {
        guard let range = title.range(of: #"(?:19|20)\d{2}"#, options: .regularExpression) else { return nil }
        return String(title[range])
    }

    private static func titleType(in title: String) -> String {
        let patterns = [#"〖([^〗]+)〗"#, #"【([^】]+)】"#, #"\[([^\]]+)\]"#]
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        let knownKinds = ["电影", "剧场版", "电视剧", "连续剧", "剧集", "番剧", "动漫", "动画", "movie", "film", "series", "tv"]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: title, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: title) else { continue }
                let value = String(title[valueRange])
                if knownKinds.contains(where: { value.localizedCaseInsensitiveContains($0) }) { return value }
            }
        }
        return ""
    }

    private static func normalizedMatchTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"(?i)(?<=[】〗\]])from\s+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+from\s+.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[（(](?:19|20)\d{2}[）)]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[【〖][^】〗]*(?:电影|剧场版|电视剧|连续剧|剧集|番剧|动漫|动画|TV|Movie)[^】〗]*[】〗]|\[[^\]]*(?:电影|剧场版|电视剧|连续剧|剧集|番剧|动漫|动画|TV|Movie)[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bSeason\s*0*\d{1,2}\b|\bS0*\d{1,2}(?:E0*\d{1,3})?\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"第\s*(?:[0-9]{1,2}|[零〇一二两三四五六七八九十百]+)\s*[季部]"#, with: "", options: .regularExpression)
        return Self.normalized(cleaned)
    }

    static func episodeNumber(in title: String) -> Int? {
        episodeReference(in: title)?.number
    }

    func searchAnime(keyword: String, apiAddress: String) async throws -> [DanmakuAnime] {
        let data = try await request(path: ["search", "anime"], query: [URLQueryItem(name: "keyword", value: keyword)], apiAddress: apiAddress)
        let root = try jsonObject(data)
        try checkAPIError(root)
        let records = root["animes"] as? [[String: Any]] ?? []
        return records.compactMap { record in
            let id = value(record, keys: ["animeId", "bangumiId", "id"])
            let originalTitle = value(record, keys: ["animeTitle", "title", "name"])
            guard !id.isEmpty, !originalTitle.isEmpty else { return nil }
            return makeAnime(id: id, title: originalTitle, record: record)
        }
    }

    func episodes(for anime: DanmakuAnime, apiAddress: String) async throws -> [DanmakuEpisode] {
        do {
            let detailData = try await request(path: ["bangumi", anime.id], apiAddress: apiAddress)
            let detail = try jsonObject(detailData)
            try checkAPIError(detail)
            let bangumi = detail["bangumi"] as? [String: Any] ?? detail
            let episodes = readEpisodes(bangumi)
            if !episodes.isEmpty { return episodes }
        } catch DanmakuServiceError.http(let status) {
            guard status == 404 else { throw DanmakuServiceError.http(status) }
        }

        let searchData = try await request(
            path: ["search", "episodes"],
            query: [URLQueryItem(name: "anime", value: anime.searchTitle)],
            apiAddress: apiAddress
        )
        let search = try jsonObject(searchData)
        try checkAPIError(search)
        let candidates = search["animes"] as? [[String: Any]] ?? []
        let exactTitleMatches = candidates.filter {
            value($0, keys: ["animeTitle", "title", "name"]).trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(anime.searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        let exactIDMatches = exactTitleMatches.filter {
            value($0, keys: ["animeId", "bangumiId", "id"]) == anime.id
        }
        if exactIDMatches.count == 1 { return readEpisodes(exactIDMatches[0]) }

        let compatibleUnidentifiedMatches = exactTitleMatches.filter { record in
            guard value(record, keys: ["animeId", "bangumiId", "id"]).isEmpty else { return false }
            let candidateDate = value(record, keys: ["startDate", "airDate"])
            let candidateYear = candidateDate.count >= 4 ? String(candidateDate.prefix(4)) : ""
            let candidateType = value(record, keys: ["typeDescription", "animeTypeDescription", "typeName"])
            let yearConflicts = !anime.startYear.isEmpty && !candidateYear.isEmpty && candidateYear != anime.startYear
            let typeConflicts = !anime.typeDescription.isEmpty && !candidateType.isEmpty
                && candidateType.localizedCaseInsensitiveCompare(anime.typeDescription) != .orderedSame
            return !yearConflicts && !typeConflicts
        }
        guard compatibleUnidentifiedMatches.count == 1 else {
            if compatibleUnidentifiedMatches.isEmpty, exactTitleMatches.isEmpty { return [] }
            if compatibleUnidentifiedMatches.isEmpty {
                throw DanmakuServiceError.api("弹幕源没有返回与所选作品 ID、年份或类型一致的集数；为避免加载同名作品的弹幕，已停止匹配。")
            }
            throw DanmakuServiceError.api("弹幕源返回了多个无法区分的同名作品，无法确认当前选中的作品。请检查弹幕 API 或选择另一条结果。")
        }
        return readEpisodes(compatibleUnidentifiedMatches[0])
    }

    func automaticMatch(
        title: String,
        category: String,
        year: String,
        episodeTitle: String,
        isSeries: Bool,
        apiAddress: String
    ) async throws -> (comments: [DanmakuComment], matchTitle: String) {
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { throw DanmakuServiceError.api("没有可用于匹配弹幕的片名，请手动搜索。") }

        // danmu-api 的 match 接口可以解析发行文件名、年份、季数和集数，
        // 优先使用服务端的规则/映射记忆；对返回结果做本地校验后才采纳。
        do {
            if let matched = try await intelligentMatch(
                title: keyword,
                category: category,
                year: year,
                episodeTitle: episodeTitle,
                isSeries: isSeries,
                apiAddress: apiAddress
            ) {
                return matched
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // 老版本 DandanPlay 兼容服务可能没有 match 接口，继续使用搜索接口兜底。
        }

        let searchResults = try await searchAnime(keyword: keyword, apiAddress: apiAddress)
        let normalizedTitle = Self.normalizedMatchTitle(keyword)
        let requestedYear = year.isEmpty ? (Self.yearNumber(in: keyword) ?? "") : year
        let requestedSeason = Self.episodeReference(in: episodeTitle)?.season ?? Self.seasonNumber(in: keyword)
        let categoryIsMovie = ["电影", "剧场版", "movie", "film"].contains { category.lowercased().contains($0) }
        let mediaIsSeries = !categoryIsMovie && (isSeries || ["电视剧", "连续剧", "剧集", "番剧", "动漫", "动画", "series", "tv"]
            .contains { category.lowercased().contains($0) })
        let exactTitleMatches = searchResults.filter {
            Self.normalizedMatchTitle($0.title) == normalizedTitle || Self.normalizedMatchTitle($0.searchTitle) == normalizedTitle
        }
        let typedMatches = exactTitleMatches.filter { anime in
            let candidateType = "\(anime.typeDescription) \(Self.titleType(in: anime.title))".lowercased()
            let candidateIsMovie = ["电影", "剧场版", "movie", "film"].contains { candidateType.contains($0) }
            let candidateIsSeries = !candidateIsMovie && ["电视剧", "连续剧", "剧集", "番剧", "动漫", "动画", "series", "tv"]
                .contains { candidateType.contains($0) }
            let mediaIsMovie = categoryIsMovie
            if mediaIsMovie && candidateIsSeries { return false }
            if mediaIsSeries && candidateIsMovie { return false }
            return true
        }
        let yearMatches = typedMatches.filter { anime in
            let titleYear = Self.yearNumber(in: anime.title) ?? Self.yearNumber(in: anime.searchTitle) ?? ""
            let candidateYear = anime.startYear.isEmpty ? titleYear : anime.startYear
            return requestedYear.isEmpty || candidateYear.isEmpty || candidateYear == requestedYear
        }.filter { anime in
            guard mediaIsSeries else { return true }
            let candidateSeason = Self.seasonNumber(in: anime.title) ?? Self.seasonNumber(in: anime.searchTitle)
            if let requestedSeason { return candidateSeason == nil || candidateSeason == requestedSeason }
            return candidateSeason == nil
        }
        guard yearMatches.count == 1, let anime = yearMatches.first else {
            throw DanmakuServiceError.api("未能唯一匹配《\(keyword)》的年份和类型，请手动搜索选择作品。")
        }

        let availableEpisodes = try await episodes(for: anime, apiAddress: apiAddress)
        let selectedEpisode: DanmakuEpisode?
        if mediaIsSeries {
            guard let currentEpisode = Self.episodeReference(in: episodeTitle) else {
                throw DanmakuServiceError.api("无法识别当前集数，请手动搜索并选择对应集数。")
            }
            let candidates = availableEpisodes.compactMap { episode -> (DanmakuEpisode, EpisodeReference)? in
                guard let reference = Self.episodeReference(in: episode.title) else { return nil }
                return (episode, reference)
            }
            let hasSeasonLabels = candidates.contains { $0.1.season != nil }
            let matches = candidates.filter { pair in
                let candidate = pair.1
                guard candidate.number == currentEpisode.number else { return false }
                guard let requestedSeason = currentEpisode.season ?? Self.seasonNumber(in: keyword) else {
                    return candidate.season == nil && !hasSeasonLabels
                }
                return candidate.season == requestedSeason || (candidate.season == nil && !hasSeasonLabels)
            }
            guard matches.count == 1, let selected = matches.first?.0 else {
                let seasonText = currentEpisode.season.map { "第 \($0) 季" } ?? ""
                throw DanmakuServiceError.api("《\(anime.title)》没有唯一匹配\(seasonText)第 \(currentEpisode.number) 集的弹幕，请手动搜索。")
            }
            selectedEpisode = selected
        } else {
            let featureMatches = availableEpisodes.filter {
                let name = $0.title.lowercased()
                return ["正片", "电影", "全片", "movie", "feature"].contains { name.contains($0) }
            }
            if availableEpisodes.count == 1 {
                selectedEpisode = availableEpisodes.first
            } else if featureMatches.count == 1 {
                selectedEpisode = featureMatches.first
            } else {
                throw DanmakuServiceError.api("无法唯一确定《\(anime.title)》的电影正片弹幕，请手动搜索选择。")
            }
        }

        guard let selectedEpisode else { throw DanmakuServiceError.api("匹配作品没有可用的弹幕集数，请手动搜索。") }
        let loadedComments = try await comments(for: selectedEpisode, apiAddress: apiAddress)
        return (loadedComments, "\(anime.title) · \(selectedEpisode.title)")
    }

    private func intelligentMatch(
        title: String,
        category: String,
        year: String,
        episodeTitle: String,
        isSeries: Bool,
        apiAddress: String
    ) async throws -> (comments: [DanmakuComment], matchTitle: String)? {
        let categoryIsMovie = ["电影", "剧场版", "movie", "film"].contains { category.lowercased().contains($0) }
        let expectsEpisode = !categoryIsMovie && (isSeries || ["电视剧", "连续剧", "剧集", "番剧", "动漫", "动画", "series", "tv"]
            .contains { category.lowercased().contains($0) })
        let requestedEpisode = Self.episodeReference(in: episodeTitle)
        let requestedSeason = requestedEpisode?.season ?? Self.seasonNumber(in: title)
        if expectsEpisode, requestedEpisode == nil { return nil }

        var fileName = title
        if !year.isEmpty { fileName += " (\(year))" }
        if expectsEpisode, let requestedEpisode {
            if let season = requestedSeason {
                fileName += String(format: " S%02dE%02d", season, requestedEpisode.number)
            } else {
                fileName += String(format: " 第%02d集", requestedEpisode.number)
            }
        }

        let data = try await request(
            path: ["match"],
            method: "POST",
            jsonBody: ["fileName": fileName],
            apiAddress: apiAddress
        )
        let root = try jsonObject(data)
        try checkAPIError(root)
        guard root["isMatched"] as? Bool == true,
              let matches = root["matches"] as? [[String: Any]], matches.count == 1,
              let result = matches.first else { return nil }

        let animeTitle = value(result, keys: ["animeTitle", "title", "name"])
        let episodeID = value(result, keys: ["episodeId", "commentId"])
        let matchedEpisodeTitle = value(result, keys: ["episodeTitle", "episodeName"])
        guard !animeTitle.isEmpty, !episodeID.isEmpty, !matchedEpisodeTitle.isEmpty,
              intelligentMatchIsCompatible(
                requestedTitle: title,
                requestedCategory: category,
                requestedYear: year,
                requestedEpisode: requestedEpisode,
                requestedSeason: requestedSeason,
                isSeries: expectsEpisode,
                result: result,
                animeTitle: animeTitle,
                episodeTitle: matchedEpisodeTitle
              ) else { return nil }

        let episode = DanmakuEpisode(id: episodeID, title: matchedEpisodeTitle)
        let loadedComments = try await comments(for: episode, apiAddress: apiAddress)
        return (loadedComments, "\(animeTitle) · \(matchedEpisodeTitle)")
    }

    private func intelligentMatchIsCompatible(
        requestedTitle: String,
        requestedCategory: String,
        requestedYear: String,
        requestedEpisode: EpisodeReference?,
        requestedSeason: Int?,
        isSeries: Bool,
        result: [String: Any],
        animeTitle: String,
        episodeTitle: String
    ) -> Bool {
        let normalizedRequest = Self.normalizedMatchTitle(requestedTitle)
        let normalizedResult = Self.normalizedMatchTitle(animeTitle)
        // 仅剥离明确的年份、平台、类型和季号标记后做完整标题比较，
        // 避免把续作或标题前缀相同的另一部作品当作别名。
        guard !normalizedRequest.isEmpty, normalizedRequest == normalizedResult else {
            return false
        }

        let requestedIsMovie = ["电影", "剧场版", "movie", "film"].contains { requestedCategory.lowercased().contains($0) }
        let requestedIsSeries = !requestedIsMovie && (isSeries || ["电视剧", "连续剧", "剧集", "番剧", "动漫", "动画", "series", "tv"]
            .contains { requestedCategory.lowercased().contains($0) })
        let resultType = "\(value(result, keys: ["typeDescription", "animeTypeDescription", "typeName"])) \(value(result, keys: ["type"])) \(Self.titleType(in: animeTitle))".lowercased()
        let resultIsMovie = ["电影", "剧场版", "movie", "film"].contains { resultType.contains($0) }
        let resultIsSeries = !resultIsMovie && ["电视剧", "连续剧", "剧集", "番剧", "动漫", "动画", "series", "tv"]
            .contains { resultType.contains($0) }
        if requestedIsMovie && resultIsSeries { return false }
        if requestedIsSeries && resultIsMovie { return false }

        let returnedDate = value(result, keys: ["startDate", "airDate", "year"])
        let titleYear = Self.yearNumber(in: animeTitle) ?? ""
        let requestedTitleYear = Self.yearNumber(in: requestedTitle) ?? ""
        let returnedYear = returnedDate.count >= 4 ? String(returnedDate.prefix(4)) : titleYear
        let effectiveRequestedYear = requestedYear.isEmpty ? requestedTitleYear : requestedYear
        if !effectiveRequestedYear.isEmpty, !returnedYear.isEmpty, effectiveRequestedYear != returnedYear { return false }

        if isSeries {
            guard let requestedEpisode,
                  let matchedEpisode = Self.episodeReference(in: episodeTitle),
                  requestedEpisode.number == matchedEpisode.number else { return false }
            let matchedSeason = matchedEpisode.season ?? Self.seasonNumber(in: animeTitle)
            if let requestedSeason, let matchedSeason, requestedSeason != matchedSeason { return false }
            if requestedSeason == nil, matchedSeason != nil { return false }
        }
        return true
    }

    func comments(for episode: DanmakuEpisode, apiAddress: String) async throws -> [DanmakuComment] {
        let data = try await request(
            path: ["comment", episode.id],
            query: [URLQueryItem(name: "format", value: "xml")],
            apiAddress: apiAddress
        )
        return try parseXML(data)
    }

    func comments(from source: String, headers: [String: String] = [:]) async throws -> [DanmakuComment] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let data: Data
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            var request = URLRequest(url: url, timeoutInterval: 20)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { throw DanmakuServiceError.invalidURL }
            guard (200..<300).contains(httpResponse.statusCode) else { throw DanmakuServiceError.http(httpResponse.statusCode) }
            data = responseData
        } else {
            data = Data(trimmed.utf8)
        }
        return try parseXML(data)
    }

    func parseXML(_ data: Data) throws -> [DanmakuComment] {
        let delegate = DanmakuXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.foundRoot else { throw DanmakuServiceError.invalidXML }
        return delegate.comments
    }

    private func request(
        path: [String],
        query: [URLQueryItem] = [],
        method: String = "GET",
        jsonBody: [String: Any]? = nil,
        apiAddress: String
    ) async throws -> Data {
        let trimmed = apiAddress.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { throw DanmakuServiceError.missingAPI }
        guard var components = URLComponents(string: trimmed),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { throw DanmakuServiceError.invalidURL }
        var apiPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if apiPath != "api/v2", !apiPath.hasSuffix("/api/v2") {
            apiPath = apiPath.isEmpty ? "api/v2" : "\(apiPath)/api/v2"
        }
        let encodedPath = path.map { segment in
            segment.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? segment
        }.joined(separator: "/")
        components.percentEncodedPath = "/\(apiPath)/\(encodedPath)"
        components.queryItems = (components.queryItems ?? []) + query
        guard let url = components.url else { throw DanmakuServiceError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw DanmakuServiceError.invalidURL }
        guard (200..<300).contains(httpResponse.statusCode) else { throw DanmakuServiceError.http(httpResponse.statusCode) }
        return data
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DanmakuServiceError.api("弹幕 API 返回了无法识别的数据。")
        }
        return object
    }

    private func checkAPIError(_ value: [String: Any]) throws {
        if let success = value["success"] as? Bool, !success {
            let message = self.value(value, keys: ["errorMessage", "message"])
            throw DanmakuServiceError.api(message.isEmpty ? "弹幕 API 返回失败。" : message)
        }
        let errorCode = (value["errorCode"] as? NSNumber)?.intValue ?? Int(value["errorCode"] as? String ?? "0") ?? 0
        guard errorCode == 0 else {
            let message = self.value(value, keys: ["errorMessage", "message"])
            throw DanmakuServiceError.api(message.isEmpty ? "弹幕 API 错误（\(errorCode)）。" : message)
        }
    }

    private func readEpisodes(_ parent: [String: Any]) -> [DanmakuEpisode] {
        (parent["episodes"] as? [[String: Any]] ?? []).compactMap { record in
            let id = value(record, keys: ["episodeId", "id"])
            let title = value(record, keys: ["episodeTitle", "episodeName", "title", "name"])
            guard !id.isEmpty, !title.isEmpty else { return nil }
            return DanmakuEpisode(id: id, title: title)
        }
    }

    private func makeAnime(id: String, title: String, record: [String: Any]) -> DanmakuAnime {
        let rawType = value(record, keys: ["typeDescription", "animeTypeDescription", "typeName"])
        let yearValue = value(record, keys: ["startDate", "airDate"])
        let year = yearValue.count >= 4 ? String(yearValue.prefix(4)) : ""
        let rawEpisodeCount = value(record, keys: ["episodeCount", "episodesCount", "episodeNumber"])
        return DanmakuAnime(
            id: id,
            title: title,
            searchTitle: title,
            typeDescription: rawType,
            startYear: year,
            episodeCount: Int(rawEpisodeCount)
        )
    }

    private static func normalized(_ value: String) -> String {
        String(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber })
    }

    private static func episodeComponent(_ value: String) -> Int? {
        Int(value) ?? chineseEpisodeNumber(value)
    }

    private static func chineseEpisodeNumber(_ value: String) -> Int? {
        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        var section = 0
        var pendingDigit = 0
        for character in value {
            if let digit = digits[character] {
                pendingDigit = digit
            } else if character == "十" {
                section += (pendingDigit == 0 ? 1 : pendingDigit) * 10
                pendingDigit = 0
            } else if character == "百" {
                section += (pendingDigit == 0 ? 1 : pendingDigit) * 100
                pendingDigit = 0
            } else {
                return nil
            }
        }
        let number = section + pendingDigit
        return number > 0 ? number : nil
    }

    private func value(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            let string = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !string.isEmpty, string != "0" { return string }
        }
        return ""
    }
}

private final class DanmakuXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var comments: [DanmakuComment] = []
    private(set) var foundRoot = false
    private var currentAttributes: [String: String]?
    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = qName ?? elementName
        if name.lowercased() == "i" { foundRoot = true }
        guard name.lowercased() == "d" else { return }
        currentAttributes = attributeDict
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentAttributes != nil else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard currentAttributes != nil, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard (qName ?? elementName).lowercased() == "d", let rawParam = currentAttributes?["p"] else { return }
        currentAttributes = nil
        let values = rawParam.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard values.count >= 4,
              let time = Double(values[0]), time >= 0,
              let rawMode = Int(values[1]),
              let rawSize = Double(values[2]) else { return }
        let mode = DanmakuComment.Mode(rawValue: rawMode) ?? .unknown
        let color = UInt32(truncatingIfNeeded: Int64(values[3]) ?? 0)
        let motion = mode == .special ? Self.readMotion(from: currentText) : nil
        if mode == .special && motion == nil { return }
        let visibleText = motion == nil ? currentText : Self.specialText(from: currentText)
        guard !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        comments.append(DanmakuComment(
            id: comments.count,
            time: time,
            mode: mode,
            fontSize: min(64, max(12, rawSize)),
            color: color,
            text: visibleText,
            motion: motion
        ))
        currentText = ""
    }

    private static func specialText(from raw: String) -> String {
        guard let values = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any], values.count > 4 else { return raw }
        return String(describing: values[4])
    }

    private static func readMotion(from raw: String) -> DanmakuComment.Motion? {
        guard let values = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Any], values.count > 4,
              let startX = Double(String(describing: values[0])),
              let startY = Double(String(describing: values[1])),
              let alphaRange = String(describing: values[2]).split(separator: "-").compactMap({ Double($0) }).first,
              let duration = Double(String(describing: values[3])) else { return nil }
        let alphaValues = String(describing: values[2]).split(separator: "-").compactMap { Double($0) }
        let endAlpha = alphaValues.count > 1 ? alphaValues[1] : alphaRange
        let endX = values.count > 7 ? Double(String(describing: values[7])) ?? startX : startX
        let endY = values.count > 8 ? Double(String(describing: values[8])) ?? startY : startY
        let delay = values.count > 10 ? (Double(String(describing: values[10])) ?? 0) / 1_000 : 0
        return DanmakuComment.Motion(
            startX: coordinate(startX, scale: 1_920),
            startY: coordinate(startY, scale: 1_080),
            endX: coordinate(endX, scale: 1_920),
            endY: coordinate(endY, scale: 1_080),
            startAlpha: min(1, max(0, alphaRange)),
            endAlpha: min(1, max(0, endAlpha)),
            duration: min(30, max(0.5, duration)),
            delay: max(0, delay)
        )
    }

    private static func coordinate(_ value: Double, scale: Double) -> Double {
        value >= 0 && value <= 1 ? value : value / scale
    }
}

struct DanmakuPlacement: Identifiable {
    let comment: DanmakuComment
    let lane: Int
    let estimatedTextWidth: Double
    var id: Int { comment.id }
}

enum DanmakuLayout {
    static func make(comments: [DanmakuComment], width: Double, fontScale: Double, speed: Double, maxLines: Int) -> [DanmakuPlacement] {
        guard width > 0 else { return [] }
        let lineCount = max(1, min(15, maxLines))
        var scrollLanes = Array(repeating: (time: -Double.infinity, requiredDelay: 0.0), count: lineCount)
        var topLanes = Array(repeating: -Double.infinity, count: lineCount)
        var bottomLanes = Array(repeating: -Double.infinity, count: lineCount)
        var placements: [DanmakuPlacement] = []
        for comment in comments.sorted(by: { $0.time < $1.time }) {
            switch comment.mode {
            case .fixedTop:
                if let lane = topLanes.firstIndex(where: { $0 <= comment.time }) {
                    topLanes[lane] = comment.time + comment.displayDuration
                    placements.append(DanmakuPlacement(comment: comment, lane: lane, estimatedTextWidth: estimatedTextWidth(comment, fontSize: displayFontSize(comment: comment, width: width, scale: fontScale))))
                }
            case .fixedBottom:
                if let lane = bottomLanes.firstIndex(where: { $0 <= comment.time }) {
                    bottomLanes[lane] = comment.time + comment.displayDuration
                    placements.append(DanmakuPlacement(comment: comment, lane: lane, estimatedTextWidth: estimatedTextWidth(comment, fontSize: displayFontSize(comment: comment, width: width, scale: fontScale))))
                }
            case .special:
                placements.append(DanmakuPlacement(comment: comment, lane: 0, estimatedTextWidth: estimatedTextWidth(comment, fontSize: displayFontSize(comment: comment, width: width, scale: fontScale))))
            case .scrollRightToLeft, .scrollLeftToRight, .reverse, .unknown:
                let estimatedSize = displayFontSize(comment: comment, width: width, scale: fontScale)
                let estimatedWidth = estimatedTextWidth(comment, fontSize: estimatedSize)
                let duration = scrollDuration(speed: speed)
                let safeDelay = (estimatedWidth + 36) * duration / (width + estimatedWidth)
                guard let lane = scrollLanes.firstIndex(where: { comment.time - $0.time >= $0.requiredDelay }) else { continue }
                scrollLanes[lane] = (comment.time, safeDelay)
                placements.append(DanmakuPlacement(comment: comment, lane: lane, estimatedTextWidth: estimatedWidth))
            }
        }
        return placements
    }

    static func displayFontSize(comment: DanmakuComment, width: Double, scale: Double) -> Double {
        #if os(tvOS)
        let minimumSize = 24.0
        #else
        let minimumSize = 14.0
        #endif
        min(44, max(minimumSize, comment.fontSize * 0.78 * min(1.6, max(0.72, width / 900)) * scale))
    }

    static func estimatedTextWidth(_ comment: DanmakuComment, fontSize: Double) -> Double {
        let units = comment.text.unicodeScalars.reduce(0.0) { result, scalar in
            result + (scalar.value < 0x2E80 ? 0.58 : 1.0)
        }
        return max(fontSize, units * fontSize)
    }

    static func scrollDuration(speed: Double) -> Double {
        min(14, max(3.5, 8 / min(2.4, max(0.5, speed))))
    }
}
