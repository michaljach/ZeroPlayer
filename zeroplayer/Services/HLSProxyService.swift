import Foundation
import AVFoundation

/// Main service that coordinates FFmpeg remuxing and HTTP server for HLS playback
@Observable
final class HLSProxyService: SegmentGenerator {
    
    enum ProxyError: Error {
        case serverNotRunning
        case ffmpegFailed(Error)
        case invalidSourceFile
        case subtitleExtractionFailed(String)
        
        var localizedDescription: String {
            switch self {
            case .serverNotRunning:
                return "HTTP server failed to start. Check network entitlements."
            case .ffmpegFailed(let error):
                return "FFmpeg conversion failed: \(error.localizedDescription)"
            case .invalidSourceFile:
                return "Invalid video file format"
            case .subtitleExtractionFailed(let msg):
                return "Subtitle extraction failed: \(msg)"
            }
        }
    }
    
    // Dependencies
    private let ffmpegService: FFmpegService
    private let httpServer: LocalHTTPServer
    
    // State
    private(set) var isReady = false
    private(set) var currentVideoInfo: VideoInfo?
    var playbackURL: URL?
    private var sourceURL: URL?
    private var sourceFileURL: URL? // The actual file being streamed (for on-demand generation)
    private var isAccessingSecurityScoped = false
    
    /// Background look-ahead task that pre-generates upcoming segments
    private var lookAheadTask: Task<Void, Never>?
    
    /// Maximum number of segments to generate ahead of the last-requested segment.
    /// Prevents memory/CPU exhaustion that causes the OS to kill the app.
    private let maxLookAhead = 10
    
    /// The highest segment index that has been requested by AVPlayer (via HTTP).
    /// Look-ahead will not advance beyond lastRequestedSegment + maxLookAhead.
    private(set) var lastRequestedSegment: Int = 0
    
    // Subtitle state
    private(set) var availableSubtitles: [SubtitleTrack] = []
    var selectedSubtitle: SubtitleTrack?
    /// Maps track ID -> URL of extracted/prepared .vtt file (in output directory)
    private var subtitleVTTURLs: [String: URL] = [:]
    /// Tracks which subtitle tracks have had their HLS sub playlist generated
    private var subtitlePlaylistsGenerated: Set<String> = []
    /// Incremented each time the master playlist is regenerated (triggers player reload)
    private(set) var masterPlaylistVersion: Int = 0
    
    init() {
        self.ffmpegService = FFmpegService()
        self.httpServer = LocalHTTPServer()
    }
    
    /// Prepares a video file for playback through the HTTP server with HLS streaming
    /// Returns the local HTTP URL that can be passed to AVPlayer
    func prepareVideo(at url: URL) async throws -> URL {
        // Start accessing security-scoped resource
        isAccessingSecurityScoped = url.startAccessingSecurityScopedResource()
        sourceURL = url
        sourceFileURL = url // Store for on-demand segment generation
        
        // Step 1: Analyze the video file
        let videoInfo = try await ffmpegService.analyzeVideoFile(url)
        self.currentVideoInfo = videoInfo
        
        // Step 2: Probe for embedded subtitles
        let subtitles = try await ffmpegService.probeSubtitles(in: url)
        self.availableSubtitles = subtitles
        
        // Step 3: Start HTTP server if not running (waits until listener is ready)
        if !httpServer.isRunning {
            try await httpServer.start()
        }

        // Always expose source file path for optional diagnostics/fallback paths.
        httpServer.setSourceFile(url)

        // Always use HLS mode for AirPlay.
        // Direct-file streaming doesn't work with AirPlay receivers (Apple TV etc.)
        // because they require HLS or a perfectly fast-start-muxed MP4, and even
        // then the handshake is unreliable. HLS is the only reliable path.
        
        // Set up segment generator reference (protocol-based to avoid closure bugs)
        httpServer.segmentGenerator = self
        
        // Step 4: Generate HLS playlist (cleans output dir, writes video.m3u8 + master.m3u8)
        do {
            let _ = try await ffmpegService.generateHLSPlaylist(from: url, videoInfo: videoInfo)
        } catch {
            throw ProxyError.ffmpegFailed(error)
        }
        
        // All segments are now MPEG-TS (.ts) for both H.264 and HEVC sources.
        // No separate init segment generation needed.
        
        // Step 4b: Extract the first subtitle (if any) and regenerate master.m3u8
        // so it's available in the initial playlist. This avoids the reload dance
        // that causes AirPlay receivers to miss the subtitle track.
        if let firstSub = subtitles.first {
            do {
                let _ = try await extractAndServeSubtitle(firstSub)
                selectedSubtitle = firstSub
                try ffmpegService.regenerateMasterPlaylist(videoInfo: videoInfo, subtitleTracks: [firstSub])
                masterPlaylistVersion += 1
                print("✅ Pre-extracted subtitle: \(firstSub.displayName)")
            } catch {
                print("⚠️ Failed to pre-extract subtitle: \(error)")
            }
        }
        
        // Step 5: Get the HTTP URL for the playlist
        guard let playbackURL = httpServer.playlistURL() else {
            throw ProxyError.serverNotRunning
        }
        
        self.playbackURL = playbackURL
        self.isReady = true
        print("[HLSProxy] HLS mode active")
        
        print("✅ HLS stream ready at: \(playbackURL.absoluteString)")
        
        // Step 6: Pre-generate the first 5 segments so AVPlayer has data immediately.
        // This is critical — AVPlayer requests segments as soon as it loads the playlist
        // and will stall/fail if they're not ready fast enough.
        // 5 segments (50s) gives more buffer for HEVC transcode which is CPU-intensive.
        let pregenCount = 5
        print("⏳ Pre-generating first \(pregenCount) segments...")
        for i in 0..<pregenCount {
            do {
                let _ = try await ffmpegService.generateSegment(
                    from: url,
                    segmentIndex: i
                )
                print("✅ Segment \(i) pre-generated")
            } catch {
                print("⚠️ Failed to pre-generate segment \(i): \(error)")
                break
            }
        }
        
        // Step 7: Start background look-ahead generation
        startLookAhead(from: pregenCount)
        
        return playbackURL
    }

