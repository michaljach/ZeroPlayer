import SwiftUI
import ComposableArchitecture
import UniformTypeIdentifiers

struct FilePickerView: View {
    let store: StoreOf<FilePickerFeature>
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            
            Text("Select a Video File")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Choose an MKV or other video file to play")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                store.send(.browseButtonTapped)
            } label: {
                Label("Browse Files", systemImage: "folder")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding()
        .fileImporter(
            isPresented: Binding(
                get: { store.isShowingPicker },
                set: { newValue in
                    if !newValue { store.send(.pickerDismissed) }
                }
            ),
            allowedContentTypes: [
                .movie,
                .video,
                UTType(filenameExtension: "mkv") ?? .data
            ],
            allowsMultipleSelection: false
        ) { result in
            store.send(.filePickerResult(result))
        }
    }
}
