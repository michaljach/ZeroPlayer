import SwiftUI
import AVKit
import AVFoundation
import Combine
import ComposableArchitecture
import UniformTypeIdentifiers

/// TCA-driven video player view.
/// Holds MPVPlayerController and AVPlayer as @State (they are reference types that can't live in TCA state).
/// Bridges mpv callbacks → store.send() actions, and reads TCA state to drive the UI.
struct PlayerView: View {
    let store: StoreOf<PlayerFeature>
    
    // MPV controller — UIViewController, kept as @State since it's a reference type
    @State private var mpvController: MPVPlayerController?
    
    // AVPlayer — reference type for AirPlay mode
    @State private var avPlayer: AVPlayer?
    @State private var avPlayerObservers: Set<AnyCancellable> = []
    
    // Controls auto-hide
    @State private var hideControlsTask: Task<Void, Never>?
    
    var body: some View {
        ZStack {
            // Always keep mpv mounted so the controller persists across
            // AirPlay transitions. Hide it (opacity 0, no hit-testing)
            // while AirPlay is active to avoid duplicate playback.
            mpvPlayerView
                .opacity(store.airPlay.isAirPlaying ? 0 : 1)
                .allowsHitTesting(!store.airPlay.isAirPlaying)
            
            if store.airPlay.isAirPlaying {
                airPlayPlayerView
            }
        }
        .onAppear {
            store.send(.onAppear)
        }
        .onDisappear {
            cleanup()
            store.send(.onDisappear)
        }
        .fileImporter(
            isPresented: Binding(
                get: { store.subtitle.isShowingFilePicker },
                set: { newValue in
                    if !newValue { store.send(.subtitle(.filePickerDismissed)) }
                }
            ),
            allowedContentTypes: SubtitleFeature.subtitleUTTypes,
            allowsMultipleSelection: false
        ) { result in
            handleExternalSubtitleFile(result)
        }
        .onChange(of: store.subtitle.isShowingFilePicker) { _, isShowing in
            if !isShowing {
                scheduleHideControls()
            }
        }
        // React to AirPlay activation from TCA state
        .onChange(of: store.airPlay.isAirPlaying) { wasAirPlaying, isAirPlaying in
            if isAirPlaying && !wasAirPlaying {
                handleAirPlayActivated()
            } else if !isAirPlaying && wasAirPlaying {
                handleAirPlayDeactivated()
            }
        }
        // React to HLS URL becoming available
        .onChange(of: store.hlsPlaybackURL) { _, newURL in
            if let url = newURL, store.airPlay.isAirPlaying {
                setupAVPlayer(hlsURL: url, seekTo: store.avPlayerSeekPosition)
            }
        }
        // React to playlist version changes for subtitle reload
        .onChange(of: store.airPlay.playlistVersion) { oldVersion, newVersion in
            guard store.airPlay.isAirPlaying, newVersion > 0, newVersion != oldVersion else { return }
            reloadAVPlayerForSubtitleChange()
        }
    }
    
    // MARK: - MPV Player View
    
