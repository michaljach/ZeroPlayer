import XCTest
import ComposableArchitecture
@testable import zeroplayer

@MainActor
final class AppFeatureTests: XCTestCase {
    func testFileSelectionNavigatesToPlayer() async {
        let url = URL(fileURLWithPath: "/tmp/video.mkv")

        let store = TestStore(initialState: AppFeature.State()) {
            AppFeature()
        }

        await store.send(.filePicker(.delegate(.fileSelected(url)))) {
            $0.player = PlayerFeature.State(sourceFileURL: url)
        }
    }

    func testClosePlayerReturnsToFilePicker() async {
        let url = URL(fileURLWithPath: "/tmp/video.mkv")

        let store = TestStore(
            initialState: AppFeature.State(player: PlayerFeature.State(sourceFileURL: url))
        ) {
            AppFeature()
        }

        await store.send(.player(.delegate(.closePlayer))) {
            $0.player = nil
            $0.filePicker = FilePickerFeature.State()
        }
    }
}
