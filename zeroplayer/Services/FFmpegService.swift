import Foundation
import AVFoundation
import Libmpv
import Libavformat
import Libavcodec
import Libavutil
import Libswresample
import Libswscale

/// Service responsible for video transcoding, subtitle extraction, and HLS playlist generation.
/// Uses libmpv (via MPVKit) for all media operations — no FFmpegKit dependency.
@Observable
final class FFmpegService {
    private enum VideoEncoder: String {
        case h264VideoToolbox
        case h264VideoToolboxSafe
        case libx264Software
    }
    
    enum FFmpegError: Error {
        case invalidInputFile
        case conversionFailed(String)
        case unsupportedFormat
        case mpvFailed(String)
    }
    
    // Temporary directory for converted files
    private let outputDirectory: URL
    
    /// Tracks in-flight segment generation to prevent concurrent mpv invocations
    /// for the same segment index. Maps segment index -> continuation list.
    private var inFlightSegments: [Int: [CheckedContinuation<URL, Error>]] = [:]
    
    /// Concurrent queue for encoding — allows multiple segments to transcode in parallel.
    /// Parallelism is bounded by `encodeSemaphore` to avoid resource exhaustion.
    private let encodeQueue = DispatchQueue(label: "com.zeroplayer.encode", qos: .userInitiated, attributes: .concurrent)
    
    /// Limits concurrent transcode operations. On iPhone, 2 concurrent transcodes
    /// (each using multi-threaded HEVC decode + VideoToolbox H.264 encode) provides
    /// good throughput without saturating CPU or memory.
    private let encodeSemaphore = DispatchSemaphore(value: 2)
    
    init() {
        // Create a temporary directory for output
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("video_output", isDirectory: true)
        
        self.outputDirectory = tempDir
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    /// Analyzes video file to check if conversion is needed.
    ///
    /// Uses FFmpeg C API instead of AVURLAsset because AVURLAsset has very limited
    /// container support on iOS — MKV, AVI, etc. often fail to probe, causing
    /// AirPlay preparation to error out.
    func analyzeVideoFile(_ url: URL) async throws -> VideoInfo {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VideoInfo, Error>) in
            encodeQueue.async {
                self.encodeSemaphore.wait()
                defer { self.encodeSemaphore.signal() }
                do {
                    let result = try self.analyzeVideoFileSync(url)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func analyzeVideoFileSync(_ url: URL) throws -> VideoInfo {
        let inputPath = url.path
        
        var inputCtx: UnsafeMutablePointer<AVFormatContext>?
        var ret = avformat_open_input(&inputCtx, inputPath, nil, nil)
        guard ret >= 0, inputCtx != nil else {
            throw FFmpegError.conversionFailed("analyzeVideoFile: avformat_open_input failed: \(Self.ffmpegErrorString(ret))")
        }
        defer {
            var ctx = inputCtx
            avformat_close_input(&ctx)
        }
        
        ret = avformat_find_stream_info(inputCtx, nil)
        guard ret >= 0 else {
            throw FFmpegError.conversionFailed("analyzeVideoFile: avformat_find_stream_info failed: \(Self.ffmpegErrorString(ret))")
        }
        
        let nbStreams = Int(inputCtx!.pointee.nb_streams)
        
        var videoCodecName: String?
        var audioCodecName: String?
        var videoWidth: Int32 = 0
        var videoHeight: Int32 = 0
        var hasVideo = false
        var hasAudio = false
        var needsAudioConversion = false
        var isHEVC = false
        var hevcCodecString: String? = nil
        
        for i in 0..<nbStreams {
            let stream = inputCtx!.pointee.streams[i]!
            let codecpar = stream.pointee.codecpar.pointee
            
            if codecpar.codec_type == AVMEDIA_TYPE_VIDEO && !hasVideo {
                hasVideo = true
                videoWidth = codecpar.width
                videoHeight = codecpar.height
                isHEVC = codecpar.codec_id == AV_CODEC_ID_HEVC
                if let desc = avcodec_descriptor_get(codecpar.codec_id) {
                    videoCodecName = String(cString: desc.pointee.name)
                }
                // Parse HEVCDecoderConfigurationRecord from extradata to build
                // the correct CODECS string for HLS master playlist.
                // Format: hvc1.<profile>.<compat_hex>.<tier><level>.<constraints>
                if isHEVC, codecpar.extradata != nil, codecpar.extradata_size >= 13 {
                    let extra = codecpar.extradata!
                    let configVersion = extra[0]
                    if configVersion == 1 {
                        let byte1 = extra[1]
                        let profileSpace = (byte1 >> 6) & 0x03
                        let tierFlag = (byte1 >> 5) & 0x01
                        let profileIDC = byte1 & 0x1F
                        
                        // Profile compatibility flags (4 bytes, big-endian)
                        let compatFlags: UInt32 = (UInt32(extra[2]) << 24) | (UInt32(extra[3]) << 16) |
                                                  (UInt32(extra[4]) << 8) | UInt32(extra[5])
                        // Reverse the bit order of compatFlags for the CODECS string
                        var reversed: UInt32 = 0
                        var cf = compatFlags
                        for _ in 0..<32 {
                            reversed = (reversed << 1) | (cf & 1)
                            cf >>= 1
                        }
                        
                        // Constraint indicator flags (6 bytes)
                        let constraints = (0..<6).map { extra[6 + $0] }
                        
                        let levelIDC = extra[12]
                        
                        // Build profile prefix
                        let profilePrefix: String
                        switch profileSpace {
                        case 1: profilePrefix = "A"
                        case 2: profilePrefix = "B"
                        case 3: profilePrefix = "C"
                        default: profilePrefix = ""
                        }
                        
                        let tierChar = tierFlag == 1 ? "H" : "L"
                        
                        // Build constraint string: bytes as hex, trim trailing zeros
                        var constraintStr = ""
                        var lastNonZero = -1
                        for j in stride(from: 5, through: 0, by: -1) {
                            if constraints[j] != 0 {
                                lastNonZero = j
                                break
                            }
                        }
                        if lastNonZero >= 0 {
                            constraintStr = "." + (0...lastNonZero).map { String(format: "%02X", constraints[$0]) }.joined(separator: ".")
                        }
                        
                        hevcCodecString = "hvc1.\(profilePrefix)\(profileIDC).\(String(format: "%X", reversed)).\(tierChar)\(levelIDC)\(constraintStr)"
                        print("HEVC codec string from extradata: \(hevcCodecString!)")
                        print("  configVersion=\(configVersion) profileSpace=\(profileSpace) tier=\(tierFlag) profileIDC=\(profileIDC)")
                        print("  compatFlags=0x\(String(format: "%08X", compatFlags)) reversed=0x\(String(format: "%08X", reversed))")
                        print("  levelIDC=\(levelIDC) constraints=\(constraints.map { String(format: "%02X", $0) }.joined(separator: " "))")
                    }
                }
            } else if codecpar.codec_type == AVMEDIA_TYPE_AUDIO && !hasAudio {
                hasAudio = true
                if let desc = avcodec_descriptor_get(codecpar.codec_id) {
                    audioCodecName = String(cString: desc.pointee.name)
                }
                // MPEG-TS supports: AAC, AC3, EAC3, MP2, MP3
                // Codecs that need conversion: Opus, Vorbis, FLAC, DTS, TrueHD, PCM, etc.
                let tsCompatibleAudio: Set<UInt32> = [
                    AV_CODEC_ID_AAC.rawValue,
                    AV_CODEC_ID_AC3.rawValue,
                    AV_CODEC_ID_EAC3.rawValue,
                    AV_CODEC_ID_MP3.rawValue,
                    AV_CODEC_ID_MP2.rawValue,
                ]
                needsAudioConversion = !tsCompatibleAudio.contains(codecpar.codec_id.rawValue)
            }
        }
        
        guard hasVideo else {
            throw FFmpegError.unsupportedFormat
        }
        
        // Get duration from format context (in AV_TIME_BASE units = microseconds)
        let durationSeconds: Double
        if inputCtx!.pointee.duration > 0 {
            durationSeconds = Double(inputCtx!.pointee.duration) / Double(AV_TIME_BASE)
        } else {
            durationSeconds = 0
        }
        let cmDuration = CMTime(seconds: durationSeconds, preferredTimescale: 600)
        
        let fileExtension = url.pathExtension.lowercased()
        let nonNativeContainer = ["mkv", "avi", "webm", "flv", "wmv"].contains(fileExtension)
        
        return VideoInfo(
            duration: cmDuration,
            size: CGSize(width: CGFloat(videoWidth), height: CGFloat(videoHeight)),
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            videoCodec: videoCodecName,
            audioCodec: audioCodecName,
            needsConversion: nonNativeContainer || needsAudioConversion,
            needsAudioConversion: needsAudioConversion,
            isHEVC: isHEVC,
            hevcCodecString: hevcCodecString
        )
    }

    /// Remuxes media for progressive HTTP streaming (fast start / moov at front).
    /// Uses passthrough (no re-encode) and returns a network-optimized MP4 URL.
    func prepareForDirectStreaming(_ sourceURL: URL) async throws -> URL {
        let outputURL = outputDirectory.appendingPathComponent("direct_stream.mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: sourceURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw FFmpegError.conversionFailed("Failed to create AVAssetExportSession")
        }

        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: export.error ?? FFmpegError.conversionFailed("Direct-stream remux failed"))
                case .cancelled:
                    continuation.resume(throwing: FFmpegError.conversionFailed("Direct-stream remux cancelled"))
                default:
                    continuation.resume(throwing: FFmpegError.conversionFailed("Direct-stream remux ended in state: \(export.status.rawValue)"))
                }
            }
        }

