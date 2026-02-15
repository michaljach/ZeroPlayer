import ComposableArchitecture
import Foundation

/// Main video player feature that composes SubtitleFeature and AirPlayFeature.
struct PlayerFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        let sourceFileURL: URL

        var timePos: Double = 0
        var duration: Double = 0
        var isPaused: Bool = false
        var isBuffering: Bool = false
        var isFileLoaded: Bool = false

        var showControls: Bool = true
        var isSeeking: Bool = false
        var seekSliderValue: Double = 0

        var subtitle: SubtitleFeature.State = .init()
        var airPlay: AirPlayFeature.State = .init()

        var avPlayerSeekPosition: Double = 0
        var hlsPlaybackURL: URL? = nil
    }

    @CasePathable
    enum Action {
        case onAppear
        case onDisappear

        case mpvPropertyChanged(property: String, doubleValue: Double?, boolValue: Bool?)
        case mpvFileLoaded
        case mpvFileEnded
        case mpvSubtitleTracksDiscovered([MPVSubtitleTrack])

        case playPauseTapped
        case seekBackwardTapped
        case seekForwardTapped
        case seekSliderEditingChanged(Bool)
        case seekSliderValueChanged(Double)
        case toggleControlsTapped
        case hideControls

        case closeButtonTapped

        case activateAirPlay(currentPosition: Double)
        case deactivateAirPlay(avPlayerPosition: Double)
        case hlsPrepareCompleted(Result<URL, Error>)

        case subtitle(SubtitleFeature.Action)
        case airPlay(AirPlayFeature.Action)

        case delegate(Delegate)

        @CasePathable
        enum Delegate: Equatable {
            case closePlayer
        }
    }

    nonisolated enum CancelID: Hashable, Sendable {
        case hideControls
        case hlsPreparation
        case subtitleSelection
    }

    @Dependency(\.continuousClock) var clock
    @Dependency(\.hlsClient) var hlsClient

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .onAppear:
            return .merge(
                .send(.airPlay(.startMonitoring)),
                scheduleHideControls()
            )

        case .onDisappear:
            hlsClient.cleanup()
            return .merge(
                .cancel(id: CancelID.hideControls),
                .send(.airPlay(.stopMonitoring))
            )

        case .mpvPropertyChanged(let property, let doubleValue, let boolValue):
            switch property {
            case "time-pos":
                if let v = doubleValue, !state.isSeeking {
                    state.timePos = v
                }
            case "duration":
                if let v = doubleValue {
                    state.duration = v
                }
            case "pause":
                if let v = boolValue {
                    state.isPaused = v
                }
            case "paused-for-cache":
                if let v = boolValue {
                    state.isBuffering = v
                }
            default:
                break
            }
            return .none

        case .mpvFileLoaded:
            state.isFileLoaded = true
            return .none

        case .mpvFileEnded:
            return .none

        case .mpvSubtitleTracksDiscovered(let tracks):
            return .send(.subtitle(.mpvTracksDiscovered(tracks)))

        case .playPauseTapped:
            state.isPaused.toggle()
            return scheduleHideControls()

        case .seekBackwardTapped:
            return scheduleHideControls()

        case .seekForwardTapped:
            return scheduleHideControls()

        case .seekSliderEditingChanged(let editing):
            if editing {
                state.isSeeking = true
                state.seekSliderValue = state.timePos
                return .cancel(id: CancelID.hideControls)
            } else {
                state.isSeeking = false
                return scheduleHideControls()
            }

        case .seekSliderValueChanged(let value):
            state.seekSliderValue = value
            return .none

        case .toggleControlsTapped:
            state.showControls.toggle()
            if state.showControls {
                return scheduleHideControls()
            }
            return .none

        case .hideControls:
            state.showControls = false
            return .none

        case .closeButtonTapped:
            return .send(.delegate(.closePlayer))

        case .activateAirPlay(let currentPosition):
            state.avPlayerSeekPosition = currentPosition
            state.airPlay.isPreparing = true
            let sourceFileURL = state.sourceFileURL
            let hlsClient = self.hlsClient
            return .run { send in
                do {
                    let url = try await hlsClient.prepareVideo(sourceFileURL)
                    await send(.hlsPrepareCompleted(.success(url)))
                } catch {
                    await send(.hlsPrepareCompleted(.failure(error)))
                }
            }
            .cancellable(id: CancelID.hlsPreparation)

        case .deactivateAirPlay(let avPlayerPosition):
            state.airPlay.isAirPlaying = false
            state.hlsPlaybackURL = nil
            state.timePos = avPlayerPosition
            return .none

        case .hlsPrepareCompleted(.success(let url)):
            state.hlsPlaybackURL = url
            state.airPlay.isPreparing = false
            state.airPlay.hlsPlaybackURL = url
            state.subtitle.hlsTracks = hlsClient.availableSubtitles()
            
            // The first subtitle was pre-extracted during prepareVideo and is
            // already included in the master playlist. Just sync the UI state
            // so the button shows the correct selection — no reload needed.
            // NOTE: Do NOT set playlistVersion here — that would trigger
            // reloadAVPlayerForSubtitleChange before the player has seeked,
            // resetting position to 0.
            if let preSelected = hlsClient.selectedSubtitle() {
                state.subtitle.selectedHLSTrack = preSelected
            }
            return .none

        case .hlsPrepareCompleted(.failure(let error)):
            state.airPlay.isPreparing = false
            state.airPlay.prepareError = error.localizedDescription
            return .none

        case .subtitle(let subtitleAction):
            let childEffect = SubtitleFeature()
                .reduce(into: &state.subtitle, action: subtitleAction)
                .map(Action.subtitle)

            switch subtitleAction {
            case .delegate(.loadExternalSubtitleMPV):
                return childEffect

            case .delegate(.selectHLSSubtitle(let track)):
                let hlsClient = self.hlsClient
                let effect: Effect<Action> = .run { send in
                    do {
                        _ = try await hlsClient.selectSubtitle(track)
                        let version = hlsClient.masterPlaylistVersion()
                        await send(.airPlay(.playlistVersionChanged(version)))
                    } catch {
                        print("HLS subtitle selection failed: \(error)")
                    }
                }
                .cancellable(id: CancelID.subtitleSelection)
                return .merge(childEffect, effect)

            case .delegate(.disableHLSSubtitles):
                let hlsClient = self.hlsClient
                let effect: Effect<Action> = .run { send in
                    do {
                        _ = try await hlsClient.selectSubtitle(nil)
                        let version = hlsClient.masterPlaylistVersion()
                        await send(.airPlay(.playlistVersionChanged(version)))
                    } catch {
                        print("HLS subtitle disable failed: \(error)")
                    }
                }
                .cancellable(id: CancelID.subtitleSelection)
                return .merge(childEffect, effect)

            case .delegate(.addExternalSubtitleHLS(let url)):
                let hlsClient = self.hlsClient
                let effect: Effect<Action> = .run { send in
                    do {
                        let track = try await hlsClient.addExternalSubtitle(url)
                        let subs = hlsClient.availableSubtitles()
                        await send(.subtitle(.hlsTracksUpdated(subs)))
                        await send(.subtitle(.hlsTrackSelected(track)))
                    } catch {
                        print("HLS external subtitle add failed: \(error)")
                    }
                }
                return .merge(childEffect, effect)

            default:
                return childEffect
            }

        case .airPlay(let airPlayAction):
            let childEffect = AirPlayFeature()
                .reduce(into: &state.airPlay, action: airPlayAction)
                .map(Action.airPlay)

            switch airPlayAction {
            case .delegate(.airPlayActivated):
                // AirPlayFeature doesn't know the current playback position —
                // use the parent's timePos (from mpv) instead of the child's 0.
                return .merge(childEffect, .send(.activateAirPlay(currentPosition: state.timePos)))

            case .delegate(.airPlayDeactivated), .delegate(.hlsReady):
                return childEffect

            default:
                return childEffect
            }

        case .delegate:
            return .none
        }
    }

    private func scheduleHideControls() -> Effect<Action> {
        .run { send in
            try await clock.sleep(for: .seconds(4))
            await send(.hideControls)
        }
        .cancellable(id: CancelID.hideControls, cancelInFlight: true)
    }
}
