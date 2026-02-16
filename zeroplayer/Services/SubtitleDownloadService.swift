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
    case couldNotParseMediaName
    case tmdbLookupFailed
    case imdbIDNotFound
    case noSubtitleResults
    case subtitleDownloadFailed

    var errorDescription: String? {
        switch self {
        case .missingTMDBAPIKey:
            return "Missing TMDb API credential. Set TMDB_API_KEY in APIKeys.plist."
        case .couldNotParseMediaName:
            return "Could not parse title from the video file name."
        case .tmdbLookupFailed:
            return "TMDb lookup failed for this media."
        case .imdbIDNotFound:
            return "TMDb did not return an IMDb ID for this media."
        case .noSubtitleResults:
            return "No downloadable subtitles found on sub.wyzie.ru."
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

    func downloadBestSubtitle(for sourceFileURL: URL) async throws -> URL {
        let filename = sourceFileURL.deletingPathExtension().lastPathComponent
        guard let parsed = Self.parseMediaQuery(from: filename) else {
            throw SubtitleDownloadError.couldNotParseMediaName
        }

        let imdbID = try await resolveIMDbID(for: parsed)
        let subtitles = try await searchWyzieSubtitles(imdbID: imdbID, parsed: parsed, releaseHint: filename)
        guard let best = chooseBestSubtitle(from: subtitles, releaseHint: filename) else {
            throw SubtitleDownloadError.noSubtitleResults
        }

        return try await downloadSubtitleFile(best, mediaTitle: parsed.title)
    }

    private func resolveIMDbID(for parsed: ParsedMediaQuery) async throws -> String {
        let credential = try tmdbCredential()

        if parsed.isTVEpisode {
            let tvSearch: TMDbSearchResponse<TMDbTVResult> = try await fetchTMDbJSON(
                path: "/3/search/tv",
                queryItems: [
                URLQueryItem(name: "query", value: parsed.title),
                URLQueryItem(name: "include_adult", value: "false"),
                URLQueryItem(name: "first_air_date_year", value: parsed.year.map(String.init))
                ],
                credential: credential
            )
            guard let best = tvSearch.results.first else {
                throw SubtitleDownloadError.tmdbLookupFailed
            }

            let external: TMDbExternalIDs = try await fetchTMDbJSON(
                path: "/3/tv/\(best.id)/external_ids",
                queryItems: [],
                credential: credential
            )
            guard let imdbID = external.imdbID, imdbID.hasPrefix("tt") else {
                throw SubtitleDownloadError.imdbIDNotFound
            }
            return imdbID
        } else {
            let movieSearch: TMDbSearchResponse<TMDbMovieResult> = try await fetchTMDbJSON(
                path: "/3/search/movie",
                queryItems: [
                URLQueryItem(name: "query", value: parsed.title),
                URLQueryItem(name: "include_adult", value: "false"),
                URLQueryItem(name: "year", value: parsed.year.map(String.init))
                ],
                credential: credential
            )
            guard let best = movieSearch.results.first else {
                throw SubtitleDownloadError.tmdbLookupFailed
            }

            let external: TMDbExternalIDs = try await fetchTMDbJSON(
                path: "/3/movie/\(best.id)/external_ids",
                queryItems: [],
                credential: credential
            )
            guard let imdbID = external.imdbID, imdbID.hasPrefix("tt") else {
                throw SubtitleDownloadError.imdbIDNotFound
            }
            return imdbID
        }
    }

    private func searchWyzieSubtitles(imdbID: String, parsed: ParsedMediaQuery, releaseHint: String) async throws -> [WyzieSubtitleResult] {
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

        let languageCode = Locale.preferredLanguages.first.map { String($0.prefix(2)).lowercased() }
        if let languageCode {
            queryItems.append(URLQueryItem(name: "language", value: languageCode))
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "sub.wyzie.ru"
        components.path = "/search"
        components.queryItems = queryItems

        guard let url = components.url else {
            throw SubtitleDownloadError.noSubtitleResults
        }

        let localizedResults: [WyzieSubtitleResult] = try await fetchJSON(from: url)
        if !localizedResults.isEmpty || languageCode == nil {
            return localizedResults
        }

        var fallbackComponents = components
        fallbackComponents.queryItems = queryItems.filter { $0.name != "language" }
        guard let fallbackURL = fallbackComponents.url else {
            return localizedResults
        }

        return try await fetchJSON(from: fallbackURL)
    }

    private func chooseBestSubtitle(from subtitles: [WyzieSubtitleResult], releaseHint: String) -> WyzieSubtitleResult? {
        guard !subtitles.isEmpty else { return nil }

        let preferredLanguage = Locale.preferredLanguages.first?.prefix(2).lowercased()
        let releaseTokens = Self.tokenSet(from: releaseHint)

        return subtitles
            .filter { subtitle in
                guard let url = URL(string: subtitle.url) else { return false }
                return url.scheme?.hasPrefix("http") == true
            }
            .sorted { lhs, rhs in
                score(lhs, preferredLanguage: preferredLanguage, releaseTokens: releaseTokens)
                > score(rhs, preferredLanguage: preferredLanguage, releaseTokens: releaseTokens)
            }
            .first
    }

    private func score(_ subtitle: WyzieSubtitleResult, preferredLanguage: String?, releaseTokens: Set<String>) -> Int {
        var value = 0

        switch subtitle.format.lowercased() {
        case "srt": value += 60
        case "vtt": value += 50
        case "ass", "ssa": value += 30
        default: value += 10
        }

        if let preferredLanguage, subtitle.language.lowercased() == preferredLanguage {
            value += 40
        } else if subtitle.language.lowercased() == "en" {
            value += 20
        }

        if subtitle.isHearingImpaired == false {
            value += 5
        }

        let subtitleTokens = Self.tokenSet(from: subtitle.release ?? subtitle.fileName ?? "")
        value += releaseTokens.intersection(subtitleTokens).count * 3

        return value
    }

    private func downloadSubtitleFile(_ subtitle: WyzieSubtitleResult, mediaTitle: String) async throws -> URL {
        guard let url = URL(string: subtitle.url) else {
            throw SubtitleDownloadError.subtitleDownloadFailed
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw SubtitleDownloadError.subtitleDownloadFailed
        }

        let downloadsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subtitle_downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let ext = subtitle.format.lowercased().isEmpty ? "srt" : subtitle.format.lowercased()
        let baseName = sanitizeFilename(subtitle.fileName ?? "\(mediaTitle).\(ext)")
        let filename = baseName.hasSuffix(".\(ext)") ? baseName : "\(baseName).\(ext)"
        let destURL = downloadsDir.appendingPathComponent(filename)

        try? FileManager.default.removeItem(at: destURL)
        try data.write(to: destURL, options: .atomic)
        return destURL
    }

    private func tmdbCredential() throws -> TMDBCredential {
        let raw = try tmdbAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains(".") {
            return .bearerToken(raw)
        }
        return .apiKey(raw)
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

        return try await fetchJSON(request: request)
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
                    text = String(text[..<fullRange.lowerBound])
                }
                break
            }
        }

        var year: Int?
        if let yearRegex = try? NSRegularExpression(pattern: "\\b(19|20)\\d{2}\\b"),
           let match = yearRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 0), in: text),
           let y = Int(String(text[range])) {
            year = y
            text = String(text[..<range.lowerBound])
        }

        let title = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard !title.isEmpty else { return nil }
        return ParsedMediaQuery(title: title, year: year, season: season, episode: episode)
    }

    private static func tokenSet(from value: String) -> Set<String> {
        let normalized = value.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return Set(normalized.split(separator: " ").map(String.init).filter { $0.count > 1 })
    }

    private func sanitizeFilename(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: #"[^a-zA-Z0-9._-]+"#, with: "_", options: .regularExpression)
        return cleaned.isEmpty ? "subtitle" : cleaned
    }
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
    let url: String
    let format: String
    let language: String
    let release: String?
    let fileName: String?
    let isHearingImpaired: Bool?
}
