import Foundation
import AVFoundation

/// Information about a video file, probed by FFmpegService
struct VideoInfo: Equatable {
    let duration: CMTime
    let size: CGSize
    let hasVideo: Bool
    let hasAudio: Bool
    let videoCodec: String?
    let audioCodec: String?
    let needsConversion: Bool
    let needsAudioConversion: Bool
    /// True if the video codec is HEVC (H.265). Apple's HLS requires HEVC to use
    /// fMP4 segments instead of MPEG-TS.
    let isHEVC: Bool
    
    var durationInSeconds: Double {
        duration.seconds
    }
    
    /// File extension for HLS segments: `.mp4` for HEVC (fMP4), `.ts` for H.264 (MPEG-TS)
    var segmentExtension: String {
        isHEVC ? "mp4" : "ts"
    }
    
    /// FFmpeg muxer format name
    var segmentMuxerFormat: String {
        isHEVC ? "mp4" : "mpegts"
    }
    
    static func == (lhs: VideoInfo, rhs: VideoInfo) -> Bool {
        lhs.duration == rhs.duration
        && lhs.size == rhs.size
        && lhs.hasVideo == rhs.hasVideo
        && lhs.hasAudio == rhs.hasAudio
        && lhs.videoCodec == rhs.videoCodec
        && lhs.audioCodec == rhs.audioCodec
        && lhs.needsConversion == rhs.needsConversion
        && lhs.needsAudioConversion == rhs.needsAudioConversion
        && lhs.isHEVC == rhs.isHEVC
    }
}
