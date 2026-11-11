import Foundation

/// Inline formatting of a run of text.
public struct GiovMarks: Sendable, Equatable, Hashable {
    public var bold: Bool
    public var italic: Bool
    public var strike: Bool
    public var underline: Bool
    public var code: Bool

    public init(bold: Bool = false, italic: Bool = false, strike: Bool = false, underline: Bool = false, code: Bool = false) {
        self.bold = bold
        self.italic = italic
        self.strike = strike
        self.underline = underline
        self.code = code
    }
}

/// A piece of text with one set of marks and, for links, an href.
public struct GiovInlineRun: Sendable, Equatable {
    public var text: String
    public var marks: GiovMarks
    /// The link target; check it with ``GiovChatMarkdown/isOpenableHref(_:)`` before opening it.
    public var href: String?

    public init(text: String, marks: GiovMarks = GiovMarks(), href: String? = nil) {
        self.text = text
        self.marks = marks
        self.href = href
    }
}

/// A bulleted (`ordered == false`) or numbered list, starting at ``start``.
public struct GiovMarkdownList: Sendable, Equatable {
    public var ordered: Bool
    public var start: Int
    public var items: [GiovMarkdownListItem]
}

/// One list item: its lines and at most one level of nested lists.
public struct GiovMarkdownListItem: Sendable, Equatable {
    public var lines: [[GiovInlineRun]]
    public var children: [GiovMarkdownList]
}

/// A block of chat markdown. A line is `[GiovInlineRun]`.
public enum GiovMarkdownBlock: Sendable, Equatable {
    case paragraph(lines: [[GiovInlineRun]])
    case heading(content: [GiovInlineRun])
    case quote(lines: [[GiovInlineRun]])
    case code(text: String)
    case rule
    case list(GiovMarkdownList)
}

/// Chat markdown, the grammar of the web widget's formatMessage (docs/protocol/README.md, "Markdown"), parsed into a
/// renderer-neutral tree. Paragraphs and line breaks, **bold**, *italic* or _italic_, ~~strike~~, <u>underline</u>,
/// `code`, fenced code, # headings, - / * / + and 1. lists (one nested level), > quotes, --- rules,
/// [links](https://…) and bare links. Only http(s) and mailto links get an href. Unfinished markup (while a reply
/// streams in) stays text until it is closed. All other text is literal. docs/protocol/conformance/
/// markdown-vectors.json is the contract.
public enum GiovChatMarkdown {
    // JavaScript's \s, spelled out (ICU's \s differs), so lines split the same way as the widget.
    private static let ws = "\\t\\n\\u000B\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff"
    private static let s = "[\(ws)]"
    private static let ns = "[^\(ws)]"
    // JavaScript's \w is ASCII only.
    private static let w = "A-Za-z0-9_"

    // Placeholders and mark delimiters are control characters that never survive in chat text, and none is a word
    // character, so the italic rules see the same neighbours as in the widget's HTML.
    private static let codeMark: Unicode.Scalar = "\u{00}"
    private static let linkMark: Unicode.Scalar = "\u{01}"
    private static let boldOpen: Unicode.Scalar = "\u{10}"
    private static let boldClose: Unicode.Scalar = "\u{11}"
    private static let italicOpen: Unicode.Scalar = "\u{12}"
    private static let italicClose: Unicode.Scalar = "\u{13}"
    private static let strikeOpen: Unicode.Scalar = "\u{14}"
    private static let strikeClose: Unicode.Scalar = "\u{15}"
    private static let underlineOpen: Unicode.Scalar = "\u{16}"
    private static let underlineClose: Unicode.Scalar = "\u{17}"

    private static let reserved = Pattern("[\\u0000\\u0001\\u0010-\\u0017]")
    private static let codeSpan = Pattern("`([^`\\n]+)`")
    private static let markdownLink = Pattern("\\[([^\\]\\n]+)\\]\\(((?:https?://|mailto:)[^\(ws))]+)\\)", caseInsensitive: true)
    private static let bareLink = Pattern("(^|[\(ws)(])((?:https?://)[^\(ws)<]+[^\(ws)<.,;:!?)'\"&])", caseInsensitive: true)
    private static let boldStars = Pattern("\\*\\*(?=\(ns))([^*]+?\(ns))\\*\\*")
    private static let boldUnderscores = Pattern("__(?=\(ns))([^_]+?\(ns))__")
    private static let italicStar = Pattern("(^|[^*\(w)])\\*(?=\(ns))([^*\\n]+?\(ns))\\*(?![*\(w)])")
    private static let italicUnderscore = Pattern("(^|[^_\(w)])_(?=\(ns))([^_\\n]+?\(ns))_(?![_\(w)])")
    private static let strikePattern = Pattern("~~(?=\(ns))([^~]+?\(ns))~~")
    private static let underlinePattern = Pattern("<u>([\\s\\S]+?)</u>", caseInsensitive: true)

