import Dependencies
import Foundation

struct SubtitleDownloadClient {
    var downloadBestSubtitle: (_ sourceFileURL: URL) async throws -> URL
}

extension SubtitleDownloadClient: DependencyKey {
    static let liveValue: SubtitleDownloadClient = {
        let service = SubtitleDownloadService()
        return SubtitleDownloadClient(
            downloadBestSubtitle: { sourceFileURL in
                try await service.downloadBestSubtitle(for: sourceFileURL)
            }
        )
    }()

    static let testValue = SubtitleDownloadClient(
        downloadBestSubtitle: { _ in
            unimplemented("SubtitleDownloadClient.downloadBestSubtitle", placeholder: URL(fileURLWithPath: "/tmp/subtitle.srt"))
        }
    )
}

extension DependencyValues {
    var subtitleDownloadClient: SubtitleDownloadClient {
        get { self[SubtitleDownloadClient.self] }
        set { self[SubtitleDownloadClient.self] = newValue }
    }
}
