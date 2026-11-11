import Foundation
import GiovChatCore

/// Marks underlined text (`<u>…</u>` and links); Foundation has no underline intent, so the SwiftUI layer turns it
/// into an underline style.
enum GiovUnderlineAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "app.giovchat.underline"
}

#if !canImport(Darwin)
/// Foundation on Linux has no `InlinePresentationIntent`. This stand-in has Apple's raw values and attribute name,
/// so the markdown conversion compiles and is tested on every platform; on Apple platforms Foundation's own type is
/// used and SwiftUI renders it.
struct InlinePresentationIntent: OptionSet, Hashable, Sendable {
    let rawValue: UInt

    static let emphasized = InlinePresentationIntent(rawValue: 1 << 0)
    static let stronglyEmphasized = InlinePresentationIntent(rawValue: 1 << 1)
    static let code = InlinePresentationIntent(rawValue: 1 << 2)
    static let strikethrough = InlinePresentationIntent(rawValue: 1 << 5)
}

enum GiovInlinePresentationIntentAttribute: AttributedStringKey {
    typealias Value = InlinePresentationIntent
    static let name = "NSInlinePresentationIntent"
}

extension AttributedString {
    var inlinePresentationIntent: InlinePresentationIntent? {
        get { self[GiovInlinePresentationIntentAttribute.self] }
        set { self[GiovInlinePresentationIntentAttribute.self] = newValue }
    }
}

extension AttributedString.Runs.Run {
    var inlinePresentationIntent: InlinePresentationIntent? {
        self[GiovInlinePresentationIntentAttribute.self]
    }
}
#endif

/// Inline markdown runs as an `AttributedString`: bold, italic, code and strike as `inlinePresentationIntent`,
/// underline as ``GiovUnderlineAttribute``, and `link` only for http(s) and mailto hrefs, whatever the text claims.
/// Lines are joined with a line break.
///
/// - Parameter decorate: adds framework-specific attributes to one piece (the SwiftUI layer sets the code
///   background and the underline style); `isLink` is true for a tappable link.
func giovInlineAttributedString(
    _ lines: [[GiovInlineRun]],
    decorate: (inout AttributedString, GiovMarks, _ isLink: Bool) -> Void = { _, _, _ in }
) -> AttributedString {
    var result = AttributedString()
    for (index, line) in lines.enumerated() {
        if index > 0 { result.append(AttributedString("\n")) }
        for run in line {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.marks.bold { intent.insert(.stronglyEmphasized) }
            if run.marks.italic { intent.insert(.emphasized) }
            if run.marks.code { intent.insert(.code) }
            if run.marks.strike { intent.insert(.strikethrough) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            var isLink = false
            if let href = run.href, GiovChatMarkdown.isOpenableHref(href), let url = URL(string: href) {
                piece.link = url
                isLink = true
            }
            if run.marks.underline || isLink { piece[GiovUnderlineAttribute.self] = true }
            decorate(&piece, run.marks, isLink)
            result.append(piece)
        }
    }
    return result
}

/// The marker before a list item: "3." or a bullet.
func giovListMarker(_ list: GiovMarkdownList, index: Int) -> String {
    list.ordered ? "\(list.start + index)." : "•"
}
