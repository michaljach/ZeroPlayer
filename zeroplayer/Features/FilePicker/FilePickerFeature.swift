import ComposableArchitecture
import Foundation

/// Feature for selecting video files from the device.
struct FilePickerFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var isShowingPicker = false
    }

    @CasePathable
    enum Action {
        case browseButtonTapped
        case pickerDismissed
        case filePickerResult(Result<[URL], Error>)
        case delegate(Delegate)

        enum Delegate {
            case fileSelected(URL)
        }
    }

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .browseButtonTapped:
            state.isShowingPicker = true
            return .none

        case .pickerDismissed:
            state.isShowingPicker = false
            return .none

        case .filePickerResult(.success(let urls)):
            state.isShowingPicker = false
            guard let url = urls.first else { return .none }
            _ = url.startAccessingSecurityScopedResource()
            return .send(.delegate(.fileSelected(url)))

        case .filePickerResult(.failure(let error)):
            state.isShowingPicker = false
            print("File selection error: \(error)")
            return .none

        case .delegate:
            return .none
        }
    }
}
