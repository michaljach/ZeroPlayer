import Dependencies
import Foundation

struct SubtitleDownloadClient {
    var searchSubtitles: (_ sourceFileURL: URL, _ languageCode: String?) async throws -> [InternetSubtitleOption]
    var downloadSubtitle: (_ subtitle: InternetSubtitleOption, _ sourceFileURL: URL) async throws -> URL
}

extension SubtitleDownloadClient: DependencyKey {
    static let liveValue: SubtitleDownloadClient = {
        let service = SubtitleDownloadService()
        return SubtitleDownloadClient(
            searchSubtitles: { sourceFileURL, languageCode in
                try await service.searchSubtitles(for: sourceFileURL, languageCode: languageCode)
            },
            downloadSubtitle: { subtitle, sourceFileURL in
                try await service.downloadSubtitle(subtitle, for: sourceFileURL)
            }
        )
    }()

    static let testValue = SubtitleDownloadClient(
        searchSubtitles: { _, _ in
            unimplemented("SubtitleDownloadClient.searchSubtitles", placeholder: [])
        },
        downloadSubtitle: { _, _ in
            unimplemented("SubtitleDownloadClient.downloadSubtitle", placeholder: URL(fileURLWithPath: "/tmp/subtitle.srt"))
        }
    )
}

extension DependencyValues {
    var subtitleDownloadClient: SubtitleDownloadClient {
        get { self[SubtitleDownloadClient.self] }
        set { self[SubtitleDownloadClient.self] = newValue }
    }
}
