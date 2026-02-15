import ComposableArchitecture
import Foundation
import AVFoundation
import Combine

/// Child feature managing AirPlay detection, HLS preparation, and AVPlayer lifecycle.
struct AirPlayFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var isAirPlaying = false
        var hlsPlaybackURL: URL? = nil
        var isPreparing = false
        var prepareError: String? = nil
        var playlistVersion: Int = 0
    }

    @CasePathable
    enum Action {
        case startMonitoring
        case stopMonitoring
        case airPlayRouteChanged(isActive: Bool)
        case airPlayRouteStabilized(isActive: Bool)
        case prepareHLS(seekTo: Double)
        case hlsPrepared(URL)
        case hlsPrepareFailed(String)
        case playlistVersionChanged(Int)
        case delegate(Delegate)

        enum Delegate: Equatable {
            case airPlayActivated
            case airPlayDeactivated
            case hlsReady(playbackURL: URL, seekTo: Double)
        }
    }

    nonisolated enum CancelID: Hashable, Sendable {
        case routeMonitoring
        case hlsPreparation
        case airPlayDeactivateDebounce
    }

    @Dependency(\.audioSession) var audioSession
    @Dependency(\.continuousClock) var clock
    @Dependency(\.hlsClient) var hlsClient

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .startMonitoring:
            let audioSession = self.audioSession
            return .run { send in
                try? audioSession.configure()
                for await isActive in audioSession.airPlayRouteChanges() {
                    await send(.airPlayRouteChanged(isActive: isActive))
                }
            }
            .cancellable(id: CancelID.routeMonitoring)

        case .stopMonitoring:
            return .merge(
                .cancel(id: CancelID.routeMonitoring),
                .cancel(id: CancelID.airPlayDeactivateDebounce)
            )

        case .airPlayRouteChanged(let isActive):
            if isActive {
                if !state.isAirPlaying {
                    state.isAirPlaying = true
                    return .merge(
                        .cancel(id: CancelID.airPlayDeactivateDebounce),
                        .send(.delegate(.airPlayActivated))
                    )
                }
                return .cancel(id: CancelID.airPlayDeactivateDebounce)
            } else if state.isAirPlaying {
                // Route-change notifications are noisy during AirPlay startup/handshake.
                // Debounce deactivation and re-check actual route state before tearing down.
                let audioSession = self.audioSession
                return .run { send in
                    try await clock.sleep(for: .seconds(2))
                    await send(.airPlayRouteStabilized(isActive: audioSession.isAirPlayActive()))
                }
                .cancellable(id: CancelID.airPlayDeactivateDebounce, cancelInFlight: true)
            }
            return .none

        case .airPlayRouteStabilized(let isActive):
            if !isActive && state.isAirPlaying {
                state.isAirPlaying = false
                return .send(.delegate(.airPlayDeactivated))
            }
            return .none

        case .prepareHLS:
            state.isPreparing = true
            state.prepareError = nil
            return .run { [hlsURL = state.hlsPlaybackURL] send in
                if let existingURL = hlsURL {
                    await send(.hlsPrepared(existingURL))
                }
            }
            .cancellable(id: CancelID.hlsPreparation)

        case .hlsPrepared(let url):
            state.hlsPlaybackURL = url
            state.isPreparing = false
            return .none

        case .hlsPrepareFailed(let error):
            state.prepareError = error
            state.isPreparing = false
            return .none

        case .playlistVersionChanged(let version):
            state.playlistVersion = version
            return .none

        case .delegate:
            return .none
        }
    }
}