        return outputURL
    }
    
    /// Generates a two-level HLS playlist structure for on-the-fly segment generation.
    ///
    /// Produces:
    /// - `master.m3u8` — Master playlist with `#EXT-X-STREAM-INF` pointing to `video.m3u8`
    ///   (and optionally `#EXT-X-MEDIA:TYPE=SUBTITLES` entries added later)
    /// - `video.m3u8` — Variant playlist with actual `#EXTINF` segment entries
    ///
    /// Uses MPEG-TS segments produced by FFmpeg C API remuxing (no re-encoding).
    ///
    /// Returns the URL of the master playlist.
    func generateHLSPlaylist(from sourceURL: URL, videoInfo: VideoInfo, subtitleTracks: [SubtitleTrack] = []) async throws -> URL {
        // Clean previous output
        try? FileManager.default.removeItem(at: outputDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        
        // Cache HEVC flag for segment generation
        self.sourceIsHEVC = videoInfo.isHEVC
        
        // Calculate segments (10 seconds each)
        let segmentDuration = 10.0
        let totalSegments = Int(ceil(videoInfo.durationInSeconds / segmentDuration))
        
        // --- Write variant playlist (video.m3u8) with segment entries ---
        // IMPORTANT: No leading whitespace — M3U8 tags must start at column 0
        // Always use MPEG-TS segments (.ts) for both H.264 and HEVC.
        // HEVC in MPEG-TS works with AVPlayer on iOS 11+ and avoids all fMP4
        // complexities that cause AirPlay rejection.
        
        var variant = "#EXTM3U\n"
        variant += "#EXT-X-VERSION:3\n"
        variant += "#EXT-X-TARGETDURATION:11\n"
        variant += "#EXT-X-MEDIA-SEQUENCE:0\n"
        variant += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        
        for i in 0..<totalSegments {
            let duration = min(segmentDuration, videoInfo.durationInSeconds - Double(i) * segmentDuration)
            variant += "#EXTINF:\(String(format: "%.3f", duration)),\n"
            variant += "segment_\(String(format: "%03d", i)).ts\n"
        }
        
        variant += "#EXT-X-ENDLIST\n"
        
        let variantPath = outputDirectory.appendingPathComponent("video.m3u8")
        try variant.write(to: variantPath, atomically: true, encoding: .utf8)
        
        // --- Write master playlist (master.m3u8) ---
        let masterPath = outputDirectory.appendingPathComponent("master.m3u8")
        let master = buildMasterPlaylist(videoInfo: videoInfo, subtitleTracks: subtitleTracks)
        try master.write(to: masterPath, atomically: true, encoding: .utf8)
        
        print("HLS playlist ready: \(totalSegments) segments (master + variant)")
        
        return masterPath
    }
    
    /// Builds the master playlist string with optional subtitle media entries.
    /// Called both at initial generation and when subtitles are added/changed.
    func buildMasterPlaylist(videoInfo: VideoInfo, subtitleTracks: [SubtitleTrack] = []) -> String {
        // IMPORTANT: No leading whitespace — M3U8 tags must start at column 0
        var master = "#EXTM3U\n"
        master += "#EXT-X-VERSION:3\n"
        
        // Add subtitle media entries
        let hasSubtitles = !subtitleTracks.isEmpty
        for (i, track) in subtitleTracks.enumerated() {
            let name = track.title.replacingOccurrences(of: "\"", with: "'")
            let lang = track.language ?? "und"
            let isDefault = i == 0 ? "YES" : "NO"
            let subtitlePlaylistName = "sub_\(track.id).m3u8"
            master += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(name)\",LANGUAGE=\"\(lang)\",DEFAULT=\(isDefault),AUTOSELECT=\(isDefault),FORCED=NO,URI=\"\(subtitlePlaylistName)\"\n"
        }
        
        // Stream info line — reference the variant playlist
        let bandwidth = 4_000_000  // Approximate bitrate
        let width = Int(videoInfo.size.width)
        let height = Int(videoInfo.size.height)
        
        // No CODECS attribute needed for MPEG-TS — AVPlayer auto-detects from the stream.
        if hasSubtitles {
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(width)x\(height),SUBTITLES=\"subs\"\n"
        } else {
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(width)x\(height)\n"
        }
        master += "video.m3u8\n"
        
        return master
    }
    
    /// Regenerates the master.m3u8 file with updated subtitle tracks.
    /// Called when subtitles are added, removed, or changed.
    func regenerateMasterPlaylist(videoInfo: VideoInfo, subtitleTracks: [SubtitleTrack]) throws {
        let masterPath = outputDirectory.appendingPathComponent("master.m3u8")
        let master = buildMasterPlaylist(videoInfo: videoInfo, subtitleTracks: subtitleTracks)
        try master.write(to: masterPath, atomically: true, encoding: .utf8)
        print("Regenerated master.m3u8 with \(subtitleTracks.count) subtitle track(s)")
    }
    
    /// Generates a segmented HLS subtitle playlist that mirrors the video segment structure.
    func generateSubtitlePlaylist(trackId: String, vttFileURL: URL, duration: Double, segmentDuration: Double = 10.0) throws -> URL {
        let playlistName = "sub_\(trackId).m3u8"
        let playlistPath = outputDirectory.appendingPathComponent(playlistName)
        
        // Parse the full VTT file into raw cues (preserving original text with formatting tags)
        let vttContent = try String(contentsOf: vttFileURL, encoding: .utf8)
        let rawCues = Self.parseRawVTTCues(vttContent)
        print("Parsed \(rawCues.count) subtitle cues from \(vttFileURL.lastPathComponent)")
        
        let totalSegments = Int(ceil(duration / segmentDuration))
        
        // IMPORTANT: No leading whitespace — M3U8 tags must start at column 0
        var playlist = "#EXTM3U\n"
        playlist += "#EXT-X-VERSION:3\n"
        playlist += "#EXT-X-TARGETDURATION:\(Int(ceil(segmentDuration)))\n"
        playlist += "#EXT-X-MEDIA-SEQUENCE:0\n"
        playlist += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        
        for i in 0..<totalSegments {
            let segStart = Double(i) * segmentDuration
            let segEnd = min(segStart + segmentDuration, duration)
            let segDuration = segEnd - segStart
            
            // Find all cues that overlap with this segment's time range
            let segmentCues = rawCues.filter { cue in
                cue.startTime < segEnd && cue.endTime > segStart
            }
            
            // Generate per-segment VTT file
            let segVttName = "sub_\(trackId)_\(String(format: "%03d", i)).vtt"
            let segVttPath = outputDirectory.appendingPathComponent(segVttName)
            
            var segVtt = "WEBVTT\n"
            // MPEGTS:0 maps to LOCAL:00:00:00.000 because our MPEG-TS remux
            // preserves the original file's PTS timeline (not zeroed per segment),
            // and the VTT cues also use the original global timestamps.
            segVtt += "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n"
            segVtt += "\n"
            
            for cue in segmentCues {
                segVtt += "\(cue.timestampLine)\n"
                segVtt += "\(cue.text)\n"
                segVtt += "\n"
            }
            
            try segVtt.write(to: segVttPath, atomically: true, encoding: .utf8)
            
            // Add entry to playlist
            playlist += "#EXTINF:\(String(format: "%.3f", segDuration)),\n"
            playlist += "\(segVttName)\n"
        }
        
        playlist += "#EXT-X-ENDLIST\n"
        
        try playlist.write(to: playlistPath, atomically: true, encoding: .utf8)
        print("Generated segmented subtitle playlist: \(playlistName) (\(totalSegments) segments, \(rawCues.count) cues)")
        
        return playlistPath
    }
    
    /// A raw VTT cue preserving the original timestamp line and text (no tag stripping)
    private struct RawVTTCue {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let timestampLine: String  // e.g. "00:01:23.456 --> 00:01:25.789"
        let text: String           // Raw text with formatting tags preserved
    }
    
    /// Parses a WebVTT file into raw cues, preserving original formatting.
    /// Unlike WebVTTParser.parse(), this does NOT strip HTML tags.
    private static func parseRawVTTCues(_ content: String) -> [RawVTTCue] {
        var cues: [RawVTTCue] = []
        let blocks = content.components(separatedBy: "\n\n")
        
        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            
            // Skip WEBVTT header, NOTE blocks, empty blocks
            if lines.first?.hasPrefix("WEBVTT") == true { continue }
            if lines.first?.hasPrefix("NOTE") == true { continue }
            if lines.first?.hasPrefix("X-TIMESTAMP-MAP") == true { continue }
            if lines.isEmpty { continue }
            
            // Find the timestamp line (contains " --> ")
            var tsIndex: Int?
            for (i, line) in lines.enumerated() {
                if line.contains(" --> ") {
                    tsIndex = i
                    break
                }
            }
            
            guard let timestampLineIndex = tsIndex else { continue }
            
            let timestampLine = lines[timestampLineIndex]
            let parts = timestampLine.components(separatedBy: " --> ")
            guard parts.count >= 2 else { continue }
            
            guard let startTime = WebVTTParser.parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                  let endTime = WebVTTParser.parseTimestamp(
                    parts[1].components(separatedBy: " ").first?.trimmingCharacters(in: .whitespaces) ?? parts[1]
                  ) else {
                continue
            }
            
            // Collect text lines after timestamp — preserve original formatting
            let textLines = lines.dropFirst(timestampLineIndex + 1)
            let text = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !text.isEmpty else { continue }
            
            cues.append(RawVTTCue(
                startTime: startTime,
                endTime: endTime,
                timestampLine: timestampLine,
                text: text
            ))
        }
        
        return cues
    }
    
    /// Formats a TimeInterval as a WebVTT timestamp (HH:MM:SS.mmm)
    private func formatVTTTimestamp(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = time.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", hours, minutes, seconds)
    }
    
    // MARK: - Segment Generation
    
    /// Cached flag: whether the current source file uses HEVC video.
    /// Set by `analyzeVideoFileSync` / `generateHLSPlaylist` flows.
    /// Used by `generateSegment` to pick the right file extension.
    private(set) var sourceIsHEVC: Bool = false
    
    /// Generates a single HLS segment on-the-fly.
    ///
    /// Strategy:
    /// 1. For H.264/HEVC sources: use FFmpeg C API to **remux** directly into
    ///    MPEG-TS without re-encoding. HEVC in MPEG-TS works with AVPlayer/AirPlay
    ///    on iOS 11+ and avoids fMP4 formatting issues.
    /// 2. For other sources: fall back to mpv encode mode.
    ///
    /// Handles concurrent requests for the same segment by queuing waiters.
    func generateSegment(from sourceURL: URL, segmentIndex: Int, segmentDuration: Double = 10.0) async throws -> URL {
        let segmentPath = outputDirectory.appendingPathComponent("segment_\(String(format: "%03d", segmentIndex)).ts")
        
        // Check if segment already exists (cached)
        if FileManager.default.fileExists(atPath: segmentPath.path) {
            return segmentPath
        }
        
        // Check if this segment is already being generated by another request.
        if inFlightSegments[segmentIndex] != nil {
            print("Segment \(segmentIndex) already generating, waiting...")
            return try await withCheckedThrowingContinuation { continuation in
                inFlightSegments[segmentIndex]?.append(continuation)
            }
        }
        
        // Mark this segment as in-flight (empty waiter list)
        inFlightSegments[segmentIndex] = []
        
        let startTime = Double(segmentIndex) * segmentDuration
        print("Generating segment \(segmentIndex) (start: \(String(format: "%.1f", startTime))s)...")
        
        do {
            try? FileManager.default.removeItem(at: segmentPath)

            // Try FFmpeg C API remux first (works for H.264+AAC MP4/M4V/MOV)
            let result: URL
            do {
                result = try await remuxSegmentWithFFmpeg(
                    from: sourceURL,
                    to: segmentPath,
                    startTime: startTime,
                    duration: segmentDuration
                )
                print("Segment \(segmentIndex) generated via FFmpeg C API")
            } catch {
                print("Segment \(segmentIndex): FFmpeg remux failed (\(error)), trying mpv encode...")
                try? FileManager.default.removeItem(at: segmentPath)
                
                // Fall back to mpv encode mode for non-remuxable sources.
                // This fallback path is known to produce audio-only output on iOS
                // for MP4 files, so it will likely fail the size check below.
                let tempPath = outputDirectory.appendingPathComponent("segment_\(String(format: "%03d", segmentIndex)).tmp.ts")
                try? FileManager.default.removeItem(at: tempPath)
                
                let encoded = try await runMPVEncode(
                    inputURL: sourceURL,
                    outputURL: tempPath,
                    startTime: startTime,
                    duration: segmentDuration,
                    videoEncoder: .h264VideoToolbox
                )
                
                if segmentLikelyAudioOnly(encoded) {
                    // mpv VT encode also failed; no viable path
                    try? FileManager.default.removeItem(at: encoded)
                    throw FFmpegError.mpvFailed("All encoding methods failed for segment \(segmentIndex)")
                }
                
                try FileManager.default.moveItem(at: encoded, to: segmentPath)
                result = segmentPath
            }
            
            // Log segment file size for debugging
            if let attrs = try? FileManager.default.attributesOfItem(atPath: result.path),
               let size = attrs[.size] as? Int64 {
                print("Segment \(segmentIndex) generated: \(size / 1024) KB")
            }
            
            // Resume all waiters with success
            let waiters = inFlightSegments.removeValue(forKey: segmentIndex) ?? []
            for waiter in waiters {
                waiter.resume(returning: result)
            }
            
            return result
        } catch {
            // Resume all waiters with the error
            let waiters = inFlightSegments.removeValue(forKey: segmentIndex) ?? []
            for waiter in waiters {
                waiter.resume(throwing: error)
            }
            throw error
        }
    }

    private func segmentLikelyAudioOnly(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return true
        }
        // 10s 1080p segment should be notably larger than this.
        return size < 500_000
    }
    
    // MARK: - FFmpeg C API Remux (No Re-encoding)
    
    /// Swift equivalent of FFmpeg's AVERROR() macro which is not importable.
    private static func AVERROR(_ e: Int32) -> Int32 { return -e }
    
    /// AVERROR_EOF constant (computed from FFERRTAG macro, not importable in Swift).
    /// Value: FFERRTAG('E','O','F',' ') = -(0x45 | (0x4F << 8) | (0x46 << 16) | (0x20 << 24))
    private static let AVERROR_EOF: Int32 = {
        let tag = Int32(0x45) | (Int32(0x4F) << 8) | (Int32(0x46) << 16) | (Int32(0x20) << 24)
        return -tag
    }()
    
    /// Strips leading `ftyp` and `moov` atoms from an fMP4 media segment file.
    ///
    /// FFmpeg's `empty_moov` movflag writes `ftyp`+`moov` at the start of every output,
    /// but HLS fMP4 media segments should contain only `moof`+`mdat` (the init segment
    /// provides the `ftyp`+`moov` via `EXT-X-MAP`). This reads the file, finds the first
    /// `moof` atom, and rewrites the file starting from that point.
    ///
    /// If `saveInitSegmentTo` is provided, the stripped `ftyp`+`moov` bytes are saved
    /// to that path as the HLS initialization segment (`init.mp4`). This guarantees
    /// the init segment's track IDs, codec parameters, and AAC `extradata` match the
    /// media segments exactly — they come from the same `AVFormatContext`.
    ///
    /// MP4 atom structure: 4 bytes size (big-endian) + 4 bytes type (ASCII).
    /// If size == 1, the next 8 bytes are the 64-bit extended size.
    private static func stripFtypMoovFromSegment(at path: String, saveInitSegmentTo initPath: String? = nil) throws {
        guard let data = FileManager.default.contents(atPath: path) else {
            print("stripFtypMoov: cannot read file at \(path)")
            return
        }
        
        // Scan atoms to find the offset of the first 'moof'
        var offset = 0
        let count = data.count
        var moofOffset: Int? = nil
        
        while offset + 8 <= count {
            let atomSize: Int = data.withUnsafeBytes { bytes in
                let ptr = bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                return (Int(ptr[0]) << 24) | (Int(ptr[1]) << 16) | (Int(ptr[2]) << 8) | Int(ptr[3])
            }
            let atomType: String = data.withUnsafeBytes { bytes in
                let ptr = bytes.baseAddress!.advanced(by: offset + 4).assumingMemoryBound(to: UInt8.self)
                return String(bytes: [ptr[0], ptr[1], ptr[2], ptr[3]], encoding: .ascii) ?? "????"
            }
            
            if atomType == "moof" {
                moofOffset = offset
                break
            }
            
            // Advance to next atom
            guard atomSize >= 8 else {
                print("stripFtypMoov: invalid atom size \(atomSize) at offset \(offset)")
                break
            }
            offset += atomSize
        }
        
        guard let start = moofOffset, start > 0 else {
            // No ftyp/moov prefix found, or file starts with moof already
            if moofOffset == 0 {
                print("stripFtypMoov: file already starts with moof")
            } else {
                print("stripFtypMoov: no moof atom found in \(path)")
            }
            return
        }
        
        // Save the ftyp+moov prefix as the init segment if requested.
        // This is the key fix for the track ID / codec parameter mismatch:
        // the init segment comes from the SAME AVFormatContext as the media data.
        if let initPath = initPath {
            let initData = data.subdata(in: 0..<start)
            try initData.write(to: URL(fileURLWithPath: initPath))
            print("stripFtypMoov: saved init segment (\(start) bytes) to \(initPath)")
            dumpMP4Boxes(at: initPath, label: "INIT SEGMENT")
        }
        
        // Rewrite the file starting from the moof atom
        let trimmedData = data.subdata(in: start..<count)
        
        // Also strip trailing 'mfra' (Movie Fragment Random Access) box if present.
        // FFmpeg's av_write_trailer writes mfra for seekable fMP4, but it's not
        // valid in HLS fMP4 segments and may confuse AirPlay receivers.
        var endOffset = trimmedData.count
        if endOffset > 8 {
            // Check if the last atom is mfra by scanning backwards
            // Look at the last atom: mfra has an mfro (Movie Fragment Random Access Offset)
            // box at the very end with a pointer to the mfra start.
            // Simpler: scan forward to find and exclude any trailing mfra.
            var scanPos = 0
            var lastMoofMdatEnd = 0
            while scanPos + 8 <= endOffset {
                let aSize: Int = trimmedData.withUnsafeBytes { bytes in
                    let ptr = bytes.baseAddress!.advanced(by: scanPos).assumingMemoryBound(to: UInt8.self)
                    return (Int(ptr[0]) << 24) | (Int(ptr[1]) << 16) | (Int(ptr[2]) << 8) | Int(ptr[3])
                }
                let aType: String = trimmedData.withUnsafeBytes { bytes in
                    let ptr = bytes.baseAddress!.advanced(by: scanPos + 4).assumingMemoryBound(to: UInt8.self)
                    return String(bytes: [ptr[0], ptr[1], ptr[2], ptr[3]], encoding: .ascii) ?? "????"
                }
                guard aSize >= 8 else { break }
                if aType == "mfra" {
                    endOffset = scanPos
                    print("stripFtypMoov: also stripped trailing mfra (\(aSize) bytes)")
                    break
                }
                scanPos += aSize
            }
        }
        
        let strippedData = endOffset < trimmedData.count ? trimmedData.subdata(in: 0..<endOffset) : trimmedData
        
        // Prepend an 'styp' (Segment Type) box before the moof.
        // Apple's HLS fMP4 spec and CMAF (ISO 23000-19) require media segments
        // to begin with a 'styp' box. Some AirPlay receivers reject segments
        // that start directly with 'moof'.
        // styp box: size(4) + 'styp'(4) + major_brand(4) + minor_version(4) + compatible_brands(...)
        var stypBox = Data()
        let stypSize: UInt32 = 24  // 8 (header) + 4 (major) + 4 (minor) + 8 (2 compatible brands)
        withUnsafeBytes(of: stypSize.bigEndian) { stypBox.append(contentsOf: $0) }
        stypBox.append(contentsOf: [0x73, 0x74, 0x79, 0x70])  // 'styp'
        stypBox.append(contentsOf: [0x6D, 0x73, 0x64, 0x68])  // major_brand: 'msdh'
        withUnsafeBytes(of: UInt32(0).bigEndian) { stypBox.append(contentsOf: $0) }  // minor_version: 0
        stypBox.append(contentsOf: [0x6D, 0x73, 0x64, 0x68])  // compatible: 'msdh'
        stypBox.append(contentsOf: [0x6D, 0x73, 0x69, 0x78])  // compatible: 'msix'
        
        var finalData = Data()
        finalData.reserveCapacity(stypBox.count + strippedData.count)
        finalData.append(stypBox)
        finalData.append(strippedData)
        
        try finalData.write(to: URL(fileURLWithPath: path))
        print("stripFtypMoov: stripped \(start) bytes (ftyp+moov), prepended styp (\(stypBox.count) bytes), \(count) -> \(finalData.count) bytes")
        dumpMP4Boxes(at: path, label: "MEDIA SEGMENT")
    }
    
    /// Dumps top-level MP4 box structure of a file for debugging.
    /// Recursively descends into container boxes (moov, trak, mdia, moof, traf).
    private static func dumpMP4Boxes(at path: String, label: String) {
        guard let data = FileManager.default.contents(atPath: path) else {
            print("\(label): cannot read file")
            return
        }
        print("\(label): \(data.count) bytes, box structure:")
        dumpBoxes(data: data, offset: 0, end: data.count, indent: "  ")
        
        // For init segments, also do a hex dump of the first 256 bytes after moov
        // to inspect hvcC and colr sub-boxes inside hvc1 sample entry
        if label.contains("INIT") {
            // Find stsd box and dump its contents
            let stsdOffset = findBoxOffset(data: data, type: "stsd")
            if let stsdOff = stsdOffset {
                let stsdSize = data.withUnsafeBytes { bytes -> Int in
                    let ptr = bytes.baseAddress!.advanced(by: stsdOff).assumingMemoryBound(to: UInt8.self)
                    return (Int(ptr[0]) << 24) | (Int(ptr[1]) << 16) | (Int(ptr[2]) << 8) | Int(ptr[3])
                }
                print("\(label) stsd at offset \(stsdOff), size \(stsdSize)")
                // Dump first entry header (at stsdOff + 16: after 8 box header + 4 version/flags + 4 entry_count)
                let entryStart = stsdOff + 16
                let entryEnd = min(stsdOff + stsdSize, data.count)
                if entryStart + 8 <= entryEnd {
                    let entrySize = data.withUnsafeBytes { bytes -> Int in
                        let ptr = bytes.baseAddress!.advanced(by: entryStart).assumingMemoryBound(to: UInt8.self)
                        return (Int(ptr[0]) << 24) | (Int(ptr[1]) << 16) | (Int(ptr[2]) << 8) | Int(ptr[3])
                    }
                    let entryType = data.withUnsafeBytes { bytes -> String in
                        let ptr = bytes.baseAddress!.advanced(by: entryStart + 4).assumingMemoryBound(to: UInt8.self)
                        return String(bytes: [ptr[0], ptr[1], ptr[2], ptr[3]], encoding: .ascii) ?? "????"
                    }
                    print("  Entry: [\(entryType)] size=\(entrySize)")
                    
                    // For hvc1/hev1, dump sub-boxes starting at entry + 86
                    if entryType == "hvc1" || entryType == "hev1" {
                        let subBoxStart = entryStart + 86
                        let subBoxEnd = min(entryStart + entrySize, entryEnd)
                        print("  Sub-boxes start at offset \(subBoxStart), end at \(subBoxEnd) (\(subBoxEnd - subBoxStart) bytes available)")
                        
                        // Dump sub-box headers
                        var subPos = subBoxStart
                        while subPos + 8 <= subBoxEnd {
                            let subSize = data.withUnsafeBytes { bytes -> Int in
                                let ptr = bytes.baseAddress!.advanced(by: subPos).assumingMemoryBound(to: UInt8.self)
                                return (Int(ptr[0]) << 24) | (Int(ptr[1]) << 16) | (Int(ptr[2]) << 8) | Int(ptr[3])
                            }
                            let subType = data.withUnsafeBytes { bytes -> String in
                                let ptr = bytes.baseAddress!.advanced(by: subPos + 4).assumingMemoryBound(to: UInt8.self)
                                return String(bytes: [ptr[0], ptr[1], ptr[2], ptr[3]], encoding: .ascii) ?? "????"
                            }
                            // Hex dump first 32 bytes of sub-box content
                            let contentStart = subPos + 8
                            let contentEnd = min(subPos + subSize, subBoxEnd)
                            let hexLen = min(32, contentEnd - contentStart)
                            var hexStr = ""
                            if hexLen > 0 {
                                hexStr = data.withUnsafeBytes { bytes -> String in
                                    let ptr = bytes.baseAddress!.advanced(by: contentStart).assumingMemoryBound(to: UInt8.self)
                                    return (0..<hexLen).map { String(format: "%02X", ptr[$0]) }.joined(separator: " ")
                                }
                            }
                            print("    [\(subType)] size=\(subSize) hex: \(hexStr)")
                            
                            if subSize < 8 { break }
                            subPos += subSize
                        }
                        
                        // Also hex dump the first 16 bytes at subBoxStart to verify alignment
                        if subBoxStart + 16 <= data.count {
                            let rawHex = data.withUnsafeBytes { bytes -> String in
                                let ptr = bytes.baseAddress!.advanced(by: subBoxStart).assumingMemoryBound(to: UInt8.self)
                                return (0..<min(16, subBoxEnd - subBoxStart)).map { String(format: "%02X", ptr[$0]) }.joined(separator: " ")
                            }
                            print("  Raw bytes at sub-box start (\(subBoxStart)): \(rawHex)")
                        }
                    }
                }
            }
        }
    }
    
    /// Find the absolute offset of a box type by scanning recursively through MP4 structure.
    private static func findBoxOffset(data: Data, type: String) -> Int? {
        return findBoxOffsetRecursive(data: data, type: type, start: 0, end: data.count)
    }
    
    private static func findBoxOffsetRecursive(data: Data, type: String, start: Int, end: Int) -> Int? {
        let containerTypes: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "moof", "traf", "mvex"]
        var pos = start
        while pos + 8 <= end {
            let boxSize = data.withUnsafeBytes { bytes -> Int in
                let ptr = bytes.baseAddress!.advanced(by: pos).assumingMemoryBound(to: UInt8.self)
                return (Int(ptr[0]) << 24) | (Int(ptr[1]) << 16) | (Int(ptr[2]) << 8) | Int(ptr[3])
            }
            let boxType = data.withUnsafeBytes { bytes -> String in
                let ptr = bytes.baseAddress!.advanced(by: pos + 4).assumingMemoryBound(to: UInt8.self)
                return String(bytes: [ptr[0], ptr[1], ptr[2], ptr[3]], encoding: .ascii) ?? "????"
            }
            let actualSize = boxSize == 0 ? (end - pos) : boxSize
            guard actualSize >= 8 else { break }
            
            if boxType == type { return pos }
            if containerTypes.contains(boxType) {
                let childStart = pos + 8 + (boxType == "stsd" ? 8 : 0)
                if let found = findBoxOffsetRecursive(data: data, type: type, start: childStart, end: min(pos + actualSize, end)) {
                    return found
                }
            }
            pos += actualSize
        }
        return nil
    }
    
    private static func dumpBoxes(data: Data, offset: Int, end: Int, indent: String) {
        let containerTypes: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "moof", "traf", "mvex"]
        let videoSampleEntries: Set<String> = ["hvc1", "hev1", "avc1", "avc3"]
        let audioSampleEntries: Set<String> = ["mp4a"]
        var pos = offset
        while pos + 8 <= end {
            let boxSize: Int = data.withUnsafeBytes { bytes in
                let ptr = bytes.baseAddress!.advanced(by: pos).assumingMemoryBound(to: UInt8.self)
                return (Int(ptr[0]) << 24) | (Int(ptr[1]) << 16) | (Int(ptr[2]) << 8) | Int(ptr[3])
            }
            let boxType: String = data.withUnsafeBytes { bytes in
                let ptr = bytes.baseAddress!.advanced(by: pos + 4).assumingMemoryBound(to: UInt8.self)
                return String(bytes: [ptr[0], ptr[1], ptr[2], ptr[3]], encoding: .ascii) ?? "????"
            }
            
            let actualSize: Int
            if boxSize == 1 && pos + 16 <= end {
                // 64-bit extended size
                actualSize = data.withUnsafeBytes { bytes in
                    let ptr = bytes.baseAddress!.advanced(by: pos + 8).assumingMemoryBound(to: UInt8.self)
                    var s: Int = 0
                    for j in 0..<8 { s = (s << 8) | Int(ptr[j]) }
                    return s
                }
            } else if boxSize == 0 {
                actualSize = end - pos  // box extends to end of file
            } else {
                actualSize = boxSize
            }
            
            guard actualSize >= 8 else {
                print("\(indent)[\(boxType)] INVALID size=\(actualSize) at offset \(pos)")
                break
            }
            
            // Extra info for specific box types
            var extra = ""
            if (boxType == "ftyp" || boxType == "styp") && actualSize >= 16 {
                // File/Segment type: major_brand(4) + minor_version(4) + compatible_brands(...)
                let majorBrand: String = data.withUnsafeBytes { bytes in
                    let ptr = bytes.baseAddress!.advanced(by: pos + 8).assumingMemoryBound(to: UInt8.self)
                    return String(bytes: [ptr[0], ptr[1], ptr[2], ptr[3]], encoding: .ascii) ?? "????"
                }
                var brands = [majorBrand]
                var bPos = pos + 16
                while bPos + 4 <= pos + actualSize {
                    let brand: String = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: bPos).assumingMemoryBound(to: UInt8.self)
                        return String(bytes: [ptr[0], ptr[1], ptr[2], ptr[3]], encoding: .ascii) ?? "????"
                    }
                    brands.append(brand)
                    bPos += 4
                }
                extra = " brands=[\(brands.joined(separator: ","))]"
            } else if boxType == "tkhd" && pos + 24 <= end && actualSize >= 24 {
                // Track header: version(1) + flags(3) + ... track_ID at offset 12 (v0) or 20 (v1)
                let version = data.withUnsafeBytes { bytes -> UInt8 in
                    bytes.baseAddress!.advanced(by: pos + 8).assumingMemoryBound(to: UInt8.self).pointee
                }
                let tkhdOffset = version == 0 ? (pos + 20) : (pos + 28)
                if tkhdOffset + 4 <= end {
                    let trackId: UInt32 = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: tkhdOffset).assumingMemoryBound(to: UInt8.self)
                        return (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                    }
                    extra = " track_id=\(trackId)"
                }
            } else if boxType == "tfhd" && pos + 12 <= end {
                // Track fragment header: version(1) + flags(3) + track_ID(4)
                let tfhdFlags: UInt32 = data.withUnsafeBytes { bytes in
                    let ptr = bytes.baseAddress!.advanced(by: pos + 8).assumingMemoryBound(to: UInt8.self)
                    // flags are bytes 1-3 of version+flags field (byte 0 is version)
                    return (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                }
                let trackId: UInt32 = data.withUnsafeBytes { bytes in
                    let ptr = bytes.baseAddress!.advanced(by: pos + 12).assumingMemoryBound(to: UInt8.self)
                    return (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                }
                let defaultBaseMoof = (tfhdFlags & 0x020000) != 0
                extra = " track_id=\(trackId) flags=0x\(String(tfhdFlags, radix: 16)) default_base_moof=\(defaultBaseMoof)"
            } else if boxType == "trun" && pos + 12 <= end {
                // Track run: version(1) + flags(3) + sample_count(4) [+ data_offset(4)]
                let trunVersion: UInt8 = data.withUnsafeBytes { bytes in
                    bytes.baseAddress!.advanced(by: pos + 8).assumingMemoryBound(to: UInt8.self).pointee
                }
                let trunFlags: UInt32 = data.withUnsafeBytes { bytes in
                    let ptr = bytes.baseAddress!.advanced(by: pos + 8).assumingMemoryBound(to: UInt8.self)
                    return (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                }
                let sampleCount: UInt32 = data.withUnsafeBytes { bytes in
                    let ptr = bytes.baseAddress!.advanced(by: pos + 12).assumingMemoryBound(to: UInt8.self)
                    return (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                }
                var dataOffsetStr = ""
                if (trunFlags & 0x1) != 0 && pos + 20 <= end {
                    // data_offset_present flag
                    let dataOffset: Int32 = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: pos + 16).assumingMemoryBound(to: UInt8.self)
                        let raw = (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                        return Int32(bitPattern: raw)
                    }
                    dataOffsetStr = " data_offset=\(dataOffset)"
                }
                extra = " v=\(trunVersion) flags=0x\(String(trunFlags, radix: 16)) samples=\(sampleCount)\(dataOffsetStr)"
            } else if boxType == "hdlr" && actualSize >= 20 {
                // Handler reference: version(1) + flags(3) + pre_defined(4) + handler_type(4)
                let htOffset = pos + 16
                if htOffset + 4 <= end {
                    let handlerType: String = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: htOffset).assumingMemoryBound(to: UInt8.self)
                        return String(bytes: [ptr[0], ptr[1], ptr[2], ptr[3]], encoding: .ascii) ?? "????"
                    }
                    extra = " handler=\(handlerType)"
                }
            } else if boxType == "stsd" && actualSize >= 16 {
                // Sample description: version(1) + flags(3) + entry_count(4) + first entry type(4)
                let entryTypeOffset = pos + 20
                if entryTypeOffset + 4 <= end {
                    let entryType: String = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: entryTypeOffset).assumingMemoryBound(to: UInt8.self)
                        return String(bytes: [ptr[0], ptr[1], ptr[2], ptr[3]], encoding: .ascii) ?? "????"
                    }
                    extra = " codec=\(entryType)"
                }
            } else if boxType == "hvcC" && actualSize >= 21 {
                // HEVCDecoderConfigurationRecord:
                // offset 8: configurationVersion(1) + general_profile_space/tier/idc(1) +
                //           profile_compatibility_flags(4) + constraint_indicator_flags(6) + general_level_idc(1)
                let hvcCBase = pos + 8
                if hvcCBase + 13 <= end {
                    let configVer = data.withUnsafeBytes { bytes -> UInt8 in
                        bytes.baseAddress!.advanced(by: hvcCBase).assumingMemoryBound(to: UInt8.self).pointee
                    }
                    let byte1 = data.withUnsafeBytes { bytes -> UInt8 in
                        bytes.baseAddress!.advanced(by: hvcCBase + 1).assumingMemoryBound(to: UInt8.self).pointee
                    }
                    let profileSpace = (byte1 >> 6) & 0x03
                    let tierFlag = (byte1 >> 5) & 0x01
                    let profileIDC = byte1 & 0x1F
                    let compatFlags: UInt32 = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: hvcCBase + 2).assumingMemoryBound(to: UInt8.self)
                        return (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                    }
                    let levelIDC = data.withUnsafeBytes { bytes -> UInt8 in
                        bytes.baseAddress!.advanced(by: hvcCBase + 12).assumingMemoryBound(to: UInt8.self).pointee
                    }
                    let constraints = (0..<6).map { i -> UInt8 in
                        data.withUnsafeBytes { bytes -> UInt8 in
                            bytes.baseAddress!.advanced(by: hvcCBase + 6 + i).assumingMemoryBound(to: UInt8.self).pointee
                        }
                    }
                    let tierStr = tierFlag == 1 ? "High" : "Main"
                    extra = " v=\(configVer) space=\(profileSpace) tier=\(tierStr) profile=\(profileIDC) level=\(levelIDC) compat=0x\(String(format: "%08X", compatFlags)) constraints=\(constraints.map { String(format: "%02X", $0) }.joined(separator: "."))"
                    
                    // Also parse NAL unit length size
                    if hvcCBase + 22 <= end {
                        let nalLenByte = data.withUnsafeBytes { bytes -> UInt8 in
                            bytes.baseAddress!.advanced(by: hvcCBase + 14 + 7).assumingMemoryBound(to: UInt8.self).pointee
                        }
                        let nalLenSize = (nalLenByte & 0x03) + 1
                        extra += " nalLenSize=\(nalLenSize)"
                    }
                }
            } else if boxType == "colr" && actualSize >= 12 {
                // Color information box
                let colrBase = pos + 8
                if colrBase + 4 <= end {
                    let colorType = (0..<4).map { i -> UInt8 in
                        data.withUnsafeBytes { bytes -> UInt8 in
                            bytes.baseAddress!.advanced(by: colrBase + i).assumingMemoryBound(to: UInt8.self).pointee
                        }
                    }
                    let colorTypeStr = String(bytes: colorType, encoding: .ascii) ?? "????"
                    if colorTypeStr == "nclx" && colrBase + 11 <= end {
                        // nclx: primaries(2) + transfer(2) + matrix(2) + full_range(1)
                        let primaries: UInt16 = data.withUnsafeBytes { bytes in
                            let ptr = bytes.baseAddress!.advanced(by: colrBase + 4).assumingMemoryBound(to: UInt8.self)
                            return (UInt16(ptr[0]) << 8) | UInt16(ptr[1])
                        }
                        let transfer: UInt16 = data.withUnsafeBytes { bytes in
                            let ptr = bytes.baseAddress!.advanced(by: colrBase + 6).assumingMemoryBound(to: UInt8.self)
                            return (UInt16(ptr[0]) << 8) | UInt16(ptr[1])
                        }
                        let matrix: UInt16 = data.withUnsafeBytes { bytes in
                            let ptr = bytes.baseAddress!.advanced(by: colrBase + 8).assumingMemoryBound(to: UInt8.self)
                            return (UInt16(ptr[0]) << 8) | UInt16(ptr[1])
                        }
                        let fullRange = data.withUnsafeBytes { bytes -> UInt8 in
                            bytes.baseAddress!.advanced(by: colrBase + 10).assumingMemoryBound(to: UInt8.self).pointee
                        }
                        extra = " type=nclx primaries=\(primaries) transfer=\(transfer) matrix=\(matrix) fullRange=\(fullRange & 0x80 != 0 ? "yes" : "no")"
                    } else if colorTypeStr == "nclc" && colrBase + 10 <= end {
                        // nclc (Apple variant): primaries(2) + transfer(2) + matrix(2)
                        let primaries: UInt16 = data.withUnsafeBytes { bytes in
                            let ptr = bytes.baseAddress!.advanced(by: colrBase + 4).assumingMemoryBound(to: UInt8.self)
                            return (UInt16(ptr[0]) << 8) | UInt16(ptr[1])
                        }
                        let transfer: UInt16 = data.withUnsafeBytes { bytes in
                            let ptr = bytes.baseAddress!.advanced(by: colrBase + 6).assumingMemoryBound(to: UInt8.self)
                            return (UInt16(ptr[0]) << 8) | UInt16(ptr[1])
                        }
                        let matrix: UInt16 = data.withUnsafeBytes { bytes in
                            let ptr = bytes.baseAddress!.advanced(by: colrBase + 8).assumingMemoryBound(to: UInt8.self)
                            return (UInt16(ptr[0]) << 8) | UInt16(ptr[1])
                        }
                        extra = " type=nclc primaries=\(primaries) transfer=\(transfer) matrix=\(matrix)"
                    } else {
                        extra = " type=\(colorTypeStr)"
                    }
                }
            } else if boxType == "pasp" && actualSize >= 16 {
                // Pixel aspect ratio box: hSpacing(4) + vSpacing(4)
                let paspBase = pos + 8
                if paspBase + 8 <= end {
                    let hSpacing: UInt32 = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: paspBase).assumingMemoryBound(to: UInt8.self)
                        return (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                    }
                    let vSpacing: UInt32 = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: paspBase + 4).assumingMemoryBound(to: UInt8.self)
                        return (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                    }
                    extra = " hSpacing=\(hSpacing) vSpacing=\(vSpacing)"
                }
            } else if boxType == "mdhd" && actualSize >= 20 {
                // Media header box: version(1) + flags(3) + timestamps + timescale
                let mdhdBase = pos + 8
                let version = data.withUnsafeBytes { bytes -> UInt8 in
                    bytes.baseAddress!.advanced(by: mdhdBase).assumingMemoryBound(to: UInt8.self).pointee
                }
                let timescaleOffset = mdhdBase + (version == 0 ? 12 : 20)
                if timescaleOffset + 4 <= end {
                    let timescale: UInt32 = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: timescaleOffset).assumingMemoryBound(to: UInt8.self)
                        return (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                    }
                    extra = " v=\(version) timescale=\(timescale)"
                }
            } else if boxType == "tfdt" && actualSize >= 16 {
                // Track Fragment Decode Time: version(1) + flags(3) + baseMediaDecodeTime
                let version = data.withUnsafeBytes { bytes -> UInt8 in
                    bytes.baseAddress!.advanced(by: pos + 8).assumingMemoryBound(to: UInt8.self).pointee
                }
                if version == 0 && pos + 16 <= end {
                    let bmdt: UInt32 = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: pos + 12).assumingMemoryBound(to: UInt8.self)
                        return (UInt32(ptr[0]) << 24) | (UInt32(ptr[1]) << 16) | (UInt32(ptr[2]) << 8) | UInt32(ptr[3])
                    }
                    extra = " baseMediaDecodeTime=\(bmdt)"
                } else if version == 1 && pos + 20 <= end {
                    let bmdt: UInt64 = data.withUnsafeBytes { bytes in
                        let ptr = bytes.baseAddress!.advanced(by: pos + 12).assumingMemoryBound(to: UInt8.self)
                        var val: UInt64 = 0
                        for j in 0..<8 { val = (val << 8) | UInt64(ptr[j]) }
                        return val
                    }
                    extra = " baseMediaDecodeTime=\(bmdt)"
                }
            }
            
            print("\(indent)[\(boxType)] size=\(actualSize)\(extra)")
            
            if containerTypes.contains(boxType) {
                let childStart = pos + 8 + (boxType == "stsd" ? 8 : 0)
                dumpBoxes(data: data, offset: childStart, end: min(pos + actualSize, end), indent: indent + "  ")
            } else if videoSampleEntries.contains(boxType) && actualSize > 86 {
                // Video sample entry (hvc1, hev1, avc1, etc.): 8 (header) + 6 (reserved) + 2 (data_ref_idx) + 70 (video fields) = 86 bytes fixed
                dumpBoxes(data: data, offset: pos + 86, end: min(pos + actualSize, end), indent: indent + "  ")
            } else if audioSampleEntries.contains(boxType) && actualSize > 36 {
                // Audio sample entry (mp4a): 8 (header) + 6 (reserved) + 2 (data_ref_idx) + 20 (audio fields) = 36 bytes fixed
                dumpBoxes(data: data, offset: pos + 36, end: min(pos + actualSize, end), indent: indent + "  ")
            }
            
            pos += actualSize
        }
    }
    
    /// Converts an FFmpeg error code to a human-readable string.
    private static func ffmpegErrorString(_ errnum: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        av_strerror(errnum, &buf, 256)
        return String(cString: buf)
    }
    
    /// Remuxes a time range from the source video into an MPEG-TS segment
    /// using the FFmpeg C API (Libavformat). For H.264, bitstreams are copied directly.
    /// For HEVC, video is transcoded to H.264 via VideoToolbox for AirPlay compatibility.
    ///
    /// Runs on concurrent `encodeQueue`, bounded by `encodeSemaphore`.
    private func remuxSegmentWithFFmpeg(
        from sourceURL: URL,
        to outputURL: URL,
        startTime: Double,
        duration: Double
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.encodeQueue.async {
                self.encodeSemaphore.wait()
                defer { self.encodeSemaphore.signal() }
                do {
                    let result = try self.remuxSegmentWithFFmpegSync(
                        from: sourceURL,
                        to: outputURL,
                        startTime: startTime,
                        duration: duration
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Synchronous FFmpeg remux implementation. Must be called on `encodeQueue`.
    ///
    /// For video: copies if H.264, transcodes HEVC→H.264 via VideoToolbox for AirPlay compatibility.
    /// For audio: copies if the codec is MPEG-TS compatible (AAC, AC3, EAC3, MP3, MP2),
    ///            otherwise transcodes to AAC (needed for MKV files with Opus/FLAC/Vorbis).
    private func remuxSegmentWithFFmpegSync(
        from sourceURL: URL,
        to outputURL: URL,
        startTime: Double,
        duration: Double
    ) throws -> URL {
        let inputPath = sourceURL.path
        let outputPath = outputURL.path
        
        // --- Open input ---
        var inputCtx: UnsafeMutablePointer<AVFormatContext>?
        var ret = avformat_open_input(&inputCtx, inputPath, nil, nil)
        guard ret >= 0, inputCtx != nil else {
            throw FFmpegError.conversionFailed("avformat_open_input failed: \(Self.ffmpegErrorString(ret))")
        }
        defer {
            var ctx = inputCtx
            avformat_close_input(&ctx)
        }
        
        ret = avformat_find_stream_info(inputCtx, nil)
        guard ret >= 0 else {
            throw FFmpegError.conversionFailed("avformat_find_stream_info failed: \(Self.ffmpegErrorString(ret))")
        }
        
        // --- Allocate output (always MPEG-TS) ---
        // HEVC cannot play video on AirPlay in any container (MPEG-TS = audio only,
        // fMP4 = rejected with -12848). HEVC video is transcoded to H.264 via
        // VideoToolbox hardware encoder for AirPlay compatibility.
        var isHEVCSource = false
        var hevcVideoStreamIdx: Int = -1
        let nbInputStreams = Int(inputCtx!.pointee.nb_streams)
        for i in 0..<nbInputStreams {
            let stream = inputCtx!.pointee.streams[i]!
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                isHEVCSource = stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
                if isHEVCSource { hevcVideoStreamIdx = i }
                break
            }
        }
        
        let outputFormat = "mpegts"
        
        var outputCtx: UnsafeMutablePointer<AVFormatContext>?
        ret = avformat_alloc_output_context2(&outputCtx, nil, outputFormat, outputPath)
        guard ret >= 0, let outputCtxUnwrapped = outputCtx else {
            throw FFmpegError.conversionFailed("avformat_alloc_output_context2 failed: \(Self.ffmpegErrorString(ret))")
        }
        defer { avformat_free_context(outputCtxUnwrapped) }
        
        // --- Analyze streams and set up mapping ---
        let inputStreamCount = Int(inputCtx!.pointee.nb_streams)
        
        let tsCompatibleVideo: Set<UInt32> = [
            AV_CODEC_ID_H264.rawValue,
            AV_CODEC_ID_HEVC.rawValue,
            AV_CODEC_ID_MPEG2VIDEO.rawValue,
            AV_CODEC_ID_MPEG1VIDEO.rawValue,
        ]
        let tsCompatibleAudio: Set<UInt32> = [
            AV_CODEC_ID_AAC.rawValue,
            AV_CODEC_ID_AC3.rawValue,
            AV_CODEC_ID_EAC3.rawValue,
            AV_CODEC_ID_MP3.rawValue,
            AV_CODEC_ID_MP2.rawValue,
        ]
        
        // Maps input stream index -> output stream index (-1 = not mapped)
        var streamMapping = [Int](repeating: -1, count: inputStreamCount)
        // Tracks which audio streams need transcoding (input stream index -> true)
        var audioNeedsTranscode = [Int: Bool]()
        var outputStreamIndex = 0
        
        // Audio transcoding state (lazily initialized)
        var audioDecCtx: UnsafeMutablePointer<AVCodecContext>?
        var audioEncCtx: UnsafeMutablePointer<AVCodecContext>?
        var swrCtx: OpaquePointer?  // SwrContext for sample format conversion
        var audioFifo: OpaquePointer?  // AVAudioFifo* for buffering resampled audio
        var audioTranscodeInputIdx: Int = -1
        // Running PTS counter for AAC encoder output.
        // Initialized to 0; will be set to the first decoded audio frame's PTS
        // when audio transcoding starts, so transcoded audio aligns with the
        // segment's actual position in the timeline.
        var audioNextPts: Int64 = 0
        var audioNextPtsInitialized = false
        
        // Video transcoding state (for HEVC→H.264, lazily initialized)
        var videoDecCtx: UnsafeMutablePointer<AVCodecContext>?
        var videoEncCtx: UnsafeMutablePointer<AVCodecContext>?
        var swsCtx: UnsafeMutablePointer<SwsContext>?  // SwsContext for pixel format conversion
        var videoNeedsTranscode = false
        var videoTranscodeInputIdx: Int = -1
        var videoNextPts: Int64 = 0  // Running PTS counter for H.264 encoder output
        
        for i in 0..<inputStreamCount {
            let inputStream = inputCtx!.pointee.streams[i]!
            let codecpar = inputStream.pointee.codecpar.pointee
            let codecType = codecpar.codec_type
            let codecId = codecpar.codec_id.rawValue
            
            if codecType == AVMEDIA_TYPE_VIDEO {
                guard tsCompatibleVideo.contains(codecId) else {
                    let name = avcodec_descriptor_get(codecpar.codec_id).flatMap { String(cString: $0.pointee.name) } ?? "unknown"
                    print("Skipping video stream \(i): codec '\(name)' not MPEG-TS compatible")
                    continue
                }
                
                if isHEVCSource && codecpar.codec_id == AV_CODEC_ID_HEVC && videoDecCtx == nil {
                    // --- Set up HEVC→H.264 video transcode pipeline ---
                    print("HEVC video detected — setting up VideoToolbox H.264 transcode for AirPlay")
                    
                    // Set up HEVC decoder
                    guard let decoder = avcodec_find_decoder(AV_CODEC_ID_HEVC) else {
                        print("HEVC decoder not found, falling back to passthrough")
                        // Fall through to passthrough copy below
                        streamMapping[i] = outputStreamIndex
                        outputStreamIndex += 1
                        guard let outStream = avformat_new_stream(outputCtxUnwrapped, nil) else {
                            throw FFmpegError.conversionFailed("avformat_new_stream failed for stream \(i)")
                        }
                        ret = avcodec_parameters_copy(outStream.pointee.codecpar, inputStream.pointee.codecpar)
                        guard ret >= 0 else {
                            throw FFmpegError.conversionFailed("avcodec_parameters_copy failed: \(Self.ffmpegErrorString(ret))")
                        }
                        outStream.pointee.codecpar.pointee.codec_tag = 0
                        continue
                    }
                    
                    guard let decCtx = avcodec_alloc_context3(decoder) else {
                        throw FFmpegError.conversionFailed("avcodec_alloc_context3 (HEVC decoder) failed")
                    }
                    ret = avcodec_parameters_to_context(decCtx, inputStream.pointee.codecpar)
                    guard ret >= 0 else {
                        avcodec_free_context(&videoDecCtx)
                        throw FFmpegError.conversionFailed("avcodec_parameters_to_context (video) failed: \(Self.ffmpegErrorString(ret))")
                    }
                    decCtx.pointee.pkt_timebase = inputStream.pointee.time_base
                    
                    // Enable multi-threaded HEVC decoding for performance.
                    // Use frame-level threading with auto thread count (0 = let FFmpeg decide).
                    decCtx.pointee.thread_count = 4
                    decCtx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
                    
                    ret = avcodec_open2(decCtx, decoder, nil)
                    guard ret >= 0 else {
                        var dc: UnsafeMutablePointer<AVCodecContext>? = decCtx
                        avcodec_free_context(&dc)
                        throw FFmpegError.conversionFailed("avcodec_open2 (HEVC decoder) failed: \(Self.ffmpegErrorString(ret))")
                    }
                    videoDecCtx = decCtx
                    
                    // Set up H.264 VideoToolbox encoder
                    guard let encoder = avcodec_find_encoder_by_name("h264_videotoolbox") else {
                        print("h264_videotoolbox encoder not found! Cannot transcode HEVC for AirPlay.")
                        var dc: UnsafeMutablePointer<AVCodecContext>? = decCtx
                        avcodec_free_context(&dc)
                        videoDecCtx = nil
                        throw FFmpegError.conversionFailed("h264_videotoolbox encoder not available")
                    }
                    
                    guard let encCtx = avcodec_alloc_context3(encoder) else {
                        var dc: UnsafeMutablePointer<AVCodecContext>? = decCtx
                        avcodec_free_context(&dc)
                        videoDecCtx = nil
                        throw FFmpegError.conversionFailed("avcodec_alloc_context3 (h264_videotoolbox) failed")
                    }
                    
                    // Configure H.264 encoder to match input resolution
                    encCtx.pointee.width = decCtx.pointee.width
                    encCtx.pointee.height = decCtx.pointee.height
                    encCtx.pointee.sample_aspect_ratio = decCtx.pointee.sample_aspect_ratio
                    // VideoToolbox encoder expects NV12 or BGRA pixel format
                    // NV12 is the most efficient for hardware encoding
                    encCtx.pointee.pix_fmt = AV_PIX_FMT_NV12
                    // Use the input timebase for consistent timestamps
                    encCtx.pointee.time_base = inputStream.pointee.time_base
                    encCtx.pointee.framerate = inputStream.pointee.r_frame_rate
                    // Set a reasonable bitrate — prioritize encode speed for real-time AirPlay
                    // VideoToolbox will use hardware rate control
                    let pixels = Int64(encCtx.pointee.width) * Int64(encCtx.pointee.height)
                    if pixels >= 1920 * 1080 {
                        encCtx.pointee.bit_rate = 6_000_000  // 6 Mbps for 1080p
                    } else if pixels >= 1280 * 720 {
                        encCtx.pointee.bit_rate = 4_000_000  // 4 Mbps for 720p
                    } else {
                        encCtx.pointee.bit_rate = 2_500_000  // 2.5 Mbps for lower res
                    }
                    // GOP size — keyframe every 2 seconds for seeking
                    let fps: Int32
                    if inputStream.pointee.r_frame_rate.num > 0 && inputStream.pointee.r_frame_rate.den > 0 {
                        fps = inputStream.pointee.r_frame_rate.num / inputStream.pointee.r_frame_rate.den
                    } else {
                        fps = 24
                    }
                    encCtx.pointee.gop_size = fps * 2
                    // Allow B-frames for better compression (VideoToolbox supports this)
                    encCtx.pointee.max_b_frames = 0  // Start without B-frames for simpler DTS handling
                    // Set global header flag if required by the muxer
                    if (outputCtxUnwrapped.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER) != 0 {
                        encCtx.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
                    }
                    // Set H.264 profile to Main for good quality + fast encode
                    encCtx.pointee.profile = 77  // FF_PROFILE_H264_MAIN
                    encCtx.pointee.level = 41  // Level 4.1 — supports 1080p@30 or 720p@60
                    
                    // Open encoder with options
                    var encOpts: OpaquePointer?  // AVDictionary*
                    // realtime=1: prioritize encode speed over quality (critical for AirPlay)
                    av_dict_set(&encOpts, "realtime", "1", 0)
                    av_dict_set(&encOpts, "allow_sw", "1", 0)  // Allow software fallback
                    
                    ret = avcodec_open2(encCtx, encoder, &encOpts)
                    av_dict_free(&encOpts)
                    guard ret >= 0 else {
                        var dc: UnsafeMutablePointer<AVCodecContext>? = decCtx
                        avcodec_free_context(&dc)
                        videoDecCtx = nil
                        var ec: UnsafeMutablePointer<AVCodecContext>? = encCtx
                        avcodec_free_context(&ec)
                        throw FFmpegError.conversionFailed("avcodec_open2 (h264_videotoolbox) failed: \(Self.ffmpegErrorString(ret))")
                    }
                    videoEncCtx = encCtx
                    
                    // Set up SwsContext for pixel format conversion
                    // HEVC decoder outputs yuv420p/yuv420p10le, VT encoder expects NV12
                    // We'll set up sws lazily in the decode loop when we know the actual
                    // decoded pixel format, since HEVC can be 8-bit or 10-bit
                    
                    print("H.264 VideoToolbox encoder initialized: \(encCtx.pointee.width)x\(encCtx.pointee.height), \(encCtx.pointee.bit_rate/1000)kbps, GOP=\(encCtx.pointee.gop_size)")
                    
                    // Create output stream from encoder parameters
                    guard let outStream = avformat_new_stream(outputCtxUnwrapped, nil) else {
                        throw FFmpegError.conversionFailed("avformat_new_stream failed for transcoded video")
                    }
                    ret = avcodec_parameters_from_context(outStream.pointee.codecpar, encCtx)
                    guard ret >= 0 else {
                        throw FFmpegError.conversionFailed("avcodec_parameters_from_context (video) failed: \(Self.ffmpegErrorString(ret))")
                    }
                    outStream.pointee.time_base = encCtx.pointee.time_base
                    
                    streamMapping[i] = outputStreamIndex
                    videoNeedsTranscode = true
                    videoTranscodeInputIdx = i
                    outputStreamIndex += 1
                } else {
                    // H.264 or non-HEVC: passthrough copy
                    streamMapping[i] = outputStreamIndex
                    outputStreamIndex += 1
                    
                    guard let outStream = avformat_new_stream(outputCtxUnwrapped, nil) else {
                        throw FFmpegError.conversionFailed("avformat_new_stream failed for stream \(i)")
                    }
                    ret = avcodec_parameters_copy(outStream.pointee.codecpar, inputStream.pointee.codecpar)
                    guard ret >= 0 else {
                        throw FFmpegError.conversionFailed("avcodec_parameters_copy failed: \(Self.ffmpegErrorString(ret))")
                    }
                    // Zero the codec tag — let the muxer choose the appropriate tag.
                    outStream.pointee.codecpar.pointee.codec_tag = 0
                }
                
            } else if codecType == AVMEDIA_TYPE_AUDIO {
                // For MPEG-TS output, TS-compatible audio codecs can be copied directly.
                // This includes AAC, AC3, EAC3, MP3, and MP2.
                // Non-TS-compatible codecs (Opus, Vorbis, FLAC, etc.) need AAC transcode.
                let canCopyAudio = tsCompatibleAudio.contains(codecId)
                
                if canCopyAudio {
                    // Audio can be copied directly (MPEG-TS output only)
                    streamMapping[i] = outputStreamIndex
                    audioNeedsTranscode[i] = false
                    outputStreamIndex += 1
                    
                    guard let outStream = avformat_new_stream(outputCtxUnwrapped, nil) else {
                        throw FFmpegError.conversionFailed("avformat_new_stream failed for stream \(i)")
                    }
                    ret = avcodec_parameters_copy(outStream.pointee.codecpar, inputStream.pointee.codecpar)
                    guard ret >= 0 else {
                        throw FFmpegError.conversionFailed("avcodec_parameters_copy failed: \(Self.ffmpegErrorString(ret))")
                    }
                    outStream.pointee.codecpar.pointee.codec_tag = 0
                } else if audioDecCtx == nil {
                    // First audio stream needing transcoding — set up transcoding to AAC
                    // For HEVC/fMP4: all audio is forced to AAC to match init segment
                    // For MPEG-TS: only TS-incompatible codecs (Opus, Vorbis, etc.)
                    let codecName = avcodec_descriptor_get(codecpar.codec_id).flatMap { String(cString: $0.pointee.name) } ?? "unknown"
                    let reason = isHEVCSource ? "HEVC/fMP4 requires AAC" : "codec not TS-compatible"
                    print("Audio stream \(i) ('\(codecName)') needs transcoding to AAC (\(reason))")
                    
                    // Set up decoder
                    guard let decoder = avcodec_find_decoder(codecpar.codec_id) else {
                        print("No decoder found for '\(codecName)', skipping audio stream \(i)")
                        continue
                    }
                    guard let decCtx = avcodec_alloc_context3(decoder) else {
                        throw FFmpegError.conversionFailed("avcodec_alloc_context3 (decoder) failed")
                    }
                    ret = avcodec_parameters_to_context(decCtx, inputStream.pointee.codecpar)
                    guard ret >= 0 else {
                        avcodec_free_context(&audioDecCtx)
                        throw FFmpegError.conversionFailed("avcodec_parameters_to_context failed: \(Self.ffmpegErrorString(ret))")
                    }
                    decCtx.pointee.pkt_timebase = inputStream.pointee.time_base
                    ret = avcodec_open2(decCtx, decoder, nil)
                    guard ret >= 0 else {
                        avcodec_free_context(&audioDecCtx)
                        throw FFmpegError.conversionFailed("avcodec_open2 (decoder) failed: \(Self.ffmpegErrorString(ret))")
                    }
                    audioDecCtx = decCtx
                    
                    // Set up AAC encoder
                    guard let encoder = avcodec_find_encoder(AV_CODEC_ID_AAC) else {
                        print("AAC encoder not found, skipping audio stream \(i)")
                        avcodec_free_context(&audioDecCtx)
                        audioDecCtx = nil
                        continue
                    }
                    guard let encCtx = avcodec_alloc_context3(encoder) else {
                        avcodec_free_context(&audioDecCtx)
                        audioDecCtx = nil
                        throw FFmpegError.conversionFailed("avcodec_alloc_context3 (encoder) failed")
                    }
                    
                    // Configure encoder to match input as closely as possible
                    encCtx.pointee.sample_rate = decCtx.pointee.sample_rate
                    if encCtx.pointee.sample_rate == 0 {
                        encCtx.pointee.sample_rate = 48000
                    }
                    encCtx.pointee.ch_layout = decCtx.pointee.ch_layout
                    // Default to stereo if input layout is unset
                    if encCtx.pointee.ch_layout.nb_channels == 0 {
                        av_channel_layout_default(&encCtx.pointee.ch_layout, 2)
                    }
                    encCtx.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP // AAC encoder expects float planar
                    encCtx.pointee.bit_rate = 128000
                    encCtx.pointee.time_base = AVRational(num: 1, den: encCtx.pointee.sample_rate)
                    // Set global header flag if required by the muxer
                    if (outputCtxUnwrapped.pointee.oformat.pointee.flags & AVFMT_GLOBALHEADER) != 0 {
                        encCtx.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
                    }
                    
                    ret = avcodec_open2(encCtx, encoder, nil)
                    guard ret >= 0 else {
                        avcodec_free_context(&audioDecCtx)
                        audioDecCtx = nil
                        avcodec_free_context(&audioEncCtx)
                        print("avcodec_open2 (AAC encoder) failed: \(Self.ffmpegErrorString(ret)), skipping audio")
                        continue
                    }
                    audioEncCtx = encCtx
                    
                    // Set up SwrContext for sample format conversion
                    // Decoder may output different format than encoder expects (e.g. Opus outputs FLT, AAC wants FLTP)
                    ret = swr_alloc_set_opts2(
                        &swrCtx,
                        &encCtx.pointee.ch_layout,     // out channel layout
                        encCtx.pointee.sample_fmt,      // out sample format (FLTP)
                        encCtx.pointee.sample_rate,     // out sample rate
                        &decCtx.pointee.ch_layout,     // in channel layout
                        decCtx.pointee.sample_fmt,      // in sample format
                        decCtx.pointee.sample_rate,     // in sample rate
                        0, nil
                    )
                    if ret < 0 || swrCtx == nil {
                        print("swr_alloc_set_opts2 failed, skipping audio transcoding")
                        avcodec_free_context(&audioDecCtx)
                        audioDecCtx = nil
                        avcodec_free_context(&audioEncCtx)
                        audioEncCtx = nil
                        continue
                    }
                    ret = swr_init(swrCtx)
                    if ret < 0 {
                        print("swr_init failed: \(Self.ffmpegErrorString(ret)), skipping audio transcoding")
                        swr_free(&swrCtx)
                        avcodec_free_context(&audioDecCtx)
                        audioDecCtx = nil
                        avcodec_free_context(&audioEncCtx)
                        audioEncCtx = nil
                        continue
                    }
                    
                    // Create AVAudioFifo to buffer resampled samples.
                    // The decoder may output frames with different sizes (e.g. EAC3 = 1536 samples)
                    // than the encoder expects (AAC = 1024 samples). The FIFO accumulates
                    // resampled samples and we drain it in encoder-frame-size chunks.
                    let fifoSampleFmt = encCtx.pointee.sample_fmt
                    let fifoChannels = encCtx.pointee.ch_layout.nb_channels
                    let fifoPtr = av_audio_fifo_alloc(fifoSampleFmt, fifoChannels, 1)
                    guard fifoPtr != nil else {
                        print("av_audio_fifo_alloc failed, skipping audio transcoding")
                        swr_free(&swrCtx)
                        avcodec_free_context(&audioDecCtx)
                        audioDecCtx = nil
                        avcodec_free_context(&audioEncCtx)
                        audioEncCtx = nil
                        continue
                    }
                    audioFifo = fifoPtr
                    
                    // Create output stream for transcoded audio
                    guard let outStream = avformat_new_stream(outputCtxUnwrapped, nil) else {
                        throw FFmpegError.conversionFailed("avformat_new_stream failed for transcoded audio")
                    }
                    ret = avcodec_parameters_from_context(outStream.pointee.codecpar, encCtx)
                    guard ret >= 0 else {
                        throw FFmpegError.conversionFailed("avcodec_parameters_from_context failed: \(Self.ffmpegErrorString(ret))")
                    }
                    outStream.pointee.time_base = encCtx.pointee.time_base
                    
                    streamMapping[i] = outputStreamIndex
                    audioNeedsTranscode[i] = true
                    audioTranscodeInputIdx = i
                    outputStreamIndex += 1
                } else {
                    // Already have a transcoded audio stream, skip additional ones
                    continue
                }
            }
            // Skip subtitles, data, attachments, etc.
        }
        
        defer {
            var dec: UnsafeMutablePointer<AVCodecContext>? = audioDecCtx
            var enc: UnsafeMutablePointer<AVCodecContext>? = audioEncCtx
            if dec != nil { avcodec_free_context(&dec) }
            if enc != nil { avcodec_free_context(&enc) }
            if swrCtx != nil { swr_free(&swrCtx) }
            if let fifo = audioFifo {
                av_audio_fifo_free(fifo)
            }
            // Clean up video transcode state
            var vdec: UnsafeMutablePointer<AVCodecContext>? = videoDecCtx
            var venc: UnsafeMutablePointer<AVCodecContext>? = videoEncCtx
            if vdec != nil { avcodec_free_context(&vdec) }
            if venc != nil { avcodec_free_context(&venc) }
            if swsCtx != nil { sws_freeContext(swsCtx) }
        }
        
        guard outputStreamIndex > 0 else {
            throw FFmpegError.unsupportedFormat
        }
        
        // --- Open output file ---
        let oformat = outputCtxUnwrapped.pointee.oformat!
        if (oformat.pointee.flags & AVFMT_NOFILE) == 0 {
            ret = avio_open(&outputCtxUnwrapped.pointee.pb, outputPath, AVIO_FLAG_WRITE)
            guard ret >= 0 else {
                throw FFmpegError.conversionFailed("avio_open failed: \(Self.ffmpegErrorString(ret))")
            }
        }
        
        // --- Write header ---
        var muxOpts: OpaquePointer?  // AVDictionary*
        // No special mux options needed for MPEG-TS output.
        // Pass &muxOpts (nil) — avformat_write_header accepts nil options.
        // Pass &muxOpts always — it's nil for non-HEVC (MPEG-TS), which is fine.
        ret = avformat_write_header(outputCtxUnwrapped, &muxOpts)
        av_dict_free(&muxOpts)
        guard ret >= 0 else {
            if (oformat.pointee.flags & AVFMT_NOFILE) == 0 {
                avio_closep(&outputCtxUnwrapped.pointee.pb)
            }
            throw FFmpegError.conversionFailed("avformat_write_header failed: \(Self.ffmpegErrorString(ret))")
        }
        
        // --- Seek to segment start time ---
        let seekTarget = Int64(startTime * Double(AV_TIME_BASE))
        ret = avformat_seek_file(
            inputCtx,
            -1,
            Int64.min,
            seekTarget,
            seekTarget,
            0
        )
        if ret < 0 {
            print("Warning: avformat_seek_file failed (\(Self.ffmpegErrorString(ret))), reading from beginning")
        }
        
        // Flush decoder after seek so stale data doesn't leak into this segment
        if let dec = audioDecCtx {
            avcodec_flush_buffers(dec)
        }
        if let dec = videoDecCtx {
            avcodec_flush_buffers(dec)
        }
        
        // --- Read packets and write to output ---
        let endTime = startTime + duration
        let avNoPTS = Int64(bitPattern: UInt64(0x8000000000000000))
        
        var pkt = av_packet_alloc()!
        defer {
            var pktPtr: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&pktPtr)
        }
        
        // Frame for audio transcoding
        var frame: UnsafeMutablePointer<AVFrame>?
        if audioDecCtx != nil {
            frame = av_frame_alloc()
        }
        defer {
            av_frame_free(&frame)
        }
        
        // Frame for video transcoding (HEVC decode output)
        var videoFrame: UnsafeMutablePointer<AVFrame>?
        // Converted frame for encoder (NV12 pixel format)
        var videoConvertedFrame: UnsafeMutablePointer<AVFrame>?
        if videoDecCtx != nil {
            videoFrame = av_frame_alloc()
            videoConvertedFrame = av_frame_alloc()
        }
        defer {
            av_frame_free(&videoFrame)
            av_frame_free(&videoConvertedFrame)
        }
        
        var wroteAnyPacket = false
        
        // Track the first video DTS for debug logging.
        var videoDtsOffsetInputTB: Int64? = nil  // First video DTS in input timebase (for logging)
        var videoPacketCount = 0  // Debug counter for first few video packets
        
        // --- HLS keyframe alignment ---
        // HLS segments MUST start with a video keyframe (IDR frame) so that each
        // segment is independently decodable. After seeking, the demuxer may
        // return non-keyframe packets first (B/P frames from the preceding GOP).
        // We skip ALL packets (video + audio) until the first video keyframe
        // is found. Audio packets before the keyframe are useless anyway since
        // the player can't display video for that time range.
        var foundFirstVideoKeyframe = false
        
        // --- Fix AV_NOPTS_VALUE DTS from MKV demuxer ---
        // MKV demuxer delivers video packets in decode order but does NOT compute
        // DTS for the first N packets (typically 1-2, the B-frame reorder depth).
        // These arrive with dts = AV_NOPTS_VALUE which corrupts the fMP4 trun box.
        // Strategy: track a monotonic video DTS counter. For any packet with
        // dts == AV_NOPTS_VALUE, assign the next counter value. The counter starts
        // at 0 and increments by the frame duration in the input timebase.
        // After all fixups, enforce strict monotonicity as a final pass.
        var videoDtsCounter: Int64 = 0
        var videoFrameDurationInputTB: Int64 = 0  // computed from stream info or first DTS gap
        var videoFrameDurationComputed = false
        var videoInputStreamIdx: Int = -1  // remember which input stream is video
        var lastVideoDtsOutput: Int64 = -1  // track last DTS written for monotonicity enforcement
        
        while true {
            ret = av_read_frame(inputCtx, pkt)
            if ret < 0 {
                break
            }
            
            let streamIdx = Int(pkt.pointee.stream_index)
            
            guard streamIdx < streamMapping.count, streamMapping[streamIdx] >= 0 else {
                av_packet_unref(pkt)
                continue
            }
            
            let inputStream = inputCtx!.pointee.streams[streamIdx]!
            let outIdx = streamMapping[streamIdx]
            let outputStream = outputCtxUnwrapped.pointee.streams[outIdx]!
            
            // Convert packet PTS to seconds to check against our time window
            let ptsSeconds: Double
            if pkt.pointee.pts != avNoPTS {
                ptsSeconds = Double(pkt.pointee.pts) * av_q2d(inputStream.pointee.time_base)
            } else if pkt.pointee.dts != avNoPTS {
                ptsSeconds = Double(pkt.pointee.dts) * av_q2d(inputStream.pointee.time_base)
            } else {
                ptsSeconds = startTime
            }
            
            // --- Keyframe gate: skip all packets until first video keyframe ---
            // HLS segments MUST start with a video keyframe (IDR frame) so that each
            // segment is independently decodable. After seeking, the demuxer may
            // return non-keyframe packets first (B/P frames from the preceding GOP),
            // or it may land on a keyframe far before the target time if the GOP
            // interval is large.
            //
            // Strategy: skip ALL packets until we find a video keyframe whose PTS
            // is within a reasonable window of the segment start time. For segment 0
            // (startTime == 0), accept any keyframe. For later segments, require the
            // keyframe PTS to be >= startTime - segmentDuration to avoid grabbing a
            // keyframe from a much earlier position (which would duplicate content).
            if !foundFirstVideoKeyframe {
                let isVideo = inputStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                if isVideo {
                    let isKeyframe = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0
                    // Accept a keyframe if it's close enough to the target start time.
                    // For segment 0, any keyframe is fine. For later segments, the
                    // keyframe must be within one segment duration before startTime.
                    let keyframeMinTime = startTime > 0 ? startTime - duration : 0.0
                    if isKeyframe && ptsSeconds >= keyframeMinTime {
                        foundFirstVideoKeyframe = true
                        // Continue to process this keyframe packet below
                    } else {
                        // Either not a keyframe, or a keyframe too far before our
                        // target time — skip it
                        av_packet_unref(pkt)
                        continue
                    }
                } else {
                    // Audio/other packet before first video keyframe — skip it
                    // (audio before the keyframe can't be displayed in sync)
                    av_packet_unref(pkt)
                    continue
                }
            }
            
            // Stop after reaching end time (only on video keyframes to avoid cutting mid-GOP)
            if ptsSeconds >= endTime {
                let isVideo = inputStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                if isVideo {
                    av_packet_unref(pkt)
                    break
                }
                if ptsSeconds >= endTime + 1.0 {
                    av_packet_unref(pkt)
                    break
                }
            }
            
            // Check if this audio stream needs transcoding
            if audioNeedsTranscode[streamIdx] == true,
               let decCtx = audioDecCtx,
               let encCtx = audioEncCtx,
               let audioFrame = frame,
               swrCtx != nil,
               let fifo = audioFifo {
                // --- Transcode audio: decode -> resample -> FIFO -> encode AAC ---
                // The FIFO buffers resampled samples so we can feed the AAC encoder
                // exactly frame_size (1024) samples at a time, regardless of the
                // decoder's output frame size (e.g. EAC3 = 1536 samples).
                ret = avcodec_send_packet(decCtx, pkt)
                av_packet_unref(pkt)
                if ret < 0 { continue }
                
                while true {
                    ret = avcodec_receive_frame(decCtx, audioFrame)
                    if ret < 0 { break }
                    
                    // Initialize audioNextPts from the first decoded audio frame
                    // so transcoded audio timestamps align with the segment's
                    // position in the overall timeline (not starting from 0).
                    if !audioNextPtsInitialized {
                        let avNoPTSLocal = Int64(bitPattern: UInt64(0x8000000000000000))
                        if audioFrame.pointee.pts != avNoPTSLocal {
                            // Convert from decoder time_base to encoder time_base
                            let decTB = decCtx.pointee.time_base
                            let encTB = encCtx.pointee.time_base
                            audioNextPts = av_rescale_q(audioFrame.pointee.pts, decTB, encTB)
                        }
                        audioNextPtsInitialized = true
                    }
                    
                    // Resample using swr_convert_frame into a temporary frame
                    var resFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
                    guard let rf = resFrame else { break }
                    rf.pointee.sample_rate = encCtx.pointee.sample_rate
                    rf.pointee.format = encCtx.pointee.sample_fmt.rawValue
                    rf.pointee.ch_layout = encCtx.pointee.ch_layout
                    
                    ret = swr_convert_frame(swrCtx, rf, audioFrame)
                    av_frame_unref(audioFrame)
                    
                    if ret < 0 {
                        av_frame_free(&resFrame)
                        continue
                    }
                    
                    let convertedSamples = rf.pointee.nb_samples
                    if convertedSamples > 0 {
                        // Write resampled samples to FIFO using the frame's extended_data
                        if let extData = rf.pointee.extended_data {
                            extData.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 8) { rawPtr in
                                _ = av_audio_fifo_write(fifo, rawPtr, convertedSamples)
                            }
                        }
                    }
                    av_frame_free(&resFrame)
                    
                    // Drain FIFO in encoder frame_size chunks
                    let frameSize = Int(encCtx.pointee.frame_size)
                    while av_audio_fifo_size(fifo) >= Int32(frameSize) {
                        var encFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
                        guard let ef = encFrame else { break }
                        ef.pointee.nb_samples = Int32(frameSize)
                        ef.pointee.format = encCtx.pointee.sample_fmt.rawValue
                        ef.pointee.ch_layout = encCtx.pointee.ch_layout
                        ef.pointee.sample_rate = encCtx.pointee.sample_rate
                        
                        ret = av_frame_get_buffer(ef, 0)
                        guard ret >= 0 else {
                            av_frame_free(&encFrame)
                            break
                        }
                        
                        // Read samples from FIFO into the frame's data buffers
                        withUnsafeMutablePointer(to: &ef.pointee.data) { dataPtr in
                            dataPtr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 8) { rawPtr in
                                _ = av_audio_fifo_read(fifo, rawPtr, Int32(frameSize))
                            }
                        }
                        
                        ef.pointee.pts = audioNextPts
                        audioNextPts = audioNextPts &+ Int64(frameSize)
                        
                        ret = avcodec_send_frame(encCtx, ef)
                        av_frame_free(&encFrame)
                        if ret < 0 { continue }
                        
                        // Read encoded packets
                        let encPkt = av_packet_alloc()!
                        while true {
                            ret = avcodec_receive_packet(encCtx, encPkt)
                            if ret < 0 { break }
                            
                            encPkt.pointee.stream_index = Int32(outIdx)
                            av_packet_rescale_ts(encPkt, encCtx.pointee.time_base, outputStream.pointee.time_base)
                            
                            if encPkt.pointee.dts < 0 {
                                let offset = Int64(bitPattern: 0) &- encPkt.pointee.dts
                                encPkt.pointee.dts = 0
                                if encPkt.pointee.pts != avNoPTS {
                                    let newPTS = encPkt.pointee.pts &+ offset
                                    encPkt.pointee.pts = newPTS < 0 ? 0 : newPTS
                                }
                            }
                            
                            encPkt.pointee.pos = -1
                            ret = av_interleaved_write_frame(outputCtxUnwrapped, encPkt)
                            if ret >= 0 { wroteAnyPacket = true }
                        }
                        var ep: UnsafeMutablePointer<AVPacket>? = encPkt
                        av_packet_free(&ep)
                    }
                }
                continue
            }
            
            // --- Video transcode path (HEVC→H.264) ---
            if videoNeedsTranscode && streamIdx == videoTranscodeInputIdx,
               let vDecCtx = videoDecCtx,
               let vEncCtx = videoEncCtx,
               let vFrame = videoFrame,
               let vConvFrame = videoConvertedFrame {
                
                ret = avcodec_send_packet(vDecCtx, pkt)
                av_packet_unref(pkt)
                if ret < 0 { continue }
                
                while true {
                    ret = avcodec_receive_frame(vDecCtx, vFrame)
                    if ret < 0 { break }
                    
                    // Lazily initialize SwsContext when we know the actual decoded pixel format
                    if swsCtx == nil {
                        let srcFmt = AVPixelFormat(rawValue: vFrame.pointee.format)
                        let dstFmt = vEncCtx.pointee.pix_fmt
                        print("Setting up sws: \(srcFmt.rawValue) -> \(dstFmt.rawValue) (\(vDecCtx.pointee.width)x\(vDecCtx.pointee.height))")
                        swsCtx = sws_getContext(
                            vDecCtx.pointee.width, vDecCtx.pointee.height, srcFmt,
                            vEncCtx.pointee.width, vEncCtx.pointee.height, dstFmt,
                            Int32(SWS_FAST_BILINEAR.rawValue), nil, nil, nil
                        )
                        if swsCtx == nil {
                            print("WARNING: sws_getContext failed! Video transcode will skip frames.")
                            av_frame_unref(vFrame)
                            continue
                        }
                        
                        // Allocate buffer for converted frame
                        vConvFrame.pointee.format = dstFmt.rawValue
                        vConvFrame.pointee.width = vEncCtx.pointee.width
                        vConvFrame.pointee.height = vEncCtx.pointee.height
                        ret = av_frame_get_buffer(vConvFrame, 0)
                        if ret < 0 {
                            print("WARNING: av_frame_get_buffer failed for converted frame: \(Self.ffmpegErrorString(ret))")
                            sws_freeContext(swsCtx)
                            swsCtx = nil
                            av_frame_unref(vFrame)
                            continue
                        }
                    }
                    
                    // Convert pixel format (e.g. yuv420p10le → NV12)
                    ret = av_frame_make_writable(vConvFrame)
                    if ret < 0 {
                        av_frame_unref(vFrame)
                        continue
                    }
                    
                    withUnsafePointer(to: vFrame.pointee.data) { srcData in
                        withUnsafePointer(to: vFrame.pointee.linesize) { srcLinesize in
                            srcData.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { srcPtr in
                                srcLinesize.withMemoryRebound(to: Int32.self, capacity: 8) { srcLsPtr in
                                    withUnsafeMutablePointer(to: &vConvFrame.pointee.data) { dstData in
                                        withUnsafeMutablePointer(to: &vConvFrame.pointee.linesize) { dstLinesize in
                                            dstData.withMemoryRebound(to: UnsafeMutablePointer<UInt8>?.self, capacity: 8) { dstPtr in
                                                dstLinesize.withMemoryRebound(to: Int32.self, capacity: 8) { dstLsPtr in
                                                    sws_scale(
                                                        swsCtx,
                                                        srcPtr, srcLsPtr,
                                                        0, vDecCtx.pointee.height,
                                                        dstPtr, dstLsPtr
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    // Copy timing from decoded frame
                    vConvFrame.pointee.pts = vFrame.pointee.pts
                    vConvFrame.pointee.pkt_dts = vFrame.pointee.pkt_dts
                    vConvFrame.pointee.duration = vFrame.pointee.duration
                    // Copy picture type so encoder knows about keyframes
                    vConvFrame.pointee.pict_type = AV_PICTURE_TYPE_NONE  // Let encoder decide
                    
                    av_frame_unref(vFrame)
                    
                    // Encode to H.264
                    ret = avcodec_send_frame(vEncCtx, vConvFrame)
                    if ret < 0 {
                        if ret != -11 { // EAGAIN
                            print("avcodec_send_frame (video) failed: \(Self.ffmpegErrorString(ret))")
                        }
                        // Try to drain encoder even if send failed with EAGAIN
                    }
                    
                    // Read encoded H.264 packets
                    let encPkt = av_packet_alloc()!
                    while true {
                        ret = avcodec_receive_packet(vEncCtx, encPkt)
                        if ret < 0 { break }
                        
                        encPkt.pointee.stream_index = Int32(outIdx)
                        av_packet_rescale_ts(encPkt, vEncCtx.pointee.time_base, outputStream.pointee.time_base)
                        
                        // Fix negative DTS
                        if encPkt.pointee.dts < 0 {
                            let offset = Int64(bitPattern: 0) &- encPkt.pointee.dts
                            encPkt.pointee.dts = 0
                            if encPkt.pointee.pts != avNoPTS {
                                let newPTS = encPkt.pointee.pts &+ offset
                                encPkt.pointee.pts = newPTS < 0 ? 0 : newPTS
                            }
                        }
                        
                        encPkt.pointee.pos = -1
                        ret = av_interleaved_write_frame(outputCtxUnwrapped, encPkt)
                        if ret >= 0 { wroteAnyPacket = true }
                    }
                    var ep: UnsafeMutablePointer<AVPacket>? = encPkt
                    av_packet_free(&ep)
                }
                continue
            }
            
            // --- Passthrough (copy) for compatible streams (H.264 video, audio) ---
            
            // Fix video DTS from MKV demuxer and normalize to zero-based.
            // (Only needed for HEVC passthrough — but kept for any MKV video stream)
            if inputStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO && !videoNeedsTranscode {
                
                // Compute frame duration once from stream metadata
                if !videoFrameDurationComputed {
                    videoInputStreamIdx = streamIdx
                    let tb = inputStream.pointee.time_base
                    // Try r_frame_rate first (most reliable for MKV), then avg_frame_rate
                    let rfr = inputStream.pointee.r_frame_rate
                    let afr = inputStream.pointee.avg_frame_rate
                    if rfr.num > 0 && rfr.den > 0 {
                        // frame_duration_in_tb = time_base.den / (r_frame_rate * time_base.num)
                        // = (tb.den * rfr.den) / (rfr.num * tb.num)
                        videoFrameDurationInputTB = Int64(tb.den) * Int64(rfr.den) / (Int64(rfr.num) * Int64(tb.num))
                    } else if afr.num > 0 && afr.den > 0 {
                        videoFrameDurationInputTB = Int64(tb.den) * Int64(afr.den) / (Int64(afr.num) * Int64(tb.num))
                    } else {
                        // Fallback: assume 24fps
                        videoFrameDurationInputTB = Int64(tb.den) / (24 * Int64(tb.num))
                    }
                    if videoFrameDurationInputTB <= 0 { videoFrameDurationInputTB = 1 }
                    videoFrameDurationComputed = true
                    print("Video frame duration in input TB: \(videoFrameDurationInputTB) (TB: \(tb.num)/\(tb.den), r_frame_rate: \(rfr.num)/\(rfr.den))")
                }
                
                let origDts = pkt.pointee.dts
                let origPts = pkt.pointee.pts
                
                // Fix AV_NOPTS_VALUE DTS: assign monotonic counter value
                // (MKV demuxer may not compute DTS for B-frame reorder depth)
                if pkt.pointee.dts == avNoPTS {
                    pkt.pointee.dts = videoDtsCounter
                    videoDtsCounter = videoDtsCounter &+ videoFrameDurationInputTB
                } else {
                    // Real DTS from demuxer — update counter to stay ahead
                    if pkt.pointee.dts &+ videoFrameDurationInputTB > videoDtsCounter {
                        videoDtsCounter = pkt.pointee.dts &+ videoFrameDurationInputTB
                    }
                }
                
                // Log first video packet for debugging
                if videoDtsOffsetInputTB == nil {
                    videoDtsOffsetInputTB = pkt.pointee.dts
                    let isKey = (pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0
                    print("Segment video start: dts=\(pkt.pointee.dts) pts=\(pkt.pointee.pts) flags=\(pkt.pointee.flags) keyframe=\(isKey) (input TB: \(inputStream.pointee.time_base.num)/\(inputStream.pointee.time_base.den))")
                }
                
                // --- Preserve original timestamps (no zero-normalization) ---
                // HLS MPEG-TS segments carry their original source timestamps.
                // AVPlayer uses the MPEG-TS PCR and internal PTS/DTS to place
                // frames on the correct position in the timeline. Zero-normalizing
                // DTS would cause all segments to appear to start at t=0, breaking
                // playback when segments don't align to exact playlist boundaries
                // (e.g., when keyframe intervals don't match segment duration).
                
                // Ensure DTS <= PTS (required for valid MPEG-TS)
                if pkt.pointee.pts != avNoPTS && pkt.pointee.dts > pkt.pointee.pts {
                    pkt.pointee.dts = pkt.pointee.pts
                }
                
                // Enforce strict DTS monotonicity: if this DTS would go backwards
                // or equal the previous one, bump it. This handles cases where the
                // MKV demuxer's real DTS overlaps with our synthetic DTS assignments.
                if lastVideoDtsOutput >= 0 && pkt.pointee.dts <= lastVideoDtsOutput {
                    pkt.pointee.dts = lastVideoDtsOutput &+ 1
                    // Also ensure DTS <= PTS after bump
                    if pkt.pointee.pts != avNoPTS && pkt.pointee.dts > pkt.pointee.pts {
                        pkt.pointee.pts = pkt.pointee.dts
                    }
                }
                lastVideoDtsOutput = pkt.pointee.dts
                
                // Debug: print first 5 video packets
                if videoPacketCount < 5 {
                    print("  video pkt[\(videoPacketCount)]: origDts=\(origDts) origPts=\(origPts) -> fixedDts=\(pkt.pointee.dts) fixedPts=\(pkt.pointee.pts)")
                }
                videoPacketCount += 1
            }
            
            pkt.pointee.stream_index = Int32(outIdx)
            av_packet_rescale_ts(pkt, inputStream.pointee.time_base, outputStream.pointee.time_base)
            
            if pkt.pointee.dts < 0 {
                // Use overflow-safe arithmetic — MKV timestamps can be huge
                let offset = Int64(bitPattern: 0) &- pkt.pointee.dts
                pkt.pointee.dts = 0
                if pkt.pointee.pts != avNoPTS {
                    let newPTS = pkt.pointee.pts &+ offset
                    pkt.pointee.pts = newPTS < 0 ? 0 : newPTS
                }
            }
            
            pkt.pointee.pos = -1
            ret = av_interleaved_write_frame(outputCtxUnwrapped, pkt)
            if ret < 0 {
                print("Warning: av_interleaved_write_frame failed: \(Self.ffmpegErrorString(ret))")
            } else {
                wroteAnyPacket = true
            }
        }
        
        // Flush resampler — drain any buffered samples in SwrContext
        if let swr = swrCtx, let encCtx = audioEncCtx, let fifo = audioFifo {
            // Flush swr: pass nil input to swr_convert_frame to get remaining buffered samples
            while true {
                var flushFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
                guard let ff = flushFrame else { break }
                ff.pointee.sample_rate = encCtx.pointee.sample_rate
                ff.pointee.format = encCtx.pointee.sample_fmt.rawValue
                ff.pointee.ch_layout = encCtx.pointee.ch_layout
                
                ret = swr_convert_frame(swr, ff, nil)
                if ret < 0 || ff.pointee.nb_samples == 0 {
                    av_frame_free(&flushFrame)
                    break
                }
                
                // Write flushed samples to FIFO
                let flushedSamples = ff.pointee.nb_samples
                if flushedSamples > 0 {
                    if let extData = ff.pointee.extended_data {
                        extData.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 8) { rawPtr in
                            _ = av_audio_fifo_write(fifo, rawPtr, flushedSamples)
                        }
                    }
                }
                av_frame_free(&flushFrame)
            }
            
            // Drain remaining FIFO samples (may be less than frame_size — that's OK for final frame)
            let frameSize = Int(encCtx.pointee.frame_size)
            let outIdx = streamMapping[audioTranscodeInputIdx]
            let outputStream = outputCtxUnwrapped.pointee.streams[outIdx]!
            
            while av_audio_fifo_size(fifo) > 0 {
                let samplesToRead = min(Int(av_audio_fifo_size(fifo)), frameSize)
                var encFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
                guard let ef = encFrame else { break }
                ef.pointee.nb_samples = Int32(samplesToRead)
                ef.pointee.format = encCtx.pointee.sample_fmt.rawValue
                ef.pointee.ch_layout = encCtx.pointee.ch_layout
                ef.pointee.sample_rate = encCtx.pointee.sample_rate
                
                ret = av_frame_get_buffer(ef, 0)
                guard ret >= 0 else {
                    av_frame_free(&encFrame)
                    break
                }
                
                withUnsafeMutablePointer(to: &ef.pointee.data) { dataPtr in
                    dataPtr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 8) { rawPtr in
                        _ = av_audio_fifo_read(fifo, rawPtr, Int32(samplesToRead))
                    }
                }
                
                ef.pointee.pts = audioNextPts
                audioNextPts = audioNextPts &+ Int64(samplesToRead)
                
                ret = avcodec_send_frame(encCtx, ef)
                av_frame_free(&encFrame)
                if ret < 0 { break }
                
                let encPkt = av_packet_alloc()!
                while true {
                    ret = avcodec_receive_packet(encCtx, encPkt)
                    if ret < 0 { break }
                    
                    encPkt.pointee.stream_index = Int32(outIdx)
                    av_packet_rescale_ts(encPkt, encCtx.pointee.time_base, outputStream.pointee.time_base)
                    
                    if encPkt.pointee.dts < 0 {
                        let offset = Int64(bitPattern: 0) &- encPkt.pointee.dts
                        encPkt.pointee.dts = 0
                        if encPkt.pointee.pts != avNoPTS {
                            let newPTS = encPkt.pointee.pts &+ offset
                            encPkt.pointee.pts = newPTS < 0 ? 0 : newPTS
                        }
                    }
                    
                    encPkt.pointee.pos = -1
                    ret = av_interleaved_write_frame(outputCtxUnwrapped, encPkt)
                    if ret >= 0 { wroteAnyPacket = true }
                }
                var ep: UnsafeMutablePointer<AVPacket>? = encPkt
                av_packet_free(&ep)
            }
        }
        
        // Flush audio encoder (drain remaining buffered frames)
        if let encCtx = audioEncCtx {
            avcodec_send_frame(encCtx, nil) // Signal EOF
            let flushPkt = av_packet_alloc()!
            defer {
                var fp: UnsafeMutablePointer<AVPacket>? = flushPkt
                av_packet_free(&fp)
            }
            while true {
                ret = avcodec_receive_packet(encCtx, flushPkt)
                if ret < 0 { break }
                
                let outIdx = streamMapping[audioTranscodeInputIdx]
                let outputStream = outputCtxUnwrapped.pointee.streams[outIdx]!
                
                flushPkt.pointee.stream_index = Int32(outIdx)
                av_packet_rescale_ts(flushPkt, encCtx.pointee.time_base, outputStream.pointee.time_base)
                
                if flushPkt.pointee.dts < 0 {
                    // Use overflow-safe arithmetic — MKV timestamps can be huge
                    let offset = Int64(bitPattern: 0) &- flushPkt.pointee.dts
                    flushPkt.pointee.dts = 0
                    if flushPkt.pointee.pts != avNoPTS {
                        let newPTS = flushPkt.pointee.pts &+ offset
                        flushPkt.pointee.pts = newPTS < 0 ? 0 : newPTS
                    }
                }
                
                flushPkt.pointee.pos = -1
                ret = av_interleaved_write_frame(outputCtxUnwrapped, flushPkt)
                if ret >= 0 { wroteAnyPacket = true }
            }
        }
        
        // Flush video encoder (drain remaining buffered H.264 frames)
        if let vEncCtx = videoEncCtx {
            print("Flushing H.264 VideoToolbox encoder...")
            avcodec_send_frame(vEncCtx, nil) // Signal EOF
            let flushPkt = av_packet_alloc()!
            defer {
                var fp: UnsafeMutablePointer<AVPacket>? = flushPkt
                av_packet_free(&fp)
            }
            while true {
                ret = avcodec_receive_packet(vEncCtx, flushPkt)
                if ret < 0 { break }
                
                let outIdx = streamMapping[videoTranscodeInputIdx]
                let outputStream = outputCtxUnwrapped.pointee.streams[outIdx]!
                
                flushPkt.pointee.stream_index = Int32(outIdx)
                av_packet_rescale_ts(flushPkt, vEncCtx.pointee.time_base, outputStream.pointee.time_base)
                
                if flushPkt.pointee.dts < 0 {
                    let offset = Int64(bitPattern: 0) &- flushPkt.pointee.dts
                    flushPkt.pointee.dts = 0
                    if flushPkt.pointee.pts != avNoPTS {
                        let newPTS = flushPkt.pointee.pts &+ offset
                        flushPkt.pointee.pts = newPTS < 0 ? 0 : newPTS
                    }
                }
                
                flushPkt.pointee.pos = -1
                ret = av_interleaved_write_frame(outputCtxUnwrapped, flushPkt)
                if ret >= 0 { wroteAnyPacket = true }
            }
            print("H.264 encoder flush complete")
        }
        
        // --- Finalize ---
        ret = av_write_trailer(outputCtxUnwrapped)
        if ret < 0 {
            print("Warning: av_write_trailer failed: \(Self.ffmpegErrorString(ret))")
        }
        
        // Close output file
        if (oformat.pointee.flags & AVFMT_NOFILE) == 0 {
            avio_closep(&outputCtxUnwrapped.pointee.pb)
        }
        
        // MPEG-TS segments are self-contained — no post-processing needed.
        // (The old fMP4 path required stripping ftyp+moov prefix and extracting init.mp4,
        // but MPEG-TS segments are ready to serve as-is.)
        
        guard wroteAnyPacket else {
            throw FFmpegError.conversionFailed("No packets written to segment")
        }
        
        return outputURL
    }

    // MARK: - mpv Encode Mode (Fallback)
    
    ///
    /// Uses mpv's `--o` (encode mode) with VideoToolbox hardware encoding,
    /// falling back to libx264 software encoding if VT fails.
    private func runMPVEncode(
        inputURL: URL,
        outputURL: URL,
        startTime: Double,
        duration: Double,
        videoEncoder: VideoEncoder
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // Use concurrent encodeQueue — bounded by semaphore
            self.encodeQueue.async {
                self.encodeSemaphore.wait()
                defer { self.encodeSemaphore.signal() }
                guard let mpv = mpv_create() else {
                    continuation.resume(throwing: FFmpegError.mpvFailed("Failed to create mpv instance"))
                    return
                }
                defer { mpv_terminate_destroy(mpv) }
                
                // Helper to log option-setting results
                @discardableResult
                func setOpt(_ name: String, _ value: String) -> CInt {
                    let rc = mpv_set_option_string(mpv, name, value)
                    if rc < 0 {
                        print("MPV encode: set '\(name)=\(value)' FAILED: \(String(cString: mpv_error_string(rc)))")
                    }
                    return rc
                }
                
                // Use verbose logging so encoder init failures are visible
                mpv_request_log_messages(mpv, "v")
                
                // Encode mode: output file — must be set FIRST, before vo/ao
                // so mpv knows it's in encode mode and selects vo_lavc/ao_lavc
                setOpt("o", outputURL.path)
                setOpt("of", "mpegts")
                
                // Video encoder
                let selectedEncoder = videoEncoder
                switch selectedEncoder {
                case .h264VideoToolbox:
                    let rc = setOpt("ovc", "h264_videotoolbox")
                    if rc < 0 {
                        continuation.resume(throwing: FFmpegError.mpvFailed("h264_videotoolbox unavailable"))
                        return
                    }
                    setOpt("ovcopts", "b=4000000,maxrate=6000000,bufsize=12000000,realtime=0,profile=high,level=41")
                case .h264VideoToolboxSafe:
                    let rc = setOpt("ovc", "h264_videotoolbox")
                    if rc < 0 {
                        continuation.resume(throwing: FFmpegError.mpvFailed("h264_videotoolbox unavailable"))
                        return
                    }
                    // Safer fallback settings for problematic files/devices.
                    setOpt("ovcopts", "b=2500000,maxrate=3000000,bufsize=6000000,realtime=1,profile=main,level=40")
                case .libx264Software:
                    let rc = setOpt("ovc", "libx264")
                    if rc < 0 {
                        continuation.resume(throwing: FFmpegError.mpvFailed("libx264 unavailable"))
                        return
                    }
                    // Fast preset for acceptable speed on mobile; CRF-style via -b:v 0 + crf
                    setOpt("ovcopts", "preset=veryfast,crf=23,profile=main,level=40")
                }
                
                // Audio encoder: always AAC for HLS compatibility
                setOpt("oac", "aac")
                setOpt("oacopts", "b=192000")
                
                // Enable streams, disable subtitles
                setOpt("vid", "auto")
                setOpt("aid", "auto")
                setOpt("sid", "no")
                
                // Do NOT set vf=format=yuv420p — it can cause frame drops in encode
                // mode when the source pixel format doesn't align. VideoToolbox and
                // libx264 both handle format conversion internally.
                
                // CRITICAL: Preserve input PTS in the output.
                // Without this, each segment's PTS resets to 0, breaking HLS
                // because AVPlayer expects continuous PTS across segments.
                // --orawts copies input pts to the output as-is.
                // In safe/software mode we disable it to avoid PES corruption.
                let useRawTS = selectedEncoder == .h264VideoToolbox
                setOpt("orawts", useRawTS ? "yes" : "no")
                
                // Seek to segment start
                setOpt("start", String(startTime))
                setOpt("length", String(duration))
                
                // Use hardware decode for the input — matches the playback pipeline
                // and avoids software decode issues on iOS for certain codecs.
                // VideoToolbox decode feeds directly into VideoToolbox encode when
                // both are active, avoiding unnecessary CPU copies.
                setOpt("hwdec", "auto")
                
                // Disable cache
                setOpt("cache", "no")
                
                // Initialize
                let initResult = mpv_initialize(mpv)
                if initResult < 0 {
                    continuation.resume(throwing: FFmpegError.mpvFailed("mpv_initialize failed: \(String(cString: mpv_error_string(initResult)))"))
                    return
                }
                
                print("MPV encode: initialized (encoder=\(selectedEncoder.rawValue), orawts=\(useRawTS), start=\(startTime), length=\(duration)), loading \(inputURL.lastPathComponent)")
                
                // Load file
                var args: [String?] = ["loadfile", inputURL.path, "replace", nil]
                let cStrings = args.map { $0.flatMap { strdup($0) } }
                defer { cStrings.forEach { $0.map { free($0) } } }
                var ptrs = cStrings.map { $0.map { UnsafePointer($0) } }
                let loadResult = mpv_command(mpv, &ptrs)
                if loadResult < 0 {
                    print("MPV encode: loadfile command failed: \(String(cString: mpv_error_string(loadResult)))")
                }
                
                // Wait for encoding to complete, collecting log messages
                var done = false
                var fatalEncodeError: String?
                while !done {
                    let event = mpv_wait_event(mpv, 60)
                    guard let event else {
                        continuation.resume(throwing: FFmpegError.mpvFailed("mpv_wait_event returned nil"))
                        return
                    }
                    
                    switch event.pointee.event_id {
                    case MPV_EVENT_LOG_MESSAGE:
                        let msg = event.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                        let text = String(cString: msg.text).trimmingCharacters(in: .whitespacesAndNewlines)
                        let prefix = String(cString: msg.prefix)
                        let level = String(cString: msg.level)
                        // Only print warnings/errors to avoid flooding the console,
                        // but still capture verbose messages for fatal error detection.
                        if level != "v" && level != "debug" && level != "trace" {
                            print("MPV encode[\(prefix)]: \(text)")
                        }
                        let lower = text.lowercased()
                        if lower.contains("codec '") && lower.contains("not found") {
                            fatalEncodeError = text
                        }
                        if lower.contains("error opening/initializing") {
                            fatalEncodeError = text
                        }
                        if lower.contains("frame size not set") {
                            fatalEncodeError = text
                        }
                        if lower.contains("could not open codec") {
                            fatalEncodeError = text
                        }
                        if lower.contains("encoder init failed") {
                            fatalEncodeError = text
                        }
                        
                    case MPV_EVENT_END_FILE:
                        let endFile = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        if let fatalEncodeError {
                            continuation.resume(throwing: FFmpegError.mpvFailed("Encoding failed: \(fatalEncodeError)"))
                        } else if endFile.reason == MPV_END_FILE_REASON_ERROR {
                            let errorStr = String(cString: mpv_error_string(endFile.error))
                            continuation.resume(throwing: FFmpegError.mpvFailed("Encoding failed: \(errorStr)"))
                        } else {
                            if FileManager.default.fileExists(atPath: outputURL.path) {
                                continuation.resume(returning: outputURL)
                            } else {
                                continuation.resume(throwing: FFmpegError.conversionFailed("Segment file not produced"))
                            }
                        }
                        done = true
                        
                    case MPV_EVENT_SHUTDOWN:
                        if !done {
                            if FileManager.default.fileExists(atPath: outputURL.path) {
                                continuation.resume(returning: outputURL)
                            } else {
                                continuation.resume(throwing: FFmpegError.mpvFailed("mpv shutdown before encoding completed"))
                            }
                            done = true
                        }
                        
                    case MPV_EVENT_NONE:
                        continuation.resume(throwing: FFmpegError.mpvFailed("Encoding timed out (60s)"))
                        done = true
                        
                    default:
                        break
                    }
                }
            }
        }
    }

    

    // MARK: - Subtitle Operations (mpv-based)
    
    /// Probes the video file for embedded subtitle streams using a headless mpv instance.
    /// Returns an array of SubtitleTrack representing each embedded subtitle stream.
    func probeSubtitles(in url: URL) async throws -> [SubtitleTrack] {
        print("Probing for embedded subtitles in: \(url.lastPathComponent)")
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let mpv = mpv_create() else {
                    continuation.resume(returning: [])
                    return
                }
                defer { mpv_terminate_destroy(mpv) }
                
                // Headless — no output
                mpv_set_option_string(mpv, "vo", "null")
                mpv_set_option_string(mpv, "ao", "null")
                
                // Disable video decoding for speed, but keep audio as timeline driver
                // so mpv actually loads the file and populates the track list.
                // With vid=no AND aid=no, mpv has no timeline and FILE_LOADED may never fire.
                mpv_set_option_string(mpv, "vid", "no")
                mpv_set_option_string(mpv, "aid", "auto")
                
                // Don't actually play
                mpv_set_option_string(mpv, "pause", "yes")
                
                // Suppress logs
                mpv_request_log_messages(mpv, "error")
                
                // We need demuxer to scan streams but not decode
                mpv_set_option_string(mpv, "demuxer-lavf-analyzeduration", "1")
                mpv_set_option_string(mpv, "demuxer-lavf-probesize", "500000")
                
                let initResult = mpv_initialize(mpv)
                guard initResult == 0 else {
                    print("   mpv init failed for probe: \(String(cString: mpv_error_string(initResult)))")
                    continuation.resume(returning: [])
                    return
                }
                
                // Load file
                var args: [String?] = ["loadfile", url.path, "replace", nil]
                let cStrings = args.map { $0.flatMap { strdup($0) } }
                defer { cStrings.forEach { $0.map { free($0) } } }
                var ptrs = cStrings.map { $0.map { UnsafePointer($0) } }
                mpv_command(mpv, &ptrs)
                
                // Wait for file to load (we need track list to be populated)
                var fileLoaded = false
                for _ in 0..<200 { // Max ~20 seconds
                    let event = mpv_wait_event(mpv, 0.1)
                    guard let event else { continue }
                    
                    if event.pointee.event_id == MPV_EVENT_FILE_LOADED {
                        fileLoaded = true
                        break
                    }
                    if event.pointee.event_id == MPV_EVENT_END_FILE ||
                       event.pointee.event_id == MPV_EVENT_SHUTDOWN {
                        break
                    }
                }
                
                guard fileLoaded else {
                    print("   File did not load for subtitle probing")
                    continuation.resume(returning: [])
                    return
                }
                
                // Read track-list properties
                var countVal = Int64(0)
                mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &countVal)
                let count = Int(countVal)
                
                var tracks: [SubtitleTrack] = []
                
                for i in 0..<count {
                    let typeStr = mpv_get_property_string(mpv, "track-list/\(i)/type")
                    let typeString = typeStr.map { String(cString: $0) }
                    mpv_free(typeStr)
                    
                    guard typeString == "sub" else { continue }
                    
                    var idVal = Int64(0)
                    mpv_get_property(mpv, "track-list/\(i)/id", MPV_FORMAT_INT64, &idVal)
                    
                    let titleStr = mpv_get_property_string(mpv, "track-list/\(i)/title")
                    let title = titleStr.map { String(cString: $0) }
                    mpv_free(titleStr)
                    
                    let langStr = mpv_get_property_string(mpv, "track-list/\(i)/lang")
                    let lang = langStr.map { String(cString: $0) }
                    mpv_free(langStr)
                    
                    let codecStr = mpv_get_property_string(mpv, "track-list/\(i)/codec")
                    let codec = codecStr.map { String(cString: $0) }
                    mpv_free(codecStr)
                    
                    // Skip bitmap-based subtitle codecs (PGS, DVB, DVD/VobSub) —
                    // these are image-based and can't be converted to WebVTT text
                    let bitmapCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "dvb_teletext"]
                    if let codec = codec, bitmapCodecs.contains(codec) {
                        print("   Skipping bitmap subtitle: stream \(i), codec: \(codec)")
                        continue
                    }
                    
                    // mpv uses its own track IDs, but for FFmpeg stream mapping we need
                    // the demuxer index. mpv's track-list/N/demux-id or
                    // track-list/N/ff-index gives us the FFmpeg stream index.
                    var ffIndex = Int64(0)
                    mpv_get_property(mpv, "track-list/\(i)/ff-index", MPV_FORMAT_INT64, &ffIndex)
                    let streamIndex = Int(ffIndex)
                    
                    let displayTitle = title ?? "Subtitle \(idVal) (\(codec ?? "unknown"))"
                    
                    let track = SubtitleTrack(
                        id: "embedded_\(streamIndex)",
                        title: displayTitle,
                        language: lang,
                        source: .embedded(streamIndex: streamIndex)
                    )
                    tracks.append(track)
                    print("   Found subtitle: \(track.displayName) [stream \(streamIndex), codec: \(codec ?? "?")]")
                }
                
                print("   Found \(tracks.count) embedded subtitle track(s)")
                continuation.resume(returning: tracks)
            }
        }
    }
    
    /// Extracts an embedded subtitle stream to a WebVTT file using FFmpeg C API
    /// (via MPVKit's bundled Libavformat/Libavcodec).
    ///
    /// mpv's encode mode cannot extract subtitles alone (needs a video/audio timeline
    /// driver), so we use a different approach: play the file with mpv in headless mode,
    /// observe `sub-text` changes, and collect all subtitle events into a VTT file.
    ///
    /// Actually, the most reliable approach is to use mpv to play through the file
    /// at high speed and capture subtitle timing via property observation.
    /// - Parameters:
    ///   - sourceURL: The video file containing the subtitle
    ///   - streamIndex: The stream index of the subtitle to extract
    /// - Returns: URL of the extracted .vtt file (with X-TIMESTAMP-MAP for HLS)
    func extractSubtitle(from sourceURL: URL, streamIndex: Int) async throws -> URL {
        let outputPath = outputDirectory.appendingPathComponent("subtitle_\(streamIndex).vtt")
        
        // If already extracted, return cached
        if FileManager.default.fileExists(atPath: outputPath.path) {
            print("   Using cached subtitle for stream \(streamIndex)")
            return outputPath
        }
        
        print("   Extracting subtitle stream \(streamIndex) to WebVTT...")
        
        // Use FFmpeg C API to read subtitle packets directly from the demuxer.
        // This gives exact PTS timestamps, unlike the old mpv-at-100x approach.
        let subtitleCues = try extractSubtitleCuesFFmpeg(from: sourceURL, streamIndex: streamIndex)
        
        // Build WebVTT content
        var vtt = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"
        
        for (i, cue) in subtitleCues.enumerated() {
            let startTS = formatVTTTimestamp(cue.startTime)
            let endTS = formatVTTTimestamp(cue.endTime)
            vtt += "\(i + 1)\n"
            vtt += "\(startTS) --> \(endTS)\n"
            vtt += "\(cue.text)\n"
            vtt += "\n"
        }
        
        try vtt.write(to: outputPath, atomically: true, encoding: .utf8)
        print("   Subtitle extracted: \(outputPath.lastPathComponent) (\(subtitleCues.count) cues)")
        
        return outputPath
    }
    
    /// Represents a single subtitle cue extracted from a video file
    private struct ExtractedCue {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
    }
    
    /// Extracts subtitle cues using the FFmpeg C API for precise timestamps.
    /// Reads subtitle packets directly from the demuxer — no playback needed.
    /// Supports subrip (SRT), ASS/SSA, and other text-based subtitle codecs.
    private func extractSubtitleCuesFFmpeg(from sourceURL: URL, streamIndex: Int) throws -> [ExtractedCue] {
        let inputPath = sourceURL.path
        
        // Open input
        var inputCtx: UnsafeMutablePointer<AVFormatContext>?
        var ret = avformat_open_input(&inputCtx, inputPath, nil, nil)
        guard ret >= 0, inputCtx != nil else {
            throw FFmpegError.conversionFailed("avformat_open_input failed for subtitle extraction: \(Self.ffmpegErrorString(ret))")
        }
        defer {
            var ctx = inputCtx
            avformat_close_input(&ctx)
        }
        
        ret = avformat_find_stream_info(inputCtx, nil)
        guard ret >= 0 else {
            throw FFmpegError.conversionFailed("avformat_find_stream_info failed: \(Self.ffmpegErrorString(ret))")
        }
        
        // Verify stream index is valid and is a subtitle stream
        let nbStreams = Int(inputCtx!.pointee.nb_streams)
        guard streamIndex < nbStreams else {
            throw FFmpegError.conversionFailed("Stream index \(streamIndex) out of range (file has \(nbStreams) streams)")
        }
        
        let subtitleStream = inputCtx!.pointee.streams[streamIndex]!
        guard subtitleStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else {
            throw FFmpegError.conversionFailed("Stream \(streamIndex) is not a subtitle stream")
        }
        
        let timeBase = subtitleStream.pointee.time_base
        let codecId = subtitleStream.pointee.codecpar.pointee.codec_id
        
        // Determine subtitle codec type for text parsing
        let isASS = (codecId == AV_CODEC_ID_ASS || codecId == AV_CODEC_ID_SSA)
        
        print("   Subtitle stream \(streamIndex): codec=\(isASS ? "ASS/SSA" : "subrip/text"), timebase=\(timeBase.num)/\(timeBase.den)")
        
        // Read all packets from this stream
        var cues: [ExtractedCue] = []
        let pkt = av_packet_alloc()!
        defer {
            var pktPtr: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&pktPtr)
        }
        
        while true {
            ret = av_read_frame(inputCtx, pkt)
            if ret < 0 { break } // EOF or error
            
            defer { av_packet_unref(pkt) }
            
            // Skip packets from other streams
            guard Int(pkt.pointee.stream_index) == streamIndex else { continue }
            
            // Get precise timestamps
            let pts = pkt.pointee.pts
            let duration = pkt.pointee.duration
            
            // Skip packets without valid PTS
            let nopts = Int64(bitPattern: UInt64(0x8000000000000000)) // AV_NOPTS_VALUE
            guard pts != nopts else { continue }
            
            let startTime = Double(pts) * av_q2d(timeBase)
            let endTime: Double
            if duration > 0 {
                endTime = startTime + Double(duration) * av_q2d(timeBase)
            } else {
                // No duration — estimate 3 seconds
                endTime = startTime + 3.0
            }
            
            // Extract text from packet data
            guard pkt.pointee.size > 0, let data = pkt.pointee.data else { continue }
            
            let rawText = String(
                bytesNoCopy: UnsafeMutableRawPointer(data),
                length: Int(pkt.pointee.size),
                encoding: .utf8,
                freeWhenDone: false
            ) ?? ""
            
            guard !rawText.isEmpty else { continue }
            
            // Parse the text based on codec type
            let cleanText: String
            if isASS {
                // ASS packet format: "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"
                // We need to extract just the Text field (everything after the 8th comma)
                cleanText = Self.extractASSDialogueText(rawText)
            } else {
                // SRT/subrip: packet data is just the subtitle text (may contain HTML tags)
                // Strip basic HTML tags for WebVTT
                cleanText = rawText
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            guard !cleanText.isEmpty else { continue }
            
            cues.append(ExtractedCue(
                startTime: startTime,
                endTime: endTime,
                text: cleanText
            ))
        }
        
        // Sort by start time (packets are usually in order, but be safe)
        cues.sort { $0.startTime < $1.startTime }
        
        print("   Extracted \(cues.count) subtitle cues via FFmpeg (precise timestamps)")
        return cues
    }
    
    /// Extracts the text portion from an ASS dialogue event packet.
    /// ASS packets in containers use the format:
    /// `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`
    /// (9 fields separated by commas, Text may contain commas)
    private static func extractASSDialogueText(_ raw: String) -> String {
        // Split on first 8 commas to get the Text field
        var commaCount = 0
        var textStartIndex = raw.startIndex
        for (i, char) in raw.enumerated() {
            if char == "," {
                commaCount += 1
                if commaCount == 8 {
                    textStartIndex = raw.index(raw.startIndex, offsetBy: i + 1)
                    break
                }
            }
        }
        
        guard commaCount >= 8 else {
            // Fallback: return the whole string with ASS tags stripped
            return raw
                .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        var text = String(raw[textStartIndex...])
        // Remove ASS override tags like {\an8}, {\i1}, {\b1}, etc.
        text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        // Replace ASS newlines with actual newlines
        text = text.replacingOccurrences(of: "\\N", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }
    
    /// Converts an SRT file to WebVTT format
    /// SRT and VTT are nearly identical — just needs a header and comma->dot replacement in timestamps
    func convertSRTtoWebVTT(srtURL: URL) throws -> URL {
        let srtContent = try String(contentsOf: srtURL, encoding: .utf8)
        let vttContent = Self.srtToWebVTT(srtContent)
        
        let vttFilename = srtURL.deletingPathExtension().lastPathComponent + ".vtt"
        let vttPath = outputDirectory.appendingPathComponent(vttFilename)
        try vttContent.write(to: vttPath, atomically: true, encoding: .utf8)
        
        print("   Converted SRT to WebVTT: \(vttPath.lastPathComponent)")
        return vttPath
    }
    
    /// Pure function: converts SRT text to WebVTT text (with X-TIMESTAMP-MAP for HLS)
    static func srtToWebVTT(_ srt: String) -> String {
        // Normalize line endings to \n (SRT files often use \r\n from Windows)
        let normalized = srt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        
        var result = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"
        
        let lines = normalized.components(separatedBy: "\n")
        
        for line in lines {
            if line.contains(" --> ") {
                result += line.replacingOccurrences(of: ",", with: ".") + "\n"
            } else {
                result += line + "\n"
            }
        }
        
        return result
    }
    
    /// Copies an external subtitle file (VTT/ASS) to the output directory,
    /// converting if necessary. Returns the URL of the ready-to-serve .vtt file.
    func prepareExternalSubtitle(from fileURL: URL) throws -> URL {
        let format = SubtitleFormat.from(url: fileURL)
        
        switch format {
        case .srt:
            return try convertSRTtoWebVTT(srtURL: fileURL)
        case .vtt:
            // Already VTT — copy to output directory if needed
            let destPath = outputDirectory.appendingPathComponent(fileURL.lastPathComponent)
            if fileURL.path == destPath.path {
                try? Self.injectTimestampMap(at: destPath)
                return destPath
            }
            if !FileManager.default.fileExists(atPath: destPath.path) {
                try FileManager.default.copyItem(at: fileURL, to: destPath)
            }
            try? Self.injectTimestampMap(at: destPath)
            return destPath
        case .ass, .ssa:
            // ASS/SSA — parse and convert using pure Swift
            return try convertASStoWebVTT(assURL: fileURL)
        case nil:
            throw FFmpegError.unsupportedFormat
        }
    }
    
    /// Converts ASS/SSA subtitle to WebVTT using pure Swift parsing.
    /// ASS format is text-based, so we can parse it directly without FFmpeg.
    private func convertASStoWebVTT(assURL: URL) throws -> URL {
        let vttFilename = assURL.deletingPathExtension().lastPathComponent + ".vtt"
        let vttPath = outputDirectory.appendingPathComponent(vttFilename)
        
        if FileManager.default.fileExists(atPath: vttPath.path) {
            return vttPath
        }
        
        let assContent = try String(contentsOf: assURL, encoding: .utf8)
        let vttContent = Self.assToWebVTT(assContent)
        try vttContent.write(to: vttPath, atomically: true, encoding: .utf8)
        
        // Inject X-TIMESTAMP-MAP for HLS compatibility
        try? Self.injectTimestampMap(at: vttPath)
        
        print("   Converted ASS/SSA to WebVTT: \(vttPath.lastPathComponent)")
        return vttPath
    }
    
    /// Pure function: converts ASS/SSA text to WebVTT text.
    /// Parses the [Events] section and extracts Dialogue lines.
    ///
    /// ASS Dialogue format:
    /// `Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text`
    /// Timestamps: `H:MM:SS.CC` (centiseconds)
    static func assToWebVTT(_ ass: String) -> String {
        let normalized = ass
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        
        var result = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"
        
        let lines = normalized.components(separatedBy: "\n")
        
        // Find the Format line in [Events] section to determine field order
        var formatFields: [String] = []
        var inEventsSection = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.lowercased().hasPrefix("[events]") {
                inEventsSection = true
                continue
            }
            if trimmed.hasPrefix("[") && !trimmed.lowercased().hasPrefix("[events]") {
                if inEventsSection { break }
                continue
            }
            
            if inEventsSection && trimmed.lowercased().hasPrefix("format:") {
                let fieldsStr = String(trimmed.dropFirst("format:".count))
                formatFields = fieldsStr.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
                continue
            }
            
            if inEventsSection && trimmed.lowercased().hasPrefix("dialogue:") {
                let dialogueStr = String(trimmed.dropFirst("dialogue:".count)).trimmingCharacters(in: .whitespaces)
                
                // Split by comma, but Text field (last) may contain commas
                // Standard format has 10 fields: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
                let fieldCount = max(formatFields.count, 10)
                let parts = dialogueStr.split(separator: ",", maxSplits: fieldCount - 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                
                guard parts.count >= fieldCount else { continue }
                
                // Find Start, End, Text indices from Format line
                let startIdx = formatFields.isEmpty ? 1 : (formatFields.firstIndex(of: "start") ?? 1)
                let endIdx = formatFields.isEmpty ? 2 : (formatFields.firstIndex(of: "end") ?? 2)
                let textIdx = formatFields.isEmpty ? 9 : (formatFields.firstIndex(of: "text") ?? (fieldCount - 1))
                
                guard startIdx < parts.count, endIdx < parts.count, textIdx < parts.count else { continue }
                
                let startTimestamp = Self.convertASSTimestamp(parts[startIdx])
                let endTimestamp = Self.convertASSTimestamp(parts[endIdx])
                
                guard let startTS = startTimestamp, let endTS = endTimestamp else { continue }
                
                // Clean ASS text: remove override tags like {\an8}, {\i1}, {\b1}, etc.
                var text = parts[textIdx]
                // Remove override blocks: {\\...}
                text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
                // Replace \N (ASS newline) with actual newline
                text = text.replacingOccurrences(of: "\\N", with: "\n")
                text = text.replacingOccurrences(of: "\\n", with: "\n")
                // Trim
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard !text.isEmpty else { continue }
                
                result += "\(startTS) --> \(endTS)\n"
                result += "\(text)\n"
                result += "\n"
            }
        }
        
        return result
    }
    
    /// Converts an ASS timestamp (H:MM:SS.CC) to WebVTT format (HH:MM:SS.mmm)
    private static func convertASSTimestamp(_ ass: String) -> String? {
        // ASS format: H:MM:SS.CC (centiseconds, single digit hour)
        let parts = ass.components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        
        guard let hours = Int(parts[0]) else { return nil }
        guard let minutes = Int(parts[1]) else { return nil }
        
        let secParts = parts[2].components(separatedBy: ".")
        guard secParts.count == 2,
              let seconds = Int(secParts[0]),
              let centiseconds = Int(secParts[1]) else { return nil }
        
        // Convert centiseconds to milliseconds
        let milliseconds = centiseconds * 10
        
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }
    
    // MARK: - HLS WebVTT Timestamp Map
    
    /// Injects `X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000` into a WebVTT file
    /// if it doesn't already have one.
    static func injectTimestampMap(at vttURL: URL) throws {
        var content = try String(contentsOf: vttURL, encoding: .utf8)
        
        // Already has it — nothing to do
        if content.contains("X-TIMESTAMP-MAP") {
            return
        }
        
        // Insert after "WEBVTT" header line
        if content.hasPrefix("WEBVTT") {
            if let newlineIndex = content.firstIndex(of: "\n") {
                let insertPosition = content.index(after: newlineIndex)
                content.insert(contentsOf: "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n", at: insertPosition)
            }
        }
        
        try content.write(to: vttURL, atomically: true, encoding: .utf8)
    }
    
    /// Cleans up temporary files
    func cleanup() {
        sourceIsHEVC = false
        try? FileManager.default.removeItem(at: outputDirectory)
    }
}
