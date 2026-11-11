#if canImport(SwiftUI) && canImport(ImageIO)
import GiovChatCore
import SwiftUI

/// A bubble: 16 pt corners with a 4 pt "tail" corner on the sender's side.
struct GiovBubbleShape: Shape {
    var tailOnLeading: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = min(16, rect.width / 2, rect.height / 2)
        let small: CGFloat = min(4, big)
        let topLeading = big
        let topTrailing = big
        let bottomTrailing = tailOnLeading ? big : small
        let bottomLeading = tailOnLeading ? small : big
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeading, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topTrailing, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + topTrailing),
            radius: topTrailing
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomTrailing))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - bottomTrailing, y: rect.maxY),
            radius: bottomTrailing
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomLeading),
            radius: bottomLeading
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeading))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + topLeading, y: rect.minY),
            radius: topLeading
        )
        path.closeSubpath()
        return path
    }
}

/// Stacks a bubble's parts top to bottom, leading-aligned, as wide as the widest part; with `trailingLast` the last
/// part (the time) sits on the trailing edge without widening the bubble.
struct GiovBubbleLayout: Layout {
    var spacing: CGFloat = 3
    var trailingLast = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            width = max(width, size.width)
            height += size.height + (index > 0 ? spacing : 0)
        }
        if let limit = proposal.width { width = min(width, limit) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let trailing = trailingLast && index == subviews.count - 1
            let x = trailing ? bounds.maxX - size.width : bounds.minX
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: size.width, height: size.height))
            y += size.height + spacing
        }
    }
}

/// A row that leaves a bubble at most `maxWidth`, on the sender's side, with the bot mark before AI replies.
@MainActor
struct GiovBubbleRow<Bubble: View, Below: View>: View {
    let visitor: Bool
    let showsBotMark: Bool
    let maxWidth: CGFloat
    let bubble: Bubble
    let below: Below

    init(visitor: Bool, showsBotMark: Bool, maxWidth: CGFloat, @ViewBuilder bubble: () -> Bubble, @ViewBuilder below: () -> Below) {
        self.visitor = visitor
        self.showsBotMark = showsBotMark
        self.maxWidth = maxWidth
        self.bubble = bubble()
        self.below = below()
    }

    var body: some View {
        VStack(alignment: visitor ? .trailing : .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                if showsBotMark {
                    GiovBotMark(size: 28)
                        .padding(.top, 2)
                }
                bubble
                    .frame(maxWidth: maxWidth, alignment: visitor ? .trailing : .leading)
            }
            below
        }
        .frame(maxWidth: .infinity, alignment: visitor ? .trailing : .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

extension GiovBubbleRow where Below == EmptyView {
    init(visitor: Bool, showsBotMark: Bool, maxWidth: CGFloat, @ViewBuilder bubble: () -> Bubble) {
        self.init(visitor: visitor, showsBotMark: showsBotMark, maxWidth: maxWidth, bubble: bubble, below: { EmptyView() })
    }
}

/// The workspace's greeting, shown before anything else.
@MainActor
struct GiovGreetingBubble: View {
    let text: String
    let look: GiovLook
    let maxWidth: CGFloat

    var body: some View {
        let colors = look.bubble(visitor: false)
        GiovBubbleRow(visitor: false, showsBotMark: false, maxWidth: maxWidth) {
            Text(text)
                .font(.subheadline)
                .foregroundColor(colors.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(GiovBubbleShape(tailOnLeading: true).fill(colors.fill))
        }
        .padding(.top, 16)
    }
}

/// Three dots while the other side writes; they stand still when Reduce Motion is on.
@MainActor
struct GiovTypingIndicator: View {
    let label: String
    let isBot: Bool
    let look: GiovLook
    let maxWidth: CGFloat

    var body: some View {
        let colors = look.bubble(visitor: false)
        GiovBubbleRow(visitor: false, showsBotMark: isBot, maxWidth: maxWidth) {
            dots(color: colors.faint)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(GiovBubbleShape(tailOnLeading: true).fill(colors.fill))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func dots(color: Color) -> some View {
        if look.reduceMotion {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(color.opacity(0.7)).frame(width: 7, height: 7)
                }
            }
        } else {
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { dot in
                        Circle()
                            .fill(color.opacity(Self.opacity(time: time, dot: dot)))
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
    }

    /// A 1.2 s wave, each dot a little behind the previous one.
    nonisolated static func opacity(time: Double, dot: Int) -> Double {
        let phase = (time / 1.2 - Double(dot) * 0.18).truncatingRemainder(dividingBy: 1)
        let t = phase < 0 ? phase + 1 : phase
        let wave = t < 0.5 ? t * 2 : (1 - t) * 2
        return 0.35 + 0.65 * wave
    }
}

/// One message: sender label, attachments, markdown, time, and "Not sent" with retry and discard.
@MainActor
struct GiovMessageBubble: View {
    let model: GiovBubbleModel
    let look: GiovLook
    let maxWidth: CGFloat
    let attachmentURL: (String) -> String
    let onRetry: (String) -> Void
    let onDiscard: (String) -> Void

    var body: some View {
        let colors = look.bubble(visitor: model.isVisitor)
        let layout = GiovBubbleLayout(trailingLast: model.footer != nil)
        GiovBubbleRow(visitor: model.isVisitor, showsBotMark: model.showsBotMark, maxWidth: maxWidth) {
            layout {
                Text(model.senderLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(colors.subtle)
                if !model.attachments.isEmpty {
                    GiovAttachmentList(attachments: model.attachments, colors: colors, look: look, attachmentURL: attachmentURL)
                }
                if !model.content.isEmpty {
                    GiovMarkdownView(content: model.content, colors: colors)
                }
                if let footer = model.footer {
                    Text(footer)
                        .font(.caption2)
                        .foregroundColor(colors.faint)
                        .padding(.top, 1)
                }
            }
            .padding(12)
            .background(GiovBubbleShape(tailOnLeading: !model.isVisitor).fill(colors.fill))
            .opacity(model.isSending ? 0.75 : 1)
        } below: {
            if let failure = model.failureText {
                failureRow(failure)
            }
        }
    }

    private func failureRow(_ text: String) -> some View {
        let retryLabel = "\(look.strings.notSent), \(look.strings.retry)"
        return HStack(spacing: 0) {
            if let id = model.clientMessageId {
                Button {
                    onRetry(id)
                } label: {
                    Text(text)
                        .font(.caption)
                        .foregroundColor(look.error)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(retryLabel)
                Button {
                    onDiscard(id)
                } label: {
                    Text(look.strings.discard)
                        .font(.caption)
                        .foregroundColor(look.secondaryText)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(text)
                    .font(.caption)
                    .foregroundColor(look.error)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 44)
            }
        }
    }
}
#endif
