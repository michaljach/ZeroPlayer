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
    /// HEVC codec string parsed from HEVCDecoderConfigurationRecord (e.g. "hvc1.2.4.L153.B0").
    /// Used in HLS master playlist CODECS attribute. Nil for non-HEVC content.
    let hevcCodecString: String?
    
    var durationInSeconds: Double {
        duration.seconds
    }
    
    /// File extension for HLS segments: always `.ts` (MPEG-TS for both H.264 and HEVC)
    var segmentExtension: String {
        "ts"
    }
    
    /// FFmpeg muxer format name: always `mpegts`
    var segmentMuxerFormat: String {
        "mpegts"
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
        && lhs.hevcCodecString == rhs.hevcCodecString
    }
}
