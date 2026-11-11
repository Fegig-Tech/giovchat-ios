import Foundation

/// A compiled regular expression that can live in a global constant (NSRegularExpression is immutable and safe to
/// share). Matching works on UTF-16 offsets, the same units JavaScript's regular expressions use.
struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        // The patterns are constants of this module; a bad one is a programming error.
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// True when the pattern matches somewhere in `text`.
    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// The capture groups of the first match (index 0 is the whole match); nil groups did not take part.
    func firstMatch(_ text: String) -> [String?]? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
    }

    /// Replaces every non-overlapping match, left to right, with what `transform` returns for its groups (nil
    /// groups are empty strings).
    func replace(_ text: String, _ transform: ([String]) -> String) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        var out = ""
        var cursor = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            out += transform(groups)
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
