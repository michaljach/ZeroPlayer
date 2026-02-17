import Foundation
import Dependencies
@preconcurrency import ObjectiveC
import AVFoundation

/// TCA dependency client for audio session and AirPlay route detection
struct AudioSessionClient: Sendable {
    /// Configures audio session for playback
    var configure: @Sendable () throws -> Void
    /// Returns an AsyncStream of whether AirPlay is currently active
    var airPlayRouteChanges: @Sendable () -> AsyncStream<Bool>
    /// Checks if AirPlay is currently active
    var isAirPlayActive: @Sendable () -> Bool
}

nonisolated private final class ObserverTokenBox: @unchecked Sendable {
    let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }
}

extension AudioSessionClient: DependencyKey {
    static let liveValue = AudioSessionClient(
        configure: {
#if os(iOS) || targetEnvironment(macCatalyst)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
#endif
        },
        airPlayRouteChanges: {
            AsyncStream { continuation in
#if os(iOS) || targetEnvironment(macCatalyst)
                let observer = NotificationCenter.default.addObserver(
                    forName: AVAudioSession.routeChangeNotification,
                    object: nil,
                    queue: .main
                ) { _ in
                    let currentRoute = AVAudioSession.sharedInstance().currentRoute
                    let hasAirPlay = currentRoute.outputs.contains {
                        $0.portType == .airPlay
                    }
                    continuation.yield(hasAirPlay)
                }
                let observerBox = ObserverTokenBox(observer)
                
                // Emit initial state
                let currentRoute = AVAudioSession.sharedInstance().currentRoute
                let hasAirPlay = currentRoute.outputs.contains {
                    $0.portType == .airPlay
                }
                continuation.yield(hasAirPlay)
                
                continuation.onTermination = { _ in
                    Task { @MainActor in
                        NotificationCenter.default.removeObserver(observerBox.token)
                    }
                }
#else
                continuation.yield(false)
                continuation.finish()
#endif
            }
        },
        isAirPlayActive: {
#if os(iOS) || targetEnvironment(macCatalyst)
            let currentRoute = AVAudioSession.sharedInstance().currentRoute
            return currentRoute.outputs.contains { $0.portType == .airPlay }
#else
            return false
#endif
        }
    )
    
    static let testValue = AudioSessionClient(
        configure: { },
        airPlayRouteChanges: { AsyncStream { $0.finish() } },
        isAirPlayActive: { false }
    )
}

extension DependencyValues {
    var audioSession: AudioSessionClient {
        get { self[AudioSessionClient.self] }
        set { self[AudioSessionClient.self] = newValue }
    }
}