    // MARK: - Subtitle Management
    
    /// Extracts/prepares a subtitle track and generates its HLS subtitle playlist.
    /// Returns the local file URL of the .vtt file.
    func extractAndServeSubtitle(_ track: SubtitleTrack) async throws -> URL {
        // Check if already extracted
        if let existingURL = subtitleVTTURLs[track.id] {
            return existingURL
        }
        
        guard let sourceFile = sourceFileURL else {
            throw ProxyError.invalidSourceFile
        }
        
        let vttFileURL: URL
        
        switch track.source {
        case .embedded(let streamIndex):
            vttFileURL = try await ffmpegService.extractSubtitle(from: sourceFile, streamIndex: streamIndex)
        case .external(let fileURL):
            vttFileURL = try ffmpegService.prepareExternalSubtitle(from: fileURL)
        }
        
        subtitleVTTURLs[track.id] = vttFileURL
        
        // Generate the HLS subtitle playlist (segmented, matching video segments)
        if !subtitlePlaylistsGenerated.contains(track.id),
           let videoInfo = currentVideoInfo {
            let _ = try ffmpegService.generateSubtitlePlaylist(
                trackId: track.id,
                vttFileURL: vttFileURL,
                duration: videoInfo.durationInSeconds
            )
            subtitlePlaylistsGenerated.insert(track.id)
        }
        
        print("📝 Subtitle ready at: \(vttFileURL.path)")
        return vttFileURL
    }
    
    /// Adds an external subtitle file to the available tracks
    func addExternalSubtitle(from fileURL: URL) async throws -> SubtitleTrack {
        let filename = fileURL.deletingPathExtension().lastPathComponent
        let format = SubtitleFormat.from(url: fileURL)
        
        let track = SubtitleTrack(
            id: "external_\(filename)_\(Int(Date().timeIntervalSince1970))",
            title: filename,
            language: nil,
            source: .external(fileURL: fileURL)
        )
        
        // Pre-extract to validate the file works
        let _ = try await extractAndServeSubtitle(track)
        
        availableSubtitles.append(track)
        print("📝 Added external subtitle: \(track.displayName) (format: \(format?.rawValue ?? "unknown"))")
        
        return track
    }
    
    /// Selects a subtitle track (or nil to disable subtitles).
    /// Regenerates the master playlist and bumps `masterPlaylistVersion`
    /// so the view knows to reload the player item.
    func selectSubtitle(_ track: SubtitleTrack?) async throws -> URL? {
        selectedSubtitle = track
        
        guard let track = track else {
            // Disable subtitles — regenerate master without subtitle entries
            if let videoInfo = currentVideoInfo {
                try ffmpegService.regenerateMasterPlaylist(videoInfo: videoInfo, subtitleTracks: [])
                masterPlaylistVersion += 1
            }
            print("📝 Subtitles disabled")
            return nil
        }
        
        let vttURL = try await extractAndServeSubtitle(track)
        
        // Regenerate master playlist with this subtitle track included
        if let videoInfo = currentVideoInfo {
            try ffmpegService.regenerateMasterPlaylist(videoInfo: videoInfo, subtitleTracks: [track])
            masterPlaylistVersion += 1
        }
        
        print("📝 Selected subtitle: \(track.displayName)")
        return vttURL
    }
    
