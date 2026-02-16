import ComposableArchitecture
import Foundation
import UniformTypeIdentifiers

/// Child feature managing subtitle track selection and external file import.
struct SubtitleFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var mpvTracks: [MPVSubtitleTrack] = []
        var selectedMPVTrackId: Int? = nil
        var isShowingFilePicker = false
        var error: String? = nil
        var isDownloading = false
        var hlsTracks: [SubtitleTrack] = []
        var selectedHLSTrack: SubtitleTrack? = nil
    }

    @CasePathable
    enum Action {
        case mpvTracksDiscovered([MPVSubtitleTrack])
        case mpvTrackSelected(Int)
        case mpvSubtitlesDisabled
        case mpvExternalSubtitleLoaded(String)

        case hlsTracksUpdated([SubtitleTrack])
        case hlsTrackSelected(SubtitleTrack)
        case hlsSubtitlesDisabled
        case hlsSelectedSubtitleUpdated(SubtitleTrack?)

        case loadFromFileTapped
        case downloadFromInternetTapped
        case downloadSucceeded(URL)
        case downloadFailed(String)
        case filePickerDismissed
        case filePickerResult(Result<[URL], Error>)

        case delegate(Delegate)

        @CasePathable
        enum Delegate: Equatable {
            case loadExternalSubtitleMPV(URL)
            case selectHLSSubtitle(SubtitleTrack)
            case disableHLSSubtitles
            case addExternalSubtitleHLS(URL)
            case downloadFromInternetRequested
        }
    }

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .mpvTracksDiscovered(let tracks):
            state.mpvTracks = tracks
            return .none

        case .mpvTrackSelected(let trackId):
            state.selectedMPVTrackId = trackId
            return .none

        case .mpvSubtitlesDisabled:
            state.selectedMPVTrackId = nil
            return .none

        case .mpvExternalSubtitleLoaded:
            return .none

        case .hlsTracksUpdated(let tracks):
            state.hlsTracks = tracks
            return .none

        case .hlsTrackSelected(let track):
            state.selectedHLSTrack = track
            return .send(.delegate(.selectHLSSubtitle(track)))

        case .hlsSubtitlesDisabled:
            state.selectedHLSTrack = nil
            return .send(.delegate(.disableHLSSubtitles))

        case .hlsSelectedSubtitleUpdated(let track):
            state.selectedHLSTrack = track
            return .none

        case .loadFromFileTapped:
            state.isShowingFilePicker = true
            return .none

        case .downloadFromInternetTapped:
            state.isDownloading = true
            state.error = nil
            return .send(.delegate(.downloadFromInternetRequested))

        case .downloadSucceeded:
            state.isDownloading = false
            return .none

        case .downloadFailed(let message):
            state.isDownloading = false
            state.error = message
            return .none

        case .filePickerDismissed:
            state.isShowingFilePicker = false
            return .none

        case .filePickerResult(.success(let urls)):
            state.isShowingFilePicker = false
            guard let fileURL = urls.first else { return .none }

            let accessing = fileURL.startAccessingSecurityScopedResource()
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("subtitle_imports", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
            try? FileManager.default.removeItem(at: destURL)

            do {
                try FileManager.default.copyItem(at: fileURL, to: destURL)
            } catch {
                if accessing { fileURL.stopAccessingSecurityScopedResource() }
                state.error = "Failed to load subtitle file: \(error.localizedDescription)"
                return .none
            }

            if accessing { fileURL.stopAccessingSecurityScopedResource() }
            return .send(.delegate(.loadExternalSubtitleMPV(destURL)))

        case .filePickerResult(.failure(let error)):
            state.isShowingFilePicker = false
            state.error = "Failed to pick subtitle file: \(error.localizedDescription)"
            return .none

        case .delegate:
            return .none
        }
    }

    static let subtitleUTTypes: [UTType] = {
        var types: [UTType] = [.plainText]
        if let srt = UTType(filenameExtension: "srt") { types.append(srt) }
        if let vtt = UTType(filenameExtension: "vtt") { types.append(vtt) }
        if let ass = UTType(filenameExtension: "ass") { types.append(ass) }
        if let ssa = UTType(filenameExtension: "ssa") { types.append(ssa) }
        return types
    }()
}
