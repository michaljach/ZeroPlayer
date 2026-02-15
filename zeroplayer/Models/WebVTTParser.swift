import Foundation

/// Parses WebVTT subtitle files into timed cue entries
struct WebVTTParser {
    
    struct Cue: Identifiable {
        let id: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
    }
    
    /// Parses a WebVTT string into an array of cues
    static func parse(_ content: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = content.components(separatedBy: "\n\n")
        var cueIndex = 0
        
        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            
            // Skip the WEBVTT header and NOTE blocks
            if lines.first?.hasPrefix("WEBVTT") == true { continue }
            if lines.first?.hasPrefix("NOTE") == true { continue }
            if lines.isEmpty { continue }
            
            // Find the timestamp line (contains " --> ")
            var timestampLineIndex: Int?
            for (i, line) in lines.enumerated() {
                if line.contains(" --> ") {
                    timestampLineIndex = i
                    break
                }
            }
            
            guard let tsIndex = timestampLineIndex else { continue }
            
            let timestampLine = lines[tsIndex]
            let parts = timestampLine.components(separatedBy: " --> ")
            guard parts.count >= 2 else { continue }
            
            guard let startTime = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                  let endTime = parseTimestamp(parts[1].components(separatedBy: " ").first?.trimmingCharacters(in: .whitespaces) ?? parts[1]) else {
                continue
            }
            
            // Collect text lines after the timestamp
            let textLines = lines.dropFirst(tsIndex + 1)
            let text = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !text.isEmpty else { continue }
            
            // Strip basic HTML tags (<b>, <i>, <u>, etc.) for plain text rendering
            let cleanText = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            
            let cueId = tsIndex > 0 ? lines[tsIndex - 1] : "\(cueIndex)"
            cues.append(Cue(id: "cue_\(cueIndex)_\(cueId)", startTime: startTime, endTime: endTime, text: cleanText))
            cueIndex += 1
        }
        
        return cues
    }
    
    /// Parses a WebVTT timestamp string to seconds
    /// Supports both HH:MM:SS.mmm and MM:SS.mmm formats
    static func parseTimestamp(_ timestamp: String) -> TimeInterval? {
        let parts = timestamp.components(separatedBy: ":")
        
        switch parts.count {
        case 3:
            // HH:MM:SS.mmm
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        case 2:
            // MM:SS.mmm
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        default:
            return nil
        }
    }
    
    /// Loads and parses a WebVTT file from a URL (local file or HTTP)
    static func load(from url: URL) async throws -> [Cue] {
        let data: Data
        
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (downloaded, _) = try await URLSession.shared.data(from: url)
            data = downloaded
        }
        
        guard let content = String(data: data, encoding: .utf8) else {
            return []
        }
        
        return parse(content)
    }
    
    /// Returns the active cue for a given playback time
    static func activeCue(at time: TimeInterval, in cues: [Cue]) -> Cue? {
        // Binary search could be used for large files, but linear is fine for typical subtitle counts
        return cues.first { time >= $0.startTime && time < $0.endTime }
    }
}
