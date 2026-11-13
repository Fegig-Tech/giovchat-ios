#if canImport(SwiftUI) && canImport(ImageIO)
import GiovChatCore
import SwiftUI

// The conversation rating card, the thumbs under GiovBot answers and the sheet ``GiovChatController/presentRating()``
// opens. All decisions live in Presentation/RatingPresentation.swift and GiovChatCore/Ratings.swift; these views only
// draw them.

/// The mouth of face 1 (very bad) to 5 (great) on a 24 x 24 grid, as in the web widget.
struct GiovFaceMouth: Shape {
    let score: Int

    func path(in rect: CGRect) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 24, y: rect.minY + rect.height * y / 24)
        }
        var path = Path()
        switch score {
        case 1:
            path.move(to: point(8, 16.4))
            path.addQuadCurve(to: point(16, 16.4), control: point(12, 12.4))
        case 2:
            path.move(to: point(8.5, 15.8))
            path.addQuadCurve(to: point(15.5, 15.8), control: point(12, 13.4))
        case 3:
            path.move(to: point(8.5, 15.4))
            path.addLine(to: point(15.5, 15.4))
        case 4:
            path.move(to: point(8.5, 14.4))
            path.addQuadCurve(to: point(15.5, 14.4), control: point(12, 16.8))
        default:
            path.move(to: point(7.8, 13.6))
            path.addQuadCurve(to: point(16.2, 13.6), control: point(12, 18.8))
            path.closeSubpath()
        }
        return path
    }
}

