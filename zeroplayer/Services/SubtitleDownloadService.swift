import Foundation

struct ParsedMediaQuery: Equatable {
    let title: String
    let year: Int?
    let season: Int?
    let episode: Int?

    var isTVEpisode: Bool {
        season != nil && episode != nil
    }
}

enum SubtitleDownloadError: LocalizedError {
    case missingTMDBAPIKey
    case invalidTMDBCredential
    case couldNotParseMediaName
    case tmdbLookupFailed
    case imdbIDNotFound
    case noSubtitleResults
    case invalidSubtitleURL
    case subtitleDownloadFailed

    var errorDescription: String? {
        switch self {
        case .missingTMDBAPIKey:
            return "Missing TMDb API credential. Set TMDB_API_KEY in APIKeys.plist."
        case .invalidTMDBCredential:
            return "TMDb credential is invalid. Update TMDB_API_KEY in APIKeys.plist."
        case .couldNotParseMediaName:
            return "Could not parse title from the video file name."
        case .tmdbLookupFailed:
            return "TMDb lookup failed for this media."
        case .imdbIDNotFound:
            return "TMDb did not return an IMDb ID for this media."
        case .noSubtitleResults:
            return "No subtitles found for this language."
        case .invalidSubtitleURL:
            return "Selected subtitle has an invalid download URL."
        case .subtitleDownloadFailed:
            return "Failed to download subtitle file."
        }
    }
}

final class SubtitleDownloadService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchSubtitles(for sourceFileURL: URL, languageCode: String?) async throws -> [InternetSubtitleOption] {
        let fileName = sourceFileURL.deletingPathExtension().lastPathComponent
        let parsed = Self.parseMediaQuery(from: fileName)
            ?? ParsedMediaQuery(title: Self.fallbackTitle(from: fileName), year: nil, season: nil, episode: nil)

        let imdbID = try await resolveIMDbID(for: parsed, fileNameHint: fileName)
        let response = try await searchWyzieSubtitles(imdbID: imdbID, parsed: parsed, releaseHint: fileName, languageCode: languageCode)
        let options = response.compactMap(Self.mapSubtitleOption(from:))
        guard !options.isEmpty else {
            throw SubtitleDownloadError.noSubtitleResults
        }