    // MARK: - Look-Ahead Segment Generation
    
    /// Starts a background task that sequentially pre-generates segments ahead of
    /// what AVPlayer has requested. This prevents stalls by having segments ready
    /// before they're needed. Only one encode runs at a time (serialized by
    /// FFmpegService.encodeQueue).
    ///
    /// Look-ahead is bounded: it will not generate more than `maxLookAhead` segments
    /// beyond `lastRequestedSegment` to prevent resource exhaustion.
    private func startLookAhead(from startIndex: Int) {
        lookAheadTask?.cancel()
        
        guard let videoInfo = currentVideoInfo,
              let sourceFile = sourceFileURL else { return }
        
        // Use probed segment count if available, otherwise fall back to fixed calculation
        let totalSegments: Int
        if !ffmpegService.segmentBoundaries.isEmpty {
            totalSegments = ffmpegService.segmentBoundaries.count
        } else {
            totalSegments = Int(ceil(videoInfo.durationInSeconds / 10.0))
        }
        
        guard startIndex < totalSegments else { return }
        
        let maxAhead = maxLookAhead
        
        lookAheadTask = Task.detached(priority: .utility) { [weak self] in
            var i = startIndex
            while i < totalSegments {
                // Check cancellation before each segment
                if Task.isCancelled { break }
                
                guard let self = self else { break }
                
                // Throttle: don't generate more than maxLookAhead segments
                // beyond the last segment AVPlayer has actually requested.
                let limit = self.lastRequestedSegment + maxAhead
                if i > limit {
                    // Wait and re-check — the player may request more segments soon
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { break }
                    continue  // Re-evaluate the limit (lastRequestedSegment may have changed)
                }
                
                do {
                    let _ = try await self.ffmpegService.generateSegment(
                        from: sourceFile,
                        segmentIndex: i
                    )
                    print("Look-ahead: segment \(i)/\(totalSegments - 1) ready")
                } catch {
                    if Task.isCancelled { break }
                    print("Look-ahead: segment \(i) failed: \(error)")
                    // Continue with next segment — transient failures shouldn't stop look-ahead
                }
                
                i += 1
            }
            if !Task.isCancelled {
                print("Look-ahead complete")
            }
        }
    }
    
    /// Protocol method: generates segment for the HTTP server.
    /// Player-requested segments get priority over look-ahead: we cancel the
    /// look-ahead task before requesting so it frees the encode semaphore slot,
    /// then restart look-ahead after the player's segment is done.
    func generateSegment(index: Int) async throws -> URL {
        guard let sourceFile = sourceFileURL,
              currentVideoInfo != nil else {
            throw ProxyError.invalidSourceFile
        }
        
        // Track the highest requested segment for look-ahead throttling.
        if index > lastRequestedSegment {
            lastRequestedSegment = index
        }
        
        // Cancel look-ahead so it releases the encode semaphore slot,
        // giving this player-requested segment priority.
        lookAheadTask?.cancel()
        lookAheadTask = nil
        
        do {
            let url = try await ffmpegService.generateSegment(
                from: sourceFile,
                segmentIndex: index
            )
            
            // Restart look-ahead from the next segment after this one
            startLookAhead(from: index + 1)
            
            return url
        } catch {
            // Still restart look-ahead even on failure
            startLookAhead(from: index + 1)
            throw ProxyError.ffmpegFailed(error)
        }
    }
    
    /// Cleans up resources
    func cleanup() {
        // Cancel any in-progress look-ahead generation
        lookAheadTask?.cancel()
        lookAheadTask = nil
        
        // Stop accessing security-scoped resource
        if isAccessingSecurityScoped, let url = sourceURL {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityScoped = false
        }
        
        httpServer.stop()
        ffmpegService.cleanup()
        isReady = false
        playbackURL = nil
        currentVideoInfo = nil
        sourceURL = nil
        sourceFileURL = nil
        lastRequestedSegment = 0
        availableSubtitles = []
        selectedSubtitle = nil
        subtitleVTTURLs = [:]
        subtitlePlaylistsGenerated = []
        masterPlaylistVersion = 0
    }
    
    deinit {
        cleanup()
    }
}

// MARK: - Convenience Extension

extension HLSProxyService {
    /// Returns formatted video duration string
    var durationString: String? {
        guard let info = currentVideoInfo else { return nil }
        let seconds = Int(info.durationInSeconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
    
    /// Returns video resolution string
    var resolutionString: String? {
        guard let info = currentVideoInfo else { return nil }
        return "\(Int(info.size.width))x\(Int(info.size.height))"
    }
}
