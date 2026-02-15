import Foundation

/// Represents a subtitle track, either embedded in the video or loaded from an external file
struct SubtitleTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let language: String?
    let source: Source
    
    /// Where the subtitle track came from
    enum Source: Hashable {
        /// Embedded in the video file, at the given stream index
        case embedded(streamIndex: Int)
        /// Loaded from an external file
        case external(fileURL: URL)
    }
    
    /// Display name for the UI
    var displayName: String {
        if let language = language, !language.isEmpty {
            return "\(title) (\(language))"
        }
        return title
    }
}

/// Supported subtitle file formats
enum SubtitleFormat: String, CaseIterable {
    case srt
    case vtt
    case ass
    case ssa
    
    /// File extensions for this format
    var fileExtension: String { rawValue }
    
    /// Detect format from a file URL
    static func from(url: URL) -> SubtitleFormat? {
        let ext = url.pathExtension.lowercased()
        return SubtitleFormat(rawValue: ext)
    }
}