        return rankSubtitles(options, releaseHint: fileName, preferredLanguage: normalizedLanguageCode(languageCode))
    }

    func downloadSubtitle(_ subtitle: InternetSubtitleOption, for sourceFileURL: URL) async throws -> URL {
        let mediaTitle = Self.parseMediaQuery(from: sourceFileURL.deletingPathExtension().lastPathComponent)?.title
            ?? Self.fallbackTitle(from: sourceFileURL.deletingPathExtension().lastPathComponent)
        return try await downloadSubtitleFile(subtitle, mediaTitle: mediaTitle)
    }

    private func resolveIMDbID(for parsed: ParsedMediaQuery, fileNameHint: String) async throws -> String {
        if let embeddedIMDb = Self.extractIMDbID(from: fileNameHint) {
            return embeddedIMDb
        }

        let credentials = try tmdbCredentialCandidates()
        let titleCandidates = Self.tmdbTitleCandidates(from: parsed.title, fileNameHint: fileNameHint)
        var lookupAttempt = TMDbLookupAttempt()

        if parsed.isTVEpisode {
            let tvAttempt = try await resolveTVIMDbID(
                titleCandidates: titleCandidates,
                year: parsed.year,
                credentials: credentials
            )
            lookupAttempt.merge(tvAttempt)
            if let subtitleLookupID = tvAttempt.subtitleLookupID {
                return subtitleLookupID
            }

            let movieAttempt = try await resolveMovieIMDbID(
                titleCandidates: titleCandidates,
                year: parsed.year,
                credentials: credentials
            )
            lookupAttempt.merge(movieAttempt)
            if let subtitleLookupID = movieAttempt.subtitleLookupID {
                return subtitleLookupID
            }
        } else {
            let movieAttempt = try await resolveMovieIMDbID(
                titleCandidates: titleCandidates,
                year: parsed.year,
                credentials: credentials
            )
            lookupAttempt.merge(movieAttempt)
            if let subtitleLookupID = movieAttempt.subtitleLookupID {
                return subtitleLookupID
            }

            let tvAttempt = try await resolveTVIMDbID(
                titleCandidates: titleCandidates,
                year: parsed.year,
                credentials: credentials
            )
            lookupAttempt.merge(tvAttempt)
            if let subtitleLookupID = tvAttempt.subtitleLookupID {
                return subtitleLookupID
            }
        }

        if lookupAttempt.hadAuthorizedResponse {
            throw SubtitleDownloadError.tmdbLookupFailed
        }
        if lookupAttempt.hadUnauthorizedResponse {
            throw SubtitleDownloadError.invalidTMDBCredential
        }
        throw SubtitleDownloadError.tmdbLookupFailed
    }

    private func resolveMovieIMDbID(
        titleCandidates: [String],
        year: Int?,
        credentials: [TMDBCredential]
    ) async throws -> TMDbLookupAttempt {
        let yearCandidates = Self.optionalYearCandidates(year)
        var attempt = TMDbLookupAttempt()

        for credential in credentials {
            for title in titleCandidates {
                for candidateYear in yearCandidates {
                    var queryItems: [URLQueryItem?] = [
                        URLQueryItem(name: "query", value: title),
                        URLQueryItem(name: "include_adult", value: "false")
                    ]
                    if let candidateYear {
                        queryItems.append(URLQueryItem(name: "year", value: String(candidateYear)))
                    }

                    let movieSearch: TMDbSearchResponse<TMDbMovieResult>
                    do {
                        movieSearch = try await fetchTMDbJSON(
                            path: "/3/search/movie",
                            queryItems: queryItems,
                            credential: credential
                        )
                        attempt.hadAuthorizedResponse = true
                    } catch TMDbRequestError.unauthorized {
                        attempt.hadUnauthorizedResponse = true
                        continue
                    } catch {
                        continue
                    }

                    var tmdbFallbackID: String?
                    for result in movieSearch.results.prefix(5) {
                        tmdbFallbackID = tmdbFallbackID ?? String(result.id)
                        do {
                            let external: TMDbExternalIDs = try await fetchTMDbJSON(
                                path: "/3/movie/\(result.id)/external_ids",
                                queryItems: [],
                                credential: credential
                            )
                            attempt.hadAuthorizedResponse = true
                            if let imdbID = external.imdbID, imdbID.hasPrefix("tt") {
                                attempt.subtitleLookupID = imdbID
                                return attempt
                            }
                        } catch TMDbRequestError.unauthorized {
                            attempt.hadUnauthorizedResponse = true
                            continue
                        } catch {
                            continue
                        }
                    }

                    if let tmdbFallbackID {
                        attempt.subtitleLookupID = tmdbFallbackID
                        return attempt
                    }
                }
            }
        }

        return attempt
    }

    private func resolveTVIMDbID(
        titleCandidates: [String],
        year: Int?,
        credentials: [TMDBCredential]
    ) async throws -> TMDbLookupAttempt {
        let yearCandidates = Self.optionalYearCandidates(year)
        var attempt = TMDbLookupAttempt()

        for credential in credentials {
            for title in titleCandidates {
                for candidateYear in yearCandidates {
                    var queryItems: [URLQueryItem?] = [
                        URLQueryItem(name: "query", value: title),
                        URLQueryItem(name: "include_adult", value: "false")
                    ]
                    if let candidateYear {
                        queryItems.append(URLQueryItem(name: "first_air_date_year", value: String(candidateYear)))
                    }

                    let tvSearch: TMDbSearchResponse<TMDbTVResult>
                    do {
                        tvSearch = try await fetchTMDbJSON(
                            path: "/3/search/tv",
                            queryItems: queryItems,
                            credential: credential
                        )
                        attempt.hadAuthorizedResponse = true
                    } catch TMDbRequestError.unauthorized {
                        attempt.hadUnauthorizedResponse = true
                        continue
                    } catch {
                        continue
                    }

                    var tmdbFallbackID: String?
                    for result in tvSearch.results.prefix(5) {
                        tmdbFallbackID = tmdbFallbackID ?? String(result.id)
                        do {
                            let external: TMDbExternalIDs = try await fetchTMDbJSON(
                                path: "/3/tv/\(result.id)/external_ids",
                                queryItems: [],
                                credential: credential
                            )
                            attempt.hadAuthorizedResponse = true
                            if let imdbID = external.imdbID, imdbID.hasPrefix("tt") {
                                attempt.subtitleLookupID = imdbID
                                return attempt
                            }
                        } catch TMDbRequestError.unauthorized {
                            attempt.hadUnauthorizedResponse = true
                            continue
                        } catch {
                            continue
                        }
                    }

                    if let tmdbFallbackID {
                        attempt.subtitleLookupID = tmdbFallbackID
                        return attempt
                    }
                }
            }
        }

        return attempt
    }

    private static func extractIMDbID(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?i)tt\\d{7,9}"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 0), in: text) else {
            return nil
        }

        return String(text[range]).lowercased()
    }

    private func searchWyzieSubtitles(
        imdbID: String,
        parsed: ParsedMediaQuery,
        releaseHint: String,
        languageCode: String?
    ) async throws -> [WyzieSubtitleResult] {
        let normalizedLanguage = normalizedLanguageCode(languageCode)

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "id", value: imdbID),
            URLQueryItem(name: "format", value: "srt,vtt,ass,ssa"),
            URLQueryItem(name: "source", value: "all"),
            URLQueryItem(name: "file", value: releaseHint)
        ]

        if let season = parsed.season, let episode = parsed.episode {
            queryItems.append(URLQueryItem(name: "season", value: String(season)))
            queryItems.append(URLQueryItem(name: "episode", value: String(episode)))
        }

        if let normalizedLanguage {
            queryItems.append(URLQueryItem(name: "language", value: normalizedLanguage))
        }

        let localizedResults = try await fetchWyzieSubtitles(queryItems)
        if !localizedResults.isEmpty || normalizedLanguage == nil {
            return localizedResults
        }

        let fallbackQuery = queryItems.filter { $0.name != "language" }
        return try await fetchWyzieSubtitles(fallbackQuery)
    }

    private func fetchWyzieSubtitles(_ queryItems: [URLQueryItem]) async throws -> [WyzieSubtitleResult] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "sub.wyzie.ru"
        components.path = "/search"
        components.queryItems = queryItems

        guard let url = components.url else {
            throw SubtitleDownloadError.noSubtitleResults
        }

        let response: [WyzieSubtitleResult] = try await fetchJSON(from: url)
        return response
    }

    private func rankSubtitles(
        _ subtitles: [InternetSubtitleOption],
        releaseHint: String,
        preferredLanguage: String?
    ) -> [InternetSubtitleOption] {
        let releaseTokens = Self.tokenSet(from: releaseHint)

        return subtitles.sorted { lhs, rhs in
            score(lhs, preferredLanguage: preferredLanguage, releaseTokens: releaseTokens)
            > score(rhs, preferredLanguage: preferredLanguage, releaseTokens: releaseTokens)
        }
    }

    private func score(
        _ subtitle: InternetSubtitleOption,
        preferredLanguage: String?,
        releaseTokens: Set<String>
    ) -> Int {
        var value = 0

        switch subtitle.format.lowercased() {
        case "srt": value += 60
        case "vtt": value += 50
        case "ass", "ssa": value += 30
        default: value += 10
        }

        if let preferredLanguage, subtitle.languageCode.lowercased() == preferredLanguage {
            value += 40
        } else if subtitle.languageCode.lowercased() == "en" {
            value += 20
        }

        if !subtitle.isHearingImpaired {
            value += 5
        }

        let subtitleTokens = Self.tokenSet(from: subtitle.release ?? subtitle.fileName ?? "")
        value += releaseTokens.intersection(subtitleTokens).count * 3

        return value
    }

    private func downloadSubtitleFile(_ subtitle: InternetSubtitleOption, mediaTitle: String) async throws -> URL {
        let (data, response) = try await session.data(from: subtitle.downloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw SubtitleDownloadError.subtitleDownloadFailed
        }

        let normalizedData = normalizeSubtitleData(data, format: subtitle.format)

        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let downloadsDir = appSupportDir
            .appendingPathComponent("subtitle_downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let ext = subtitle.format.lowercased().isEmpty ? "srt" : subtitle.format.lowercased()
        let baseName = sanitizeFilename(subtitle.fileName ?? "\(mediaTitle).\(ext)")
        let languageTag = subtitle.languageCode.uppercased()
        let languageTaggedBase = baseName.hasSuffix("_\(languageTag)") ? baseName : "\(baseName)_\(languageTag)"
        let filename = languageTaggedBase.hasSuffix(".\(ext)") ? languageTaggedBase : "\(languageTaggedBase).\(ext)"
        let destURL = downloadsDir.appendingPathComponent(filename)

        try? FileManager.default.removeItem(at: destURL)
        try normalizedData.write(to: destURL, options: .atomic)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: destURL.path)
        return destURL
    }

    private func normalizeSubtitleData(_ data: Data, format: String) -> Data {
        guard format.lowercased() == "srt", var text = decodeSubtitleText(data) else {
            return data
        }

        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \ .isNewline).map(String.init)
        var output: [String] = []
        var cueIndex = 1
        var i = 0

        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                output.append("")
                i += 1
                continue
            }

            if Int(trimmed) != nil,
               i + 1 < lines.count,
               let normalizedTiming = normalizeTimingLine(lines[i + 1]) {
                output.append(String(cueIndex))
                output.append(normalizedTiming)
                cueIndex += 1
                i += 2
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    output.append(lines[i])
                    i += 1
                }
                continue
            }

            if let normalizedTiming = normalizeTimingLine(lines[i]) {
                output.append(String(cueIndex))
                output.append(normalizedTiming)
                cueIndex += 1
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    output.append(lines[i])
                    i += 1
                }
                continue
            }

            output.append(lines[i])
            i += 1
        }

        let normalizedText = output.joined(separator: "\n")
        return normalizedText.data(using: .utf8) ?? data
    }

    private func decodeSubtitleText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        if let windows = String(data: data, encoding: .windowsCP1252) {
            return windows
        }
        return nil
    }

    private func normalizeTimingLine(_ line: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*(\d{1,2}:\d{2}:\d{2}(?:[\.,]\d{1,3})?)\s*-->\s*(\d{1,2}:\d{2}:\d{2}(?:[\.,]\d{1,3})?)(.*)$"#
        ),
        let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        match.numberOfRanges >= 4,
        let startRange = Range(match.range(at: 1), in: line),
        let endRange = Range(match.range(at: 2), in: line),
        let tailRange = Range(match.range(at: 3), in: line),
        let start = canonicalSRTTimestamp(String(line[startRange])),
        let end = canonicalSRTTimestamp(String(line[endRange])) else {
            return nil
        }

        let tail = String(line[tailRange])
        return "\(start) --> \(end)\(tail)"
    }

    private func canonicalSRTTimestamp(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(
            pattern: #"^(\d{1,2}):(\d{2}):(\d{2})(?:[\.,](\d{1,3}))?$"#
        ),
        let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
        match.numberOfRanges >= 4,
        let hRange = Range(match.range(at: 1), in: trimmed),
        let mRange = Range(match.range(at: 2), in: trimmed),
        let sRange = Range(match.range(at: 3), in: trimmed),
        let hour = Int(trimmed[hRange]),
        let minute = Int(trimmed[mRange]),
        let second = Int(trimmed[sRange]) else {
            return nil
        }

        var ms = 0
        if match.range(at: 4).location != NSNotFound,
           let msRange = Range(match.range(at: 4), in: trimmed) {
            var fraction = String(trimmed[msRange])
            if fraction.count < 3 {
                fraction += String(repeating: "0", count: 3 - fraction.count)
            }
            fraction = String(fraction.prefix(3))
            ms = Int(fraction) ?? 0
        }

        return String(format: "%02d:%02d:%02d,%03d", hour, minute, second, ms)
    }

    private static func mapSubtitleOption(from result: WyzieSubtitleResult) -> InternetSubtitleOption? {
        guard let url = URL(string: result.url), url.scheme?.hasPrefix("http") == true else {
            return nil
        }

        let format = result.format.lowercased().isEmpty ? "srt" : result.format.lowercased()
        let languageCode = result.language.lowercased()
        let languageName = localizedLanguageName(for: languageCode)

        return InternetSubtitleOption(
            id: result.id,
            downloadURL: url,
            languageCode: languageCode,
            languageName: languageName,
            format: format,
            source: result.source ?? "unknown",
            release: result.release ?? result.matchedRelease,
            fileName: result.fileName,
            isHearingImpaired: result.isHearingImpaired ?? false
        )
    }

    private func normalizedLanguageCode(_ languageCode: String?) -> String? {
        if let languageCode {
            let trimmed = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty || trimmed == "any" {
                return nil
            }
            return String(trimmed.prefix(2))
        }

        if let preferred = Locale.preferredLanguages.first {
            return String(preferred.prefix(2)).lowercased()
        }
        return nil
    }

    private static func localizedLanguageName(for languageCode: String) -> String {
        let locale = Locale.current
        let normalizedCode = String(languageCode.prefix(2)).lowercased()
        if let localized = locale.localizedString(forLanguageCode: normalizedCode), !localized.isEmpty {
            return localized.capitalized
        }
        return normalizedCode.uppercased()
    }

    private func tmdbCredentialCandidates() throws -> [TMDBCredential] {
        let raw = try tmdbAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains(".") {
            var credentials: [TMDBCredential] = [.bearerToken(raw)]
            if let apiKey = Self.extractTMDbAPIKeyFromJWT(raw) {
                credentials.append(.apiKey(apiKey))
            }
            return credentials
        }
        return [.apiKey(raw)]
    }

    private func tmdbAPIKey() throws -> String {
        let keyCandidates = ["TMDB_API_KEY", "TMDBApiKey"]

        if let envKey = ProcessInfo.processInfo.environment["TMDB_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envKey.isEmpty {
            return envKey
        }

        for key in keyCandidates {
            if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        if let url = Bundle.main.url(forResource: "APIKeys", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for key in keyCandidates {
                if let value = plist[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }

        throw SubtitleDownloadError.missingTMDBAPIKey
    }

    private func fetchTMDbJSON<T: Decodable>(path: String, queryItems: [URLQueryItem?], credential: TMDBCredential) async throws -> T {
        var allQueryItems = queryItems
        if case .apiKey(let apiKey) = credential {
            allQueryItems.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        let url = tmdbURL(path: path, queryItems: allQueryItems)
        var request = URLRequest(url: url)
        if case .bearerToken(let token) = credential {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TMDbRequestError.other
        }

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw TMDbRequestError.unauthorized
            }
            throw TMDbRequestError.other
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func tmdbURL(path: String, queryItems: [URLQueryItem?]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.themoviedb.org"
        components.path = path
        components.queryItems = queryItems.compactMap { $0 }
        guard let url = components.url else {
            fatalError("Invalid TMDb URL components")
        }
        return url
    }

    private func fetchJSON<T: Decodable>(from url: URL) async throws -> T {
        try await fetchJSON(request: URLRequest(url: url))
    }

    private func fetchJSON<T: Decodable>(request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SubtitleDownloadError.tmdbLookupFailed
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private static func parseMediaQuery(from fileName: String) -> ParsedMediaQuery? {
        var text = fileName
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        text = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)

        let seasonEpisodePatterns = ["(?i)\\bS(\\d{1,2})E(\\d{1,2})\\b", "(?i)\\b(\\d{1,2})x(\\d{1,2})\\b"]
        var season: Int?
        var episode: Int?

        for pattern in seasonEpisodePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges >= 3,
                let seasonRange = Range(match.range(at: 1), in: text),
                let episodeRange = Range(match.range(at: 2), in: text) {
                season = Int(String(text[seasonRange]))
                episode = Int(String(text[episodeRange]))
                if let fullRange = Range(match.range(at: 0), in: text) {
                    text.removeSubrange(fullRange)
                }
                break
            }
        }

        var year: Int?
        if let yearRegex = try? NSRegularExpression(pattern: "\\b(19|20)\\d{2}\\b") {
            let matches = yearRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let chosenRange: Range<String.Index>? = {
                guard !matches.isEmpty else { return nil }
                if matches.count >= 2 {
                    return Range(matches.last!.range(at: 0), in: text)
                }

                guard let single = matches.first,
                      let range = Range(single.range(at: 0), in: text) else {
                    return nil
                }

                let prefix = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                let hasTextBefore = !prefix.isEmpty
                let hasTextAfter = !suffix.isEmpty

                if !hasTextBefore && hasTextAfter {
                    return nil
                }

                return range
            }()

            if let chosenRange, let parsedYear = Int(String(text[chosenRange])) {
                year = parsedYear
                text.removeSubrange(chosenRange)
            }
        }

        text = text.replacingOccurrences(of: #"[\[\]\(\)]"#, with: " ", options: .regularExpression)

        let releaseTagPattern = #"(?i)\b(2160p|1080p|720p|480p|x264|x265|h264|h265|hevc|hdr|web[- ]?dl|webrip|bluray|brrip|dvdrip|remux|proper|repack|aac|ac3|dts|yts|rarbg)\b"#
        text = text.replacingOccurrences(of: releaseTagPattern, with: " ", options: .regularExpression)

        let title = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard !title.isEmpty else { return nil }
        return ParsedMediaQuery(title: title, year: year, season: season, episode: episode)
    }

    private static func fallbackTitle(from fileName: String) -> String {
        let normalized = fileName
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? fileName : normalized
    }

    private static func tokenSet(from value: String) -> Set<String> {
        let normalized = value.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return Set(normalized.split(separator: " ").map(String.init).filter { $0.count > 1 })
    }

    private static func optionalYearCandidates(_ year: Int?) -> [Int?] {
        guard let year else { return [nil] }
        return [year, nil]
    }

    private static func tmdbTitleCandidates(from title: String, fileNameHint: String) -> [String] {
        let parsedCandidates = normalizedTitleCandidates(from: title)
        let fallbackFromFilename = fallbackTitle(from: fileNameHint)
        let filenameCandidates = normalizedTitleCandidates(from: fallbackFromFilename)

        let all = parsedCandidates + filenameCandidates
        var unique: [String] = []

        for candidate in all where !candidate.isEmpty {
            if !unique.contains(candidate) {
                unique.append(candidate)
            }
        }

        return unique
    }

    private static func normalizedTitleCandidates(from title: String) -> [String] {
        let normalized = title
            .replacingOccurrences(of: #"[\[\]\(\)]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let stripped = normalized
            .replacingOccurrences(
                of: #"(?i)\b(2160p|1080p|720p|480p|x264|x265|h264|h265|hevc|hdr|web[- ]?dl|webrip|bluray|brrip|dvdrip|remux|proper|repack|aac|ac3|dts|yts|rarbg)\b"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var candidates = [normalized]
        if !stripped.isEmpty {
            candidates.append(stripped)
        }

        if let colonVariant = yearPrefixColonVariant(from: stripped) {
            candidates.append(colonVariant)
        }

        if let withoutYearPrefix = titleWithoutLeadingYear(from: stripped) {
            candidates.append(withoutYearPrefix)
        }

        var unique: [String] = []
        for candidate in candidates where !candidate.isEmpty {
            if !unique.contains(candidate) {
                unique.append(candidate)
            }
        }
        return unique
    }

    private static func yearPrefixColonVariant(from title: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^((19|20)\d{2})\s+(.+)$"#),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              match.numberOfRanges >= 4,
              let yearRange = Range(match.range(at: 1), in: title),
              let restRange = Range(match.range(at: 3), in: title) else {
            return nil
        }

        let year = String(title[yearRange])
        let rest = String(title[restRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        return "\(year): \(rest)"
    }

    private static func titleWithoutLeadingYear(from title: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^(19|20)\d{2}\s+(.+)$"#),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              match.numberOfRanges >= 3,
              let restRange = Range(match.range(at: 2), in: title) else {
            return nil
        }

        let rest = String(title[restRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    private static func extractTMDbAPIKeyFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let aud = object["aud"] as? String,
              !aud.isEmpty else {
            return nil
        }

        return aud
    }

    private func sanitizeFilename(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: #"[^a-zA-Z0-9._-]+"#, with: "_", options: .regularExpression)
        return cleaned.isEmpty ? "subtitle" : cleaned
    }
}

private struct TMDbLookupAttempt {
    var subtitleLookupID: String?
    var hadAuthorizedResponse = false
    var hadUnauthorizedResponse = false

    mutating func merge(_ other: TMDbLookupAttempt) {
        if subtitleLookupID == nil {
            subtitleLookupID = other.subtitleLookupID
        }
        hadAuthorizedResponse = hadAuthorizedResponse || other.hadAuthorizedResponse
        hadUnauthorizedResponse = hadUnauthorizedResponse || other.hadUnauthorizedResponse
    }
}

private enum TMDbRequestError: Error {
    case unauthorized
    case other
}

private enum TMDBCredential {
    case apiKey(String)
    case bearerToken(String)
}

private struct TMDbSearchResponse<Result: Decodable>: Decodable {
    let results: [Result]
}

private struct TMDbMovieResult: Decodable {
    let id: Int
}

private struct TMDbTVResult: Decodable {
    let id: Int
}

private struct TMDbExternalIDs: Decodable {
    let imdbID: String?

    private enum CodingKeys: String, CodingKey {
        case imdbID = "imdb_id"
    }
}

private struct WyzieSubtitleResult: Decodable {
    let id: String
    let url: String
    let format: String
    let display: String?
    let language: String
    let source: String?
    let release: String?
    let fileName: String?
    let matchedRelease: String?
    let isHearingImpaired: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case url
        case format
        case display
        case language
        case source
        case release
        case fileName
        case matchedRelease
        case isHearingImpaired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let idString = try? container.decode(String.self, forKey: .id) {
            id = idString
        } else if let idNumber = try? container.decode(Int.self, forKey: .id) {
            id = String(idNumber)
        } else {
            id = UUID().uuidString
        }

        url = try container.decode(String.self, forKey: .url)
        format = try container.decode(String.self, forKey: .format)
        display = try? container.decode(String.self, forKey: .display)
        language = try container.decode(String.self, forKey: .language)
        source = try? container.decode(String.self, forKey: .source)
        release = try? container.decode(String.self, forKey: .release)
        fileName = try? container.decode(String.self, forKey: .fileName)
        matchedRelease = try? container.decode(String.self, forKey: .matchedRelease)
        isHearingImpaired = try? container.decode(Bool.self, forKey: .isHearingImpaired)
    }
}
