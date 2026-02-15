import Foundation
import Dependencies

/// TCA dependency client wrapping HLSProxyService for AirPlay streaming.
/// Manages the HLS pipeline: video analysis, subtitle extraction, HTTP server,
/// and on-the-fly segment generation.
struct HLSClient {
    /// Prepares video for HLS streaming, returns the playback URL
    var prepareVideo: (_ url: URL) async throws -> URL
    /// Cleans up all HLS resources
    var cleanup: () -> Void
    /// Available subtitle tracks discovered during preparation
    var availableSubtitles: () -> [SubtitleTrack]
    /// Select a subtitle track (nil to disable)
    var selectSubtitle: (_ track: SubtitleTrack?) async throws -> URL?
    /// Add an external subtitle file
    var addExternalSubtitle: (_ url: URL) async throws -> SubtitleTrack
    /// Current master playlist version (incremented on subtitle changes)
    var masterPlaylistVersion: () -> Int
    /// Currently selected subtitle
    var selectedSubtitle: () -> SubtitleTrack?
    /// Video info after preparation
    var videoInfo: () -> VideoInfo?
}

extension HLSClient: DependencyKey {
    static let liveValue: HLSClient = {
        // Shared mutable instance — @unchecked Sendable because all mutation
        // happens through the actor-like HLSProxyService internally
        let service = MainActor.assumeIsolated { LockIsolated(HLSProxyService()) }
        
        return HLSClient(
            prepareVideo: { url in
                try await service.value.prepareVideo(at: url)
            },
            cleanup: {
                service.value.cleanup()
            },
            availableSubtitles: {
                service.value.availableSubtitles
            },
            selectSubtitle: { track in
                try await service.value.selectSubtitle(track)
            },
            addExternalSubtitle: { url in
                try await service.value.addExternalSubtitle(from: url)
            },
            masterPlaylistVersion: {
                service.value.masterPlaylistVersion
            },
            selectedSubtitle: {
                service.value.selectedSubtitle
            },
            videoInfo: {
                service.value.currentVideoInfo
            }
        )
    }()
    
    static let testValue = HLSClient(
        prepareVideo: { _ in
            unimplemented("HLSClient.prepareVideo", placeholder: URL(fileURLWithPath: "/"))
        },
        cleanup: { },
        availableSubtitles: { [] },
        selectSubtitle: { _ in
            unimplemented("HLSClient.selectSubtitle", placeholder: nil as URL?)
        },
        addExternalSubtitle: { _ in
            unimplemented(
                "HLSClient.addExternalSubtitle",
                placeholder: SubtitleTrack(
                    id: "test",
                    title: "Test",
                    language: nil,
                    source: .external(fileURL: URL(fileURLWithPath: "/tmp/test.vtt"))
                )
            )
        },
        masterPlaylistVersion: { 0 },
        selectedSubtitle: { nil },
        videoInfo: { nil }
    )
}

extension DependencyValues {
    var hlsClient: HLSClient {
        get { self[HLSClient.self] }
        set { self[HLSClient.self] = newValue }
    }
}
