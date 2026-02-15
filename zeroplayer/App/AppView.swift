import SwiftUI
import ComposableArchitecture

/// Root view that switches between file picker and video player based on AppFeature state.
struct AppView: View {
    let store: StoreOf<AppFeature>
    
    var body: some View {
        if let playerStore = store.scope(state: \.player, action: \.player) {
            PlayerView(store: playerStore)
                .ignoresSafeArea()
        } else {
            FilePickerView(store: store.scope(state: \.filePicker, action: \.filePicker))
        }
    }
}