    private static let fence = Pattern("^\(s)*```")
    private static let listStart = Pattern("^\(s)*(?:[-*+]|[0-9]+[.)])\(s)+")
    private static let headingPattern = Pattern("^(#{1,6})\(s)+(.*)$")
    private static let rulePattern = Pattern("^\(s)*(?:-{3,}|\\*{3,}|_{3,})\(s)*$")
    private static let quotePattern = Pattern("^>\(s)?(.*)$")
    private static let itemPattern = Pattern("^(\(s)*)([-*+]|[0-9]+[.)])\(s)+(.*)$")
    private static let continuation = Pattern("^\(s)+\(ns)")
    private static let openable = Pattern("^(?:https?://|mailto:)", caseInsensitive: true)

    /// Links are opened only for these schemes, whatever the text claims.
    public static func isOpenableHref(_ href: String?) -> Bool {
        guard let href else { return false }
        return openable.matches(href)
    }

    private static func mark(_ open: Unicode.Scalar, _ text: String, _ close: Unicode.Scalar) -> String {
        String(Character(open)) + text + String(Character(close))
    }

    /// Inline markup on one line, in the widget's order: code spans and links are cut out first.
    public static func parseInline(_ text: String) -> [GiovInlineRun] {
        var codes: [String] = []
        var out = reserved.replace(text) { _ in "" }
        out = codeSpan.replace(out) { groups in
            codes.append(groups[1])
            return mark(codeMark, String(codes.count - 1), codeMark)
        }
        var links: [(label: String, href: String)] = []
        func keep(_ label: String, _ href: String) -> String {
            links.append((label, href))
            return mark(linkMark, String(links.count - 1), linkMark)
        }
        out = markdownLink.replace(out) { keep($0[1], $0[2]) }
        out = bareLink.replace(out) { $0[1] + keep($0[2], $0[2]) }
        out = boldStars.replace(out) { mark(boldOpen, $0[1], boldClose) }
        out = boldUnderscores.replace(out) { mark(boldOpen, $0[1], boldClose) }
        out = italicStar.replace(out) { $0[1] + mark(italicOpen, $0[2], italicClose) }
        out = italicUnderscore.replace(out) { $0[1] + mark(italicOpen, $0[2], italicClose) }
        out = strikePattern.replace(out) { mark(strikeOpen, $0[1], strikeClose) }
        out = underlinePattern.replace(out) { mark(underlineOpen, $0[1], underlineClose) }

        var runs: [GiovInlineRun] = []
        var bold = 0, italic = 0, strike = 0, underline = 0
        func current() -> GiovMarks { GiovMarks(bold: bold > 0, italic: italic > 0, strike: strike > 0, underline: underline > 0) }
        func push(_ run: GiovInlineRun) {
            guard !run.text.isEmpty else { return }
            if let last = runs.last, last.href == nil, run.href == nil, last.marks == run.marks {
                runs[runs.count - 1].text += run.text
            } else {
                runs.append(run)
            }
        }
        var buffer = String.UnicodeScalarView()
        func flush() {
            push(GiovInlineRun(text: String(buffer), marks: current()))
            buffer.removeAll()
        }
        let scalars = Array(out.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case boldOpen: flush(); bold += 1
            case boldClose: flush(); bold -= 1
            case italicOpen: flush(); italic += 1
            case italicClose: flush(); italic -= 1
            case strikeOpen: flush(); strike += 1
            case strikeClose: flush(); strike -= 1
            case underlineOpen: flush(); underline += 1
            case underlineClose: flush(); underline -= 1
            case codeMark, linkMark:
                var end = index + 1
                while end < scalars.count, scalars[end] != scalar { end += 1 }
                var digits = String.UnicodeScalarView()
                digits.append(contentsOf: scalars[(index + 1)..<min(end, scalars.count)])
                let slot = Int(String(digits)) ?? 0
                flush()
                if scalar == codeMark {
                    var marks = current()
                    marks.code = true
                    push(GiovInlineRun(text: codes[slot], marks: marks))
                } else {
                    push(GiovInlineRun(text: links[slot].label, marks: current(), href: links[slot].href))
                }
                index = end
            default:
                buffer.append(scalar)
            }
            index += 1
        }
        flush()
        return runs
    }

    private final class OpenList {
        let ordered: Bool
        let start: Int
        let indent: Int
        var items: [OpenItem] = []

        init(ordered: Bool, start: Int, indent: Int) {
            self.ordered = ordered
            self.start = start
            self.indent = indent
        }

        func build() -> GiovMarkdownList {
            GiovMarkdownList(ordered: ordered, start: start, items: items.map { $0.build() })
        }
    }

    private final class OpenItem {
        var lines: [[GiovInlineRun]]
        var children: [OpenList] = []

        init(_ firstLine: [GiovInlineRun]) {
            lines = [firstLine]
        }

        func build() -> GiovMarkdownListItem {
            GiovMarkdownListItem(lines: lines, children: children.map { $0.build() })
        }
    }

    private enum Pending {
        case block(GiovMarkdownBlock)
        case list(OpenList)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses one message into blocks; an empty or blank message has none.
    public static func parse(_ content: String?) -> [GiovMarkdownBlock] {
        guard let content, !content.isEmpty else { return [] }
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        // Blocks in order; a top-level list stays open (and mutable) until the document is built.
        var blocks: [Pending] = []
        var paragraph: [String] = []
        var quote: [String] = []
        // Open lists, outermost first; one nested level, as in the widget.
        var lists: [OpenList] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.block(.paragraph(lines: paragraph.map(parseInline)))) }
            paragraph = []
        }
        func closeLists(_ toIndent: Int = -1) {
            while let last = lists.last, last.indent > toIndent { lists.removeLast() }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.block(.quote(lines: quote.map(parseInline)))) }
            quote = []
        }
        func flushAll() {
            flushParagraph()
            closeLists()
            flushQuote()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            // Fenced code: everything up to the closing fence (or the end, while streaming) is literal.
            if fence.matches(line) {
                flushAll()
                var body: [String] = []
                index += 1
                while index < lines.count, !fence.matches(lines[index]) {
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.block(.code(text: body.joined(separator: "\n"))))
                index += 1
                continue
            }
            if trimmed(line).isEmpty {
                flushParagraph()
                flushQuote()
                // A blank line between list items keeps the list going.
                let next = index + 1 < lines.count ? lines[index + 1] : ""
                if !lists.isEmpty && !listStart.matches(next) { closeLists() }
                index += 1
                continue
            }
            if let heading = headingPattern.firstMatch(line) {
                flushAll()
                blocks.append(.block(.heading(content: parseInline(heading[2] ?? ""))))
                index += 1
                continue
            }
            if rulePattern.matches(line) {
                flushAll()
                blocks.append(.block(.rule))
                index += 1
                continue
            }
            if let quoted = quotePattern.firstMatch(line) {
                flushParagraph()
                closeLists()
                quote.append(quoted[1] ?? "")
                index += 1
                continue
            }
            flushQuote()
            if let item = itemPattern.firstMatch(line) {
                flushParagraph()
                let indent = ((item[1] ?? "").replacingOccurrences(of: "\t", with: "  ") as NSString).length
                let marker = item[2] ?? ""
                let ordered = marker.contains { $0.isASCII && $0.isNumber }
                let entry = OpenItem(parseInline(item[3] ?? ""))
                closeLists(indent)
                let top = lists.last
                if let top, top.indent == indent, top.ordered == ordered {
                    top.items.append(entry)
                } else {
                    if let top, top.indent == indent { closeLists(indent - 1) }
                    let parent = lists.last
                    // Only one nested level: deeper indentation joins the nested list.
                    let nested = parent.map { indent > $0.indent } ?? false
                    if lists.count >= 2, nested, let parent {
                        parent.items.append(entry)
                        index += 1
                        continue
                    }
                    var start = 1
                    if ordered, let number = Int(String(marker.prefix { $0.isASCII && $0.isNumber })), number != 0 { start = number }
                    let list = OpenList(ordered: ordered, start: start, indent: indent)
                    list.items.append(entry)
                    if nested, let parent, let last = parent.items.last {
                        last.children.append(list)
                    } else {
                        blocks.append(.list(list))
                    }
                    lists.append(list)
                }
                index += 1
                continue
            }
            // A line indented under a list item continues that item.
            if let last = lists.last, continuation.matches(line), let item = last.items.last {
                item.lines.append(parseInline(trimmed(line)))
                index += 1
                continue
            }
            closeLists()
            paragraph.append(line)
            index += 1
        }
        flushAll()
        return blocks.map { pending in
            switch pending {
            case .block(let block): return block
            case .list(let list): return .list(list.build())
            }
        }
    }
}
