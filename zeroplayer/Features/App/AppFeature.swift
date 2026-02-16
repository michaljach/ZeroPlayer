import ComposableArchitecture

/// Root feature that manages navigation between file picker and video player.
struct AppFeature: Reducer {
    @ObservableState
    struct State: Equatable {
        var filePicker = FilePickerFeature.State()
        var player: PlayerFeature.State?
    }

    @CasePathable
    enum Action {
        case filePicker(FilePickerFeature.Action)
        case player(PlayerFeature.Action)
    }

    func reduce(into state: inout State, action: Action) -> Effect<Action> {
        switch action {
        case .filePicker(let filePickerAction):
            let effect = FilePickerFeature()
                .reduce(into: &state.filePicker, action: filePickerAction)
                .map(Action.filePicker)

            if case .delegate(.fileSelected(let url)) = filePickerAction {
                state.player = PlayerFeature.State(sourceFileURL: url)
            }

            return effect

        case .player(let playerAction):
            guard var playerState = state.player else { return .none }

            let effect = PlayerFeature()
                .reduce(into: &playerState, action: playerAction)
                .map(Action.player)

            if case .delegate(.closePlayer) = playerAction {
                state.player = nil
                state.filePicker = FilePickerFeature.State()
            } else {
                state.player = playerState
            }

            return effect
        }
    }
}
