import Foundation

struct InternetSubtitleOption: Equatable, Identifiable, Sendable {
    let id: String
    let downloadURL: URL
    let languageCode: String
    let languageName: String
    let format: String
    let source: String
    let release: String?
    let fileName: String?
    let isHearingImpaired: Bool

    var primaryText: String {
        let code = languageCode.uppercased()
        if languageName.caseInsensitiveCompare(code) == .orderedSame {
            return "\(code) (\(format.uppercased()))"
        }
        return "\(languageName) (\(code)) • \(format.uppercased())"
    }

    var secondaryText: String {
        release ?? fileName ?? source
    }
}
