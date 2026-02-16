import ComposableArchitecture
import Foundation
import UniformTypeIdentifiers

struct SubtitleFeature: Reducer {
    struct InternetSubtitleLanguage: Equatable, Identifiable {
        let code: String
        let name: String

        var id: String { code }
    }

    @ObservableState
    struct State: Equatable {
        var mpvTracks: [MPVSubtitleTrack] = []
        var selectedMPVTrackId: Int? = nil
        var isShowingFilePicker = false
        var error: String? = nil
        var hlsTracks: [SubtitleTrack] = []
        var selectedHLSTrack: SubtitleTrack? = nil

        var isShowingInternetSubtitleSheet = false
        var internetSubtitleLanguageCode = SubtitleFeature.defaultLanguageCode
        var internetSubtitles: [InternetSubtitleOption] = []
        var isSearchingInternetSubtitles = false
        var isDownloadingInternetSubtitle = false
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
        case filePickerDismissed
        case filePickerResult(Result<[URL], Error>)

        case downloadFromInternetTapped
        case internetSubtitleSheetDismissed
        case internetSubtitleLanguageChanged(String)
        case internetSubtitleSearchStarted
        case internetSubtitleSearchSucceeded([InternetSubtitleOption])
        case internetSubtitleSearchFailed(String)
        case internetSubtitleDownloadTapped(InternetSubtitleOption)
        case internetSubtitleDownloadSucceeded(URL)
        case internetSubtitleDownloadFailed(String)

        case delegate(Delegate)

        @CasePathable
        enum Delegate: Equatable {
            case loadExternalSubtitleMPV(URL)
            case selectHLSSubtitle(SubtitleTrack)
            case disableHLSSubtitles
            case addExternalSubtitleHLS(URL)
            case searchInternetSubtitles(languageCode: String)
            case downloadInternetSubtitle(InternetSubtitleOption)
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

        case .downloadFromInternetTapped:
            state.error = nil
            state.isShowingInternetSubtitleSheet = true
            state.internetSubtitles = []
            state.isSearchingInternetSubtitles = true
            return .send(.delegate(.searchInternetSubtitles(languageCode: state.internetSubtitleLanguageCode)))

        case .internetSubtitleSheetDismissed:
            state.isShowingInternetSubtitleSheet = false
            state.isSearchingInternetSubtitles = false
            state.isDownloadingInternetSubtitle = false
            return .none

        case .internetSubtitleLanguageChanged(let code):
            state.internetSubtitleLanguageCode = code
            state.isSearchingInternetSubtitles = true
            state.internetSubtitles = []
            state.error = nil
            return .send(.delegate(.searchInternetSubtitles(languageCode: code)))

        case .internetSubtitleSearchStarted:
            state.isSearchingInternetSubtitles = true
            state.error = nil
            return .none

        case .internetSubtitleSearchSucceeded(let subtitles):
            state.isSearchingInternetSubtitles = false
            state.internetSubtitles = subtitles
            return .none

        case .internetSubtitleSearchFailed(let message):
            state.isSearchingInternetSubtitles = false
            state.internetSubtitles = []
            state.error = message
            return .none

        case .internetSubtitleDownloadTapped(let subtitle):
            state.isDownloadingInternetSubtitle = true
            state.error = nil
            return .send(.delegate(.downloadInternetSubtitle(subtitle)))

        case .internetSubtitleDownloadSucceeded:
            state.isDownloadingInternetSubtitle = false
            state.isShowingInternetSubtitleSheet = false
            return .none

        case .internetSubtitleDownloadFailed(let message):
            state.isDownloadingInternetSubtitle = false
            state.error = message
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

    static let internetSubtitleLanguages: [InternetSubtitleLanguage] = [
        .init(code: "any", name: "Any"),
        .init(code: "en", name: "English"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "ru", name: "Russian"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "tr", name: "Turkish"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "pl", name: "Polish")
    ]

    static var defaultLanguageCode: String {
        if let preferred = Locale.preferredLanguages.first {
            let code = String(preferred.prefix(2)).lowercased()
            if internetSubtitleLanguages.contains(where: { $0.code == code }) {
                return code
            }
        }
        return "en"
    }
}
