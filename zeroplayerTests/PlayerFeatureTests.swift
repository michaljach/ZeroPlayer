import XCTest
import ComposableArchitecture
@testable import zeroplayer

@MainActor
final class PlayerFeatureTests: XCTestCase {
    func testActivateAirPlayPreparesHLSAndSetsPlaybackURL() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mkv")
        let hlsURL = URL(string: "http://127.0.0.1:8080/master.m3u8")!
        let subtitle = SubtitleTrack(
            id: "sub-1",
            title: "English",
            language: "en",
            source: .embedded(streamIndex: 0)
        )

        let store = TestStore(initialState: PlayerFeature.State(sourceFileURL: sourceURL)) {
            PlayerFeature()
        } withDependencies: {
            $0.hlsClient.prepareVideo = { _ in hlsURL }
            $0.hlsClient.availableSubtitles = { [subtitle] }
        }

        await store.send(.activateAirPlay(currentPosition: 42)) {
            $0.avPlayerSeekPosition = 42
            $0.airPlay.isPreparing = true
        }

        await store.receive(.hlsPrepareCompleted(.success(hlsURL))) {
            $0.hlsPlaybackURL = hlsURL
            $0.airPlay.isPreparing = false
            $0.airPlay.hlsPlaybackURL = hlsURL
            $0.subtitle.hlsTracks = [subtitle]
        }
    }

    func testSelectingHLSSubtitlePublishesPlaylistVersion() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mkv")
        let subtitle = SubtitleTrack(
            id: "sub-1",
            title: "English",
            language: "en",
            source: .embedded(streamIndex: 0)
        )

        let store = TestStore(initialState: PlayerFeature.State(sourceFileURL: sourceURL)) {
            PlayerFeature()
        } withDependencies: {
            $0.hlsClient.selectSubtitle = { _ in nil }
            $0.hlsClient.masterPlaylistVersion = { 3 }
        }

        await store.send(.subtitle(.hlsTrackSelected(subtitle))) {
            $0.subtitle.selectedHLSTrack = subtitle
        }

        await store.receive(.subtitle(.delegate(.selectHLSSubtitle(subtitle))))
        await store.receive(.airPlay(.playlistVersionChanged(3))) {
            $0.airPlay.playlistVersion = 3
        }
    }
}

extension PlayerFeature.Action: Equatable {
    public static func == (lhs: PlayerFeature.Action, rhs: PlayerFeature.Action) -> Bool {
        switch (lhs, rhs) {
        case let (.hlsPrepareCompleted(.success(l)), .hlsPrepareCompleted(.success(r))):
            return l == r
        case let (.hlsPrepareCompleted(.failure(l)), .hlsPrepareCompleted(.failure(r))):
            return l.localizedDescription == r.localizedDescription
        case let (.subtitle(.delegate(.selectHLSSubtitle(l))), .subtitle(.delegate(.selectHLSSubtitle(r)))):
            return l == r
        case let (.airPlay(.playlistVersionChanged(l)), .airPlay(.playlistVersionChanged(r))):
            return l == r
        default:
            return false
        }
    }
}
