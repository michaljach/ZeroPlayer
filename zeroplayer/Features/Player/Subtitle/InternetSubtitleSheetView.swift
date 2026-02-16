import SwiftUI
import ComposableArchitecture

struct InternetSubtitleSheetView: View {
    let store: StoreOf<SubtitleFeature>
    let onSubtitleSelected: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Picker(
                "Language",
                selection: Binding(
                    get: { store.internetSubtitleLanguageCode },
                    set: { store.send(.internetSubtitleLanguageChanged($0)) }
                )
            ) {
                ForEach(SubtitleFeature.internetSubtitleLanguages) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            if store.isSearchingInternetSubtitles {
                ProgressView("Searching subtitles...")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = store.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if store.internetSubtitles.isEmpty && !store.isSearchingInternetSubtitles {
                ContentUnavailableView(
                    "No Subtitles",
                    systemImage: "captions.bubble",
                    description: Text("Try a different language.")
                )
            } else {
                List(store.internetSubtitles) { subtitle in
                    Button {
                        store.send(.internetSubtitleDownloadTapped(subtitle))
                        onSubtitleSelected()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(subtitle.primaryText)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(subtitle.secondaryText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(store.isDownloadingInternetSubtitle)
                }
                .listStyle(.plain)
            }
        }
        .padding()
        .navigationTitle("Download Subtitles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if store.isDownloadingInternetSubtitle {
                    ProgressView()
                }
            }
        }
        .onAppear {
            if store.internetSubtitles.isEmpty && !store.isSearchingInternetSubtitles {
                store.send(.internetSubtitleLanguageChanged(store.internetSubtitleLanguageCode))
            }
        }
    }
}
