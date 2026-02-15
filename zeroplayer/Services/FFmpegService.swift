import Foundation
import AVFoundation
import Libmpv
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

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
    
    /// Serial queue for encoding — only one mpv encode instance runs at a time
    /// to avoid resource exhaustion (each instance does software decode + HW encode).
    private let encodeQueue = DispatchQueue(label: "com.zeroplayer.encode", qos: .userInitiated)
    
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
            isHEVC: isHEVC
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
        let segExt = videoInfo.segmentExtension  // "mp4" for HEVC, "ts" for H.264
        
        var variant = "#EXTM3U\n"
        if videoInfo.isHEVC {
            // HEVC in HLS requires fMP4 segments with version 7+
            variant += "#EXT-X-VERSION:7\n"
        } else {
            variant += "#EXT-X-VERSION:3\n"
        }
        variant += "#EXT-X-TARGETDURATION:11\n"
        variant += "#EXT-X-MEDIA-SEQUENCE:0\n"
        variant += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        
        if videoInfo.isHEVC {
            // fMP4 requires an initialization segment (moov atom)
            variant += "#EXT-X-MAP:URI=\"init.mp4\"\n"
        }
        
        for i in 0..<totalSegments {
            let duration = min(segmentDuration, videoInfo.durationInSeconds - Double(i) * segmentDuration)
            variant += "#EXTINF:\(String(format: "%.3f", duration)),\n"
            variant += "segment_\(String(format: "%03d", i)).\(segExt)\n"
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
        if videoInfo.isHEVC {
            master += "#EXT-X-VERSION:7\n"
        } else {
            master += "#EXT-X-VERSION:3\n"
        }
        
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
        let bandwidth = 4_000_000  // Approximate bitrate matching our -b:v 4000k
        let width = Int(videoInfo.size.width)
        let height = Int(videoInfo.size.height)
        
        // CODECS attribute: required for HEVC so AirPlay receivers know the codec.
        // hvc1.2.4.L153.B0 = HEVC Main 10 Profile, Level 5.1 (conservative, widely compatible)
        // mp4a.40.2 = AAC-LC
        let codecsAttr: String
        if videoInfo.isHEVC {
            codecsAttr = ",CODECS=\"hvc1.2.4.L153.B0,mp4a.40.2\""
        } else {
            codecsAttr = ""
        }
        
        if hasSubtitles {
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(width)x\(height)\(codecsAttr),SUBTITLES=\"subs\"\n"
        } else {
            master += "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),RESOLUTION=\(width)x\(height)\(codecsAttr)\n"
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
    ///    MPEG-TS (H.264) or fMP4 (HEVC) without re-encoding.
    /// 2. For other sources: fall back to mpv encode mode.
    ///
    /// Handles concurrent requests for the same segment by queuing waiters.
    func generateSegment(from sourceURL: URL, segmentIndex: Int, segmentDuration: Double = 10.0) async throws -> URL {
        let ext = sourceIsHEVC ? "mp4" : "ts"
        let segmentPath = outputDirectory.appendingPathComponent("segment_\(String(format: "%03d", segmentIndex)).\(ext)")
        
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
                print("Segment \(segmentIndex) remuxed via FFmpeg (no re-encode)")
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
        }
        
        // Rewrite the file starting from the moof atom
        let trimmedData = data.subdata(in: start..<count)
        try trimmedData.write(to: URL(fileURLWithPath: path))
        print("stripFtypMoov: stripped \(start) bytes (ftyp+moov) from segment, \(count) -> \(trimmedData.count) bytes")
    }
    
    /// Converts an FFmpeg error code to a human-readable string.
    private static func ffmpegErrorString(_ errnum: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        av_strerror(errnum, &buf, 256)
        return String(cString: buf)
    }
    
    /// Remuxes a time range from the source video into an MPEG-TS segment
    /// using the FFmpeg C API (Libavformat). No re-encoding — the H.264 and AAC
    /// bitstreams are copied directly into a proper MPEG-TS container.
    ///
    /// This produces real `.ts` segments that AirPlay receivers expect,
    /// unlike fMP4 segments which cause init/media segment mismatch errors.
    ///
    /// Runs on `encodeQueue` to serialize FFmpeg operations.
    private func remuxSegmentWithFFmpeg(
        from sourceURL: URL,
        to outputURL: URL,
        startTime: Double,
        duration: Double
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            self.encodeQueue.async {
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
    /// For video: always copies (remuxes) — no re-encoding.
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
        
        // --- Allocate output (MPEG-TS or fMP4 depending on video codec) ---
        // Detect HEVC to decide output format
        var isHEVCSource = false
        let nbInputStreams = Int(inputCtx!.pointee.nb_streams)
        for i in 0..<nbInputStreams {
            let stream = inputCtx!.pointee.streams[i]!
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                isHEVCSource = stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
                break
            }
        }
        
        let outputFormat = isHEVCSource ? "mp4" : "mpegts"
        
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
        var audioNextPts: Int64 = 0  // Running PTS counter for AAC encoder output
        
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
                
            } else if codecType == AVMEDIA_TYPE_AUDIO {
                // For HEVC (fMP4), ALL audio must be transcoded to AAC to match
                // the init segment. EAC3/AC3 can't be directly copied into fMP4
                // with empty_moov movflags (FFmpeg can't build AudioSpecificConfig
                // without parsing packets first, which isn't possible in init-only mode).
                let canCopyAudio = !isHEVCSource && tsCompatibleAudio.contains(codecId)
                
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
        // For HEVC (fMP4), set movflags for fragmented MP4 output.
        // Must match the init segment's movflags exactly.
        var muxOpts: OpaquePointer?  // AVDictionary*
        if isHEVCSource {
            av_dict_set(&muxOpts, "movflags", "empty_moov+frag_keyframe+default_base_moof", 0)
        }
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
        
        var wroteAnyPacket = false
        
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
            
            // Skip packets before our start time (seek may land before the target)
            if ptsSeconds < startTime - 1.0 {
                av_packet_unref(pkt)
                continue
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
            
            // --- Passthrough (copy) for compatible streams ---
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
        
        // Flush encoder (drain remaining buffered frames)
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
        
        // --- Finalize ---
        ret = av_write_trailer(outputCtxUnwrapped)
        if ret < 0 {
            print("Warning: av_write_trailer failed: \(Self.ffmpegErrorString(ret))")
        }
        
        // Close output file
        if (oformat.pointee.flags & AVFMT_NOFILE) == 0 {
            avio_closep(&outputCtxUnwrapped.pointee.pb)
        }
        
        // For HEVC fMP4 media segments: strip the leading ftyp+moov atoms.
        // FFmpeg's empty_moov movflag writes ftyp+moov at the start of every output,
        // but HLS fMP4 media segments must contain only moof+mdat (the init segment
        // provides ftyp+moov via EXT-X-MAP). AirPlay receivers reject segments that
        // duplicate the moov atom.
        //
        // KEY FIX: If init.mp4 doesn't exist yet, extract the ftyp+moov prefix from
        // this segment and save it as the init segment. This guarantees the init
        // segment's track IDs, codec params, and AAC extradata are identical to those
        // in the media segments — they literally come from the same AVFormatContext.
        // Previously, init.mp4 was generated by a separate AVFormatContext which
        // could produce different track IDs and AAC AudioSpecificConfig, causing
        // AirPlay receivers to reject the stream with error -15562.
        if isHEVCSource {
            let initPath = outputDirectory.appendingPathComponent("init.mp4").path
            let needsInitSegment = !FileManager.default.fileExists(atPath: initPath)
            try Self.stripFtypMoovFromSegment(
                at: outputPath,
                saveInitSegmentTo: needsInitSegment ? initPath : nil
            )
        }
        
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
            // Use serial encodeQueue — only one encode at a time
            self.encodeQueue.async {
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
