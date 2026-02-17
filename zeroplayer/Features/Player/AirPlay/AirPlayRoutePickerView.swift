import SwiftUI
import AVKit

/// Platform-specific route picker used for AirPlay controls.
#if canImport(UIKit)
struct AirPlayRoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
struct AirPlayRoutePickerView: View {
    var body: some View {
        Image(systemName: "airplayaudio")
            .foregroundStyle(.secondary)
    }
}
#endif
