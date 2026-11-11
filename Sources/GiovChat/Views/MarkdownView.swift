#if canImport(SwiftUI) && canImport(ImageIO)
import GiovChatCore
import SwiftUI

/// Inline runs as SwiftUI text: Foundation's intents plus a code background and underlines.
@MainActor
func giovStyledText(_ lines: [[GiovInlineRun]], colors: GiovBubbleColors) -> AttributedString {
    giovInlineAttributedString(lines) { piece, marks, isLink in
        if marks.code { piece.backgroundColor = colors.code }
        if marks.underline || isLink { piece.underlineStyle = Text.LineStyle(pattern: .solid, color: colors.text) }
        if isLink { piece.foregroundColor = colors.text }
    }
}

/// A chat message's markdown drawn as native text. Links open through the environment's `openURL`.
@MainActor
struct GiovMarkdownView: View {
    let content: String
    let colors: GiovBubbleColors

    var body: some View {
        let blocks = GiovChatMarkdown.parse(content)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                GiovMarkdownBlockView(block: block, colors: colors)
            }
        }
        .font(.subheadline)
        .foregroundColor(colors.text)
        .tint(colors.text)
    }
}

@MainActor
struct GiovMarkdownBlockView: View {
    let block: GiovMarkdownBlock
    let colors: GiovBubbleColors

    var body: some View {
        switch block {
        case .paragraph(let lines):
            paragraph(lines)
        case .heading(let content):
            paragraph([content])
                .fontWeight(.bold)
                .accessibilityAddTraits(.isHeader)
        case .quote(let lines):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(colors.accent)
                    .frame(width: 3)
                paragraph(lines)
            }
            .fixedSize(horizontal: false, vertical: true)
            .opacity(0.85)
        case .code(let text):
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(colors.code))
        case .rule:
            Rectangle()
                .fill(colors.accent)
                .frame(height: 1)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        case .list(let list):
            GiovMarkdownListView(list: list, colors: colors)
        }
    }

    private func paragraph(_ lines: [[GiovInlineRun]]) -> Text {
        Text(giovStyledText(lines, colors: colors))
    }
}

@MainActor
struct GiovMarkdownListView: View {
    let list: GiovMarkdownList
    let colors: GiovBubbleColors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(giovListMarker(list, index: index))
                        .frame(minWidth: 18, alignment: .leading)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(giovStyledText(item.lines, colors: colors))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            AnyView(GiovMarkdownListView(list: child, colors: colors))
                        }
                    }
                }
            }
        }
    }
}
#endif