/// One face, drawn with lines in `color`.
struct GiovRatingFace: View {
    let score: Int
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        let line = max(1.4, size / 18)
        ZStack {
            Circle().stroke(color, lineWidth: line)
            GiovFaceMouth(score: score)
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            if score == 5 {
                GiovFaceMouth(score: score).fill(color)
            }
            HStack(spacing: size * 0.27) {
                Circle().fill(color).frame(width: size * 0.09, height: size * 0.09)
                Circle().fill(color).frame(width: size * 0.09, height: size * 0.09)
            }
            .offset(y: -size * 0.15)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private func giovNowMs() -> Int { Int((Date().timeIntervalSince1970 * 1000).rounded()) }

/// The rating card: five faces, an optional comment and Send; "Thanks" with the chosen face afterwards, which the
/// visitor may change until the window closes.
@MainActor
struct GiovRatingCard: View {
    let block: GiovRatingBlock
    let look: GiovLook
    /// Answers the card; throws the controller's ``GiovChatError``.
    let onRate: (Int, String?) async throws -> Void

    @State private var model = GiovRatingCardModel()
    @State private var now = giovNowMs()

    var body: some View {
        let strings = look.strings.rating
        let card = model.card(block: block, now: now)
        Group {
            switch card {
            case .hidden:
                EmptyView()
            case .closed:
                Text(strings.closed)
                    .font(.footnote)
                    .foregroundColor(look.secondaryText)
            case .answered(let score, let comment, let canChange):
                answered(score: score, comment: comment, canChange: canChange, strings: strings)
            case .form(let selected, _, let canCancel):
                form(selected: selected, canCancel: canCancel, strings: strings)
            }
        }
        // Read-only from `closesAt` on, without waiting for another update.
        .task(id: block.closesAt) {
            while !Task.isCancelled {
                let wait = block.closesAt - giovNowMs()
                if wait <= 0 {
                    now = giovNowMs()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(min(wait, 3_600_000)) * 1_000_000)
                now = giovNowMs()
            }
        }
    }

    private func answered(score: Int, comment: String?, canChange: Bool, strings: GiovRatingStrings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                GiovRatingFace(score: score, color: look.primary, size: 24)
                Text(strings.thanks(strings.face(score)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(look.text)
            }
            if let comment, !comment.isEmpty {
                Text(comment)
                    .font(.footnote)
                    .foregroundColor(look.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canChange {
                Button(strings.change) { model.beginEditing(from: block) }
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44, alignment: .leading)
                    .disabled(model.sending)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.yourRating)
    }

    private func form(selected: Int?, canCancel: Bool, strings: GiovRatingStrings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(giovRatingScores, id: \.self) { score in
                    let face = giovFaceAccessibility(score, selected: selected, strings: strings)
                    Button {
                        model.select(score)
                    } label: {
                        GiovRatingFace(score: score, color: face.selected ? look.primary : look.secondaryText)
                            .padding(7)
                            .frame(minWidth: 44, minHeight: 44)
                            .background(Circle().fill(face.selected ? look.primary.opacity(0.14) : Color.clear))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(face.label)
                    .accessibilityAddTraits(face.selected ? [.isSelected] : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(strings.yourRating)
            TextField(
                strings.commentPlaceholder,
                text: Binding(get: { model.comment }, set: { model.setComment($0) }),
                axis: .vertical
            )
            .lineLimit(2...4)
            .font(.subheadline)
            .foregroundColor(look.text)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(look.inputFill))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(look.inputBorder, lineWidth: 1))
            .accessibilityLabel(strings.commentPlaceholder)
            if let failure = model.failure, let text = strings.describe(failure) {
                Text(text)
                    .font(.footnote)
                    .foregroundColor(look.error)
                    .onAppear { giovAnnounce(text) }
            }
            HStack(spacing: 8) {
                Button(action: send) {
                    Text(strings.send)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(look.onButton)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(look.button))
                }
                .buttonStyle(.plain)
                .disabled(selected == nil || model.sending)
                .opacity(selected == nil || model.sending ? 0.4 : 1)
                if canCancel {
                    Button(strings.cancel) { model.cancelEditing() }
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.title)
    }

    private func send() {
        guard let choice = model.beginSend() else { return }
        let rate = onRate
        Task {
            do {
                try await rate(choice.score, choice.comment)
                model.sent()
            } catch {
                model.failed((error as? GiovChatError)?.ratingFailure ?? .retry)
            }
        }
    }
}

/// Thumbs under a GiovBot answer: one vote, changeable; a thumbs-down offers an optional reason.
@MainActor
struct GiovAnswerThumbs: View {
    let messageId: String
    let vote: GiovAnswerVote?
    let look: GiovLook
    /// Sends the vote (`nil` takes it back) with an optional reason; throws the controller's ``GiovChatError``.
    let onVote: (String, GiovAnswerVote?, String?) async throws -> Void

    @State private var model = GiovFeedbackModel()

    var body: some View {
        let strings = look.strings.rating
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                thumb(.up, label: strings.goodAnswer)
                thumb(.down, label: strings.badAnswer)
                if model.failed {
                    Text(strings.couldNotSave)
                        .font(.caption)
                        .foregroundColor(look.error)
                        .padding(.leading, 4)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(strings.rateAnswer)
            if model.asking {
                HStack(spacing: 8) {
                    TextField(
                        strings.reasonPlaceholder,
                        text: Binding(get: { model.reason }, set: { model.setReason($0) })
                    )
                    .font(.footnote)
                    .foregroundColor(look.text)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(look.inputFill))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(look.inputBorder, lineWidth: 1))
                    .submitLabel(.send)
                    .onSubmit(sendReason)
                    Button(strings.send, action: sendReason)
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                    Button(strings.skip) { model.skip() }
                        .font(.footnote)
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private func thumb(_ kind: GiovAnswerVote, label: String) -> some View {
        let active = vote == kind
        let name = kind == .up ? "hand.thumbsup" : "hand.thumbsdown"
        return Button {
            tap(kind)
        } label: {
            Image(systemName: active ? name + ".fill" : name)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(active ? look.primary : look.secondaryText)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func tap(_ kind: GiovAnswerVote) {
        let next = model.tap(kind, current: vote)
        let id = messageId
        let send = onVote
        Task {
            do { try await send(id, next, nil) } catch { model.fail() }
        }
    }

    private func sendReason() {
        guard let reason = model.submitReason() else { return }
        let id = messageId
        let send = onVote
        Task {
            do { try await send(id, .down, reason) } catch { model.fail() }
        }
    }
}

/// The sheet ``GiovChatController/presentRating()`` opens: the open request's card on its own.
@MainActor
struct GiovRatingSheet: View {
    let block: GiovRatingBlock
    let look: GiovLook
    let onRate: (Int, String?) async throws -> Void
    let onClose: () -> Void

    var body: some View {
        let strings = look.strings.rating
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(strings.title)
                    .font(.headline)
                    .foregroundColor(look.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(look.strings.closeChat, action: onClose)
                    .font(.subheadline)
                    .frame(minHeight: 44)
            }
            GiovRatingCard(block: block, look: look, onRate: onRate)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(look.background.ignoresSafeArea())
        .environment(\.colorScheme, look.dark ? .dark : .light)
        .tint(look.primary)
    }
}
#endif