    @ViewBuilder
    private var mpvPlayerView: some View {
        ZStack {
            MPVRepresentableView(
                controller: $mpvController,
                fileURL: store.sourceFileURL,
                onPropertyChange: { property, value in
                    switch property {
                    case "time-pos":
                        store.send(.mpvPropertyChanged(property: property, doubleValue: value as? Double, boolValue: nil))
                    case "duration":
                        store.send(.mpvPropertyChanged(property: property, doubleValue: value as? Double, boolValue: nil))
                    case "pause", "paused-for-cache":
                        store.send(.mpvPropertyChanged(property: property, doubleValue: nil, boolValue: value as? Bool))
                    default:
                        break
                    }
                },
                onSubtitleTracksDiscovered: { tracks in
                    store.send(.mpvSubtitleTracksDiscovered(tracks))
                },
                onFileLoaded: {
                    store.send(.mpvFileLoaded)
                },
                onFileEnded: {
                    store.send(.mpvFileEnded)
                }
            )
            .ignoresSafeArea()
            
            // Buffering overlay
            if store.isBuffering || !store.isFileLoaded {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
            }
            
            // Tap to toggle controls
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    store.send(.toggleControlsTapped)
                    if store.showControls {
                        scheduleHideControls()
                    }
                }
            
            // Controls overlay
            if store.showControls {
                controlsOverlay
            }
        }
    }
    
    // MARK: - Safe Area
    
    private var safeAreaTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 0
    }
    
    // MARK: - Controls Overlay
    
    @ViewBuilder
    private var controlsOverlay: some View {
        VStack {
            // Close button at top
            HStack {
                Spacer()
                Button {
                    store.send(.closeButtonTapped)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white, .black.opacity(0.3))
                }
                .padding()
            }
            .padding(.top, safeAreaTop)
            
            Spacer()
            
            // Bottom transport controls
            mpvTransportControls
        }
        .transition(.opacity)
    }
    
    // MARK: - MPV Transport Controls
    
    private var mpvTransportControls: some View {
        VStack(spacing: 8) {
            // Seek bar
            HStack(spacing: 12) {
                Text(timeString(from: store.isSeeking ? store.seekSliderValue : store.timePos))
                    .font(.caption)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                
                Slider(
                    value: Binding(
                        get: { store.isSeeking ? store.seekSliderValue : store.timePos },
                        set: { newVal in
                            store.send(.seekSliderValueChanged(newVal))
                        }
                    ),
                    in: 0...max(store.duration, 1)
                ) { editing in
                    store.send(.seekSliderEditingChanged(editing))
                    if editing {
                        hideControlsTask?.cancel()
                    } else {
                        // Perform the actual seek via mpv
                        mpvController?.seek(to: store.seekSliderValue)
                        scheduleHideControls()
                    }
                }
                .tint(.white)
                
                Text(timeString(from: store.duration))
                    .font(.caption)
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            
            // Play/Pause + action buttons
            HStack {
                Spacer()
                
                HStack(spacing: 40) {
                    Button {
                        mpvController?.seekRelative(-10)
                        store.send(.seekBackwardTapped)
                    } label: {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                    }
                    
                    Button {
                        mpvController?.togglePause()
                        store.send(.playPauseTapped)
                    } label: {
                        Image(systemName: store.isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white)
                    }
                    
                    Button {
                        mpvController?.seekRelative(10)
                        store.send(.seekForwardTapped)
                    } label: {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                    }
                }
                
                Spacer()
                
                // Subtitle + AirPlay buttons
                HStack(spacing: 12) {
                    mpvSubtitleButton
                    airPlayRoutePickerButton
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial.opacity(0.6))
    }
    
    // MARK: - AirPlay Player View (HLS via AVPlayer)
    
    @ViewBuilder
    private var airPlayPlayerView: some View {
        ZStack {
            if let player = avPlayer {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if store.airPlay.isPreparing {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Preparing AirPlay stream...")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else if let error = store.airPlay.prepareError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.yellow)
                    Text("AirPlay Error")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else {
                ProgressView("Starting AirPlay...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
            
            VStack {
                // Close button at top
                HStack {
                    Spacer()
                    Button {
                        store.send(.closeButtonTapped)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white, .black.opacity(0.3))
                    }
                    .padding()
                }
                .padding(.top, safeAreaTop)
                
                Spacer()
                
                // Bottom action buttons
                HStack {
                    Spacer()
                    HStack(spacing: 12) {
                        hlsSubtitleButton
                        airPlayRoutePickerButton
                    }
                }
                .padding()
                .background(.ultraThinMaterial.opacity(0.6))
            }
        }
    }
    
    // MARK: - AirPlay Route Picker
    
    private var airPlayRoutePickerButton: some View {
        AirPlayRoutePickerView()
            .frame(width: 36, height: 36)
    }
    
    // MARK: - MPV Subtitle Button
    
    @ViewBuilder
    private var mpvSubtitleButton: some View {
        Menu {
            Button {
                mpvController?.disableSubtitles()
                store.send(.subtitle(.mpvSubtitlesDisabled))
            } label: {
                HStack {
                    Text("Off")
                    if store.subtitle.selectedMPVTrackId == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            if !store.subtitle.mpvTracks.isEmpty {
                Divider()
                
                ForEach(store.subtitle.mpvTracks) { track in
                    Button {
                        mpvController?.selectSubtitleTrack(track.id)
                        store.send(.subtitle(.mpvTrackSelected(track.id)))
                    } label: {
                        HStack {
                            Text(track.displayName)
                            if store.subtitle.selectedMPVTrackId == track.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            Button {
                hideControlsTask?.cancel()
                store.send(.subtitle(.loadFromFileTapped))
            } label: {
                Label("Load from File...", systemImage: "doc.badge.plus")
            }
        } label: {
            Image(systemName: store.subtitle.selectedMPVTrackId != nil ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .padding(8)
                .background(Circle().fill(.black.opacity(0.3)))
        }
    }
    
    // MARK: - HLS Subtitle Button (AirPlay mode)
    
    @ViewBuilder
    private var hlsSubtitleButton: some View {
        Menu {
            Button {
                store.send(.subtitle(.hlsSubtitlesDisabled))
            } label: {
                HStack {
                    Text("Off")
                    if store.subtitle.selectedHLSTrack == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            if !store.subtitle.hlsTracks.isEmpty {
                Divider()
                
                ForEach(store.subtitle.hlsTracks) { track in
                    Button {
                        store.send(.subtitle(.hlsTrackSelected(track)))
                    } label: {
                        HStack {
                            Text(track.displayName)
                            if store.subtitle.selectedHLSTrack == track {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            Button {
                hideControlsTask?.cancel()
                store.send(.subtitle(.loadFromFileTapped))
            } label: {
                Label("Load from File...", systemImage: "doc.badge.plus")
            }
        } label: {
            Image(systemName: store.subtitle.selectedHLSTrack != nil ? "captions.bubble.fill" : "captions.bubble")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .padding(8)
                .background(Circle().fill(.black.opacity(0.3)))
        }
    }
    
    // MARK: - AirPlay Activation / Deactivation
    
    private func handleAirPlayActivated() {
        // Pause mpv and disable video decoding to free GPU/memory
        mpvController?.pause()
        mpvController?.disableVideoTrack()
    }
    
    private func handleAirPlayDeactivated() {
        // Get position from AVPlayer before tearing it down
        let avTime = avPlayer?.currentTime().seconds ?? store.timePos
        
        // Clean up AVPlayer
        cleanupAVPlayer()
        
        // Tell TCA about the deactivation with AVPlayer's position
        store.send(.deactivateAirPlay(avPlayerPosition: avTime))
        
        // Re-enable video track and resume mpv
        mpvController?.enableVideoTrack()
        mpvController?.seek(to: avTime)
        mpvController?.play()
    }
    
    // MARK: - External Subtitle File Handling
    
    private func handleExternalSubtitleFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            
            let accessing = fileURL.startAccessingSecurityScopedResource()
            
            do {
                // Copy to temp directory while security-scoped access is active
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("subtitle_imports", isDirectory: true)
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                
                let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.copyItem(at: fileURL, to: destURL)
                
                if accessing { fileURL.stopAccessingSecurityScopedResource() }
                
                if store.airPlay.isAirPlaying {
                    // AirPlay mode: delegate to TCA for HLS subtitle pipeline
                    store.send(.subtitle(.delegate(.addExternalSubtitleHLS(destURL))))
                } else {
                    // Local mode: load directly into mpv
                    mpvController?.addExternalSubtitle(destURL.path)
                }
            } catch {
                if accessing { fileURL.stopAccessingSecurityScopedResource() }
                print("External subtitle error: \(error)")
            }
            
        case .failure(let error):
            print("Failed to pick subtitle file: \(error)")
        }
    }
    
    // MARK: - AVPlayer Management (AirPlay)
    
    private func setupAVPlayer(hlsURL: URL, seekTo position: Double) {
        cleanupAVPlayer()
        
        let asset = AVURLAsset(url: hlsURL)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 30
        
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        newPlayer.allowsExternalPlayback = true
        newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
        
        // Configure audio session for AirPlay
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
        
        self.avPlayer = newPlayer
        
        // Observe player item status
        playerItem.publisher(for: \.status)
            .sink { status in
                switch status {
                case .readyToPlay:
                    print("AirPlay: Player item ready to play")
                case .failed:
                    print("AirPlay: Player item FAILED: \(playerItem.error?.localizedDescription ?? "unknown")")
                    if let underlyingError = (playerItem.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError {
                        print("AirPlay: Underlying error: \(underlyingError)")
                    }
                default:
                    break
                }
            }
            .store(in: &avPlayerObservers)
        
        // Observe player error
        newPlayer.publisher(for: \.status)
            .sink { status in
                if status == .failed {
                    print("AirPlay: AVPlayer FAILED: \(newPlayer.error?.localizedDescription ?? "unknown")")
                    if let underlyingError = (newPlayer.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError {
                        print("AirPlay: Player underlying error: \(underlyingError)")
                    }
                }
            }
            .store(in: &avPlayerObservers)
        
        // Observe error log entries for detailed playback diagnostics
        NotificationCenter.default.publisher(for: .AVPlayerItemNewErrorLogEntry, object: playerItem)
            .sink { _ in
                if let log = playerItem.errorLog() {
                    for event in log.events {
                        print("AirPlay: Error log entry: domain=\(event.errorDomain) code=\(event.errorStatusCode) comment=\(event.errorComment ?? "none") URI=\(event.uri ?? "none")")
                    }
                }
            }
            .store(in: &avPlayerObservers)
        
        // Observe access log for successful segment fetches
        NotificationCenter.default.publisher(for: .AVPlayerItemNewAccessLogEntry, object: playerItem)
            .sink { _ in
                if let log = playerItem.accessLog(), let lastEvent = log.events.last {
                    print("AirPlay: Access log: URI=\(lastEvent.uri ?? "?") bytesTransferred=\(lastEvent.numberOfBytesTransferred) indicatedBitrate=\(lastEvent.indicatedBitrate)")
                }
            }
            .store(in: &avPlayerObservers)
        
        // Observe failed-to-play-to-end notification
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    print("AirPlay: Failed to play to end: \(error)")
                }
            }
            .store(in: &avPlayerObservers)
        
        // Observe playback stalls
        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: playerItem)
            .sink { _ in
                print("AirPlay: Playback stalled!")
                print("AirPlay: Player rate=\(newPlayer.rate) reasonForWaitingToPlay=\(newPlayer.reasonForWaitingToPlay?.rawValue ?? "none")")
            }
            .store(in: &avPlayerObservers)
        
        // Observe external playback state
        newPlayer.publisher(for: \.isExternalPlaybackActive)
            .sink { isActive in
                print("AirPlay: External playback active = \(isActive)")
            }
            .store(in: &avPlayerObservers)
        
        // Observe timeControlStatus to track play/pause/buffering state
        newPlayer.publisher(for: \.timeControlStatus)
            .sink { [weak newPlayer] status in
                guard let player = newPlayer else { return }
                switch status {
                case .paused:
                    print("AirPlay: timeControlStatus = PAUSED, rate=\(player.rate)")
                case .waitingToPlayAtSpecifiedRate:
                    print("AirPlay: timeControlStatus = WAITING, reason=\(player.reasonForWaitingToPlay?.rawValue ?? "none") rate=\(player.rate)")
                case .playing:
                    print("AirPlay: timeControlStatus = PLAYING, rate=\(player.rate) currentTime=\(player.currentTime().seconds)")
                @unknown default:
                    print("AirPlay: timeControlStatus = unknown(\(status.rawValue))")
                }
            }
            .store(in: &avPlayerObservers)
        
        // Wait for ready, seek if needed, then play
        // IMPORTANT: Use the Combine publisher sink (not AsyncPublisher) to avoid
        // missing the readyToPlay event if it fires before the async for-loop starts.
        let seekTime = position > 1.0 ? CMTime(seconds: position, preferredTimescale: 600) : nil
        var playbackStarted = false
        playerItem.publisher(for: \.status)
            .sink { [weak newPlayer] status in
                guard let player = newPlayer, !playbackStarted else { return }
                if status == .readyToPlay {
                    playbackStarted = true
                    if let seekTime {
                        print("AirPlay: Seeking to \(position)s before starting playback")
                        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                            print("AirPlay: Seek completed (finished=\(finished)), calling play()")
                            player.play()
                            print("AirPlay: play() called, rate=\(player.rate) timeControlStatus=\(player.timeControlStatus.rawValue)")
                        }
                    } else {
                        print("AirPlay: No seek needed, calling play()")
                        player.play()
                        print("AirPlay: play() called, rate=\(player.rate) timeControlStatus=\(player.timeControlStatus.rawValue)")
                    }
                    // Auto-select the subtitle track if one is pre-selected
                    Task {
                        await self.enableSubtitleTrackInAVPlayer(player)
                    }
                } else if status == .failed {
                    print("AirPlay: player item failed: \(playerItem.error?.localizedDescription ?? "unknown")")
                }
            }
            .store(in: &avPlayerObservers)
    }
    
    private func reloadAVPlayerForSubtitleChange() {
        guard let player = avPlayer, let hlsURL = store.hlsPlaybackURL else { return }
        
        let currentTime = player.currentTime()
        let wasPlaying = (player.rate > 0)
        
        var reloadURL = hlsURL
        if var components = URLComponents(url: hlsURL, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "v", value: "\(store.airPlay.playlistVersion)")]
            reloadURL = components.url ?? hlsURL
        }
        
        let asset = AVURLAsset(url: reloadURL)
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = 30
        
        player.replaceCurrentItem(with: newItem)
        
        Task {
            for await status in newItem.publisher(for: \.status).values {
                if status == .readyToPlay {
                    await player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    if wasPlaying {
                        player.play()
                    }
                    await enableSubtitleTrackInAVPlayer(player)
                    break
                } else if status == .failed {
                    print("Player item failed after subtitle reload: \(newItem.error?.localizedDescription ?? "unknown")")
                    break
                }
            }
        }
    }
    
    private func enableSubtitleTrackInAVPlayer(_ player: AVPlayer) async {
        guard let playerItem = player.currentItem else { return }
        
        guard store.subtitle.selectedHLSTrack != nil else {
            if let asset = playerItem.asset as? AVURLAsset {
                do {
                    let chars = try await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)
                    if chars.contains(.legible),
                       let group = try await asset.loadMediaSelectionGroup(for: .legible) {
                        playerItem.select(nil, in: group)
                    }
                } catch {}
            }
            return
        }
        
        try? await Task.sleep(for: .milliseconds(500))
        
        guard let asset = playerItem.asset as? AVURLAsset else { return }
        
        do {
            let chars = try await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)
            guard chars.contains(.legible),
                  let group = try await asset.loadMediaSelectionGroup(for: .legible) else { return }
            
            if let option = group.options.first {
                playerItem.select(option, in: group)
            }
        } catch {
            print("Failed to select subtitle track: \(error)")
        }
    }
    
    // MARK: - Controls Auto-Hide
    
    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            store.send(.hideControls)
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        hideControlsTask?.cancel()
        mpvController?.shutdown()
        mpvController = nil
        cleanupAVPlayer()
    }
    
    private func cleanupAVPlayer() {
        avPlayerObservers.removeAll()
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
    }
    
    // MARK: - Helpers
    
    private func timeString(from seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - MPV UIViewControllerRepresentable

struct MPVRepresentableView: UIViewControllerRepresentable {
    @Binding var controller: MPVPlayerController?
    let fileURL: URL
    var onPropertyChange: ((_ property: String, _ value: Any?) -> Void)?
    var onSubtitleTracksDiscovered: ((_ tracks: [MPVSubtitleTrack]) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onFileEnded: (() -> Void)?
    
    func makeUIViewController(context: Context) -> MPVPlayerController {
        let vc = MPVPlayerController()
        vc.fileURL = fileURL
        vc.onPropertyChange = onPropertyChange
        vc.onSubtitleTracksDiscovered = onSubtitleTracksDiscovered
        vc.onFileLoaded = onFileLoaded
        vc.onFileEnded = onFileEnded
        return vc
    }
    
    func updateUIViewController(_ uiViewController: MPVPlayerController, context: Context) {
        DispatchQueue.main.async {
            if self.controller == nil {
                self.controller = uiViewController
            }
        }
    }
}
