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
    
    var durationInSeconds: Double {
        duration.seconds
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
    }
}
