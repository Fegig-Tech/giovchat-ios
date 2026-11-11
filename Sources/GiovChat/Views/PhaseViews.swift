#if canImport(SwiftUI) && canImport(ImageIO)
import GiovChatCore
import SwiftUI

/// Placeholder bubbles while the configuration loads.
@MainActor
struct GiovSkeletonView: View {
    let look: GiovLook

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            bar(width: 220, height: 44, trailing: false)
            bar(width: 150, height: 36, trailing: true)
            bar(width: 250, height: 60, trailing: false)
            Spacer(minLength: 0)
            Text(look.strings.loading)
                .font(.subheadline)
                .foregroundColor(look.hint)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
        .padding(16)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.strings.loading)
    }

    private func bar(width: CGFloat, height: CGFloat, trailing: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(look.skeleton)
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

/// A failure that needs a fresh start, with "Try again".
@MainActor
struct GiovErrorView: View {
    let message: String
    let look: GiovLook
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(message)
                .font(.subheadline)
                .foregroundColor(look.error)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onRetry) {
                Text(look.strings.tryAgain)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(look.onButton)
                    .padding(.horizontal, 28)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(look.button))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { giovAnnounce(message) }
    }
}

/// "Powered by GiovChat". Deliberately isolated from the style overrides, as in the other SDKs.
@MainActor
struct GiovBrandingView: View {
    @Environment(\.openURL) private var openURL

    init() {}

    var body: some View {
        Button {
            openURL(giovBrandingURL)
        } label: {
            (Text(verbatim: "Powered by ") + Text(verbatim: "GiovChat").bold().foregroundColor(Color(GiovRGB(rgb: 0x7C3AED))))
                .font(.caption)
                .foregroundColor(Color(GiovRGB(rgb: 0x52525B)))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "Powered by GiovChat"))
        .background(Color.white.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color(GiovRGB(rgb: 0xEBEBEB))).frame(height: 0.5) }
    }
}

/// The pre-chat form: only the contact fields the workspace requires and the host has not supplied. The button
/// stays disabled until every required field is valid.
@MainActor
struct GiovPreChatForm: View {
    private enum Field: Hashable {
        case firstName, lastName, email, phone
    }

    let fields: GiovRequestUserInfo
    let look: GiovLook
    let onSubmit: (GiovContact) -> Void

    @State private var values: GiovPreChatValues
    @FocusState private var focused: Field?

    init(fields: GiovRequestUserInfo, initial: GiovContact?, look: GiovLook, onSubmit: @escaping (GiovContact) -> Void) {
        self.fields = fields
        self.look = look
        self.onSubmit = onSubmit
        _values = State(initialValue: GiovPreChatValues(contact: initial))
    }

    private var order: [Field] {
        var list: [Field] = []
        if fields.firstName { list.append(.firstName) }
        if fields.lastName { list.append(.lastName) }
        if fields.email { list.append(.email) }
        if fields.phone { list.append(.phone) }
        return list
    }

    private var valid: Bool { values.isValid(for: fields) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(look.strings.preChatTitle)
                    .font(.title3.weight(.bold))
                    .foregroundColor(look.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 8)
                ForEach(order, id: \.self) { field in
                    fieldView(field)
                }
                Button(action: submit) {
                    Text(look.strings.startChat)
                        .font(.body.weight(.bold))
                        .foregroundColor(look.onButton)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 10).fill(look.button))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!valid)
                .opacity(valid ? 1 : 0.45)
                .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private func label(_ field: Field) -> String {
        switch field {
        case .firstName: return look.strings.firstName
        case .lastName: return look.strings.lastName
        case .email: return look.strings.email
        case .phone: return look.strings.phone
        }
    }

    private func binding(_ field: Field) -> Binding<String> {
        switch field {
        case .firstName: return $values.firstName
        case .lastName: return $values.lastName
        case .email: return $values.email
        case .phone: return $values.phone
        }
    }

    private func hint(_ field: Field) -> String {
        switch field {
        case .email: return "you@example.com"
        case .phone: return "+1 555 000 0000"
        default: return label(field)
        }
    }

    private func keyboard(_ field: Field) -> GiovKeyboardKind {
        switch field {
        case .firstName: return .givenName
        case .lastName: return .familyName
        case .email: return .email
        case .phone: return .phone
        }
    }

    private func fieldView(_ field: Field) -> some View {
        let name = label(field)
        let isLast = order.last == field
        return VStack(alignment: .leading, spacing: 6) {
            Text(look.strings.required(name))
                .font(.footnote.weight(.semibold))
                .foregroundColor(look.secondaryText)
                .accessibilityHidden(true)
            TextField(name, text: binding(field), prompt: Text(hint(field)))
                .giovKeyboard(for: keyboard(field))
                .autocorrectionDisabled(true)
                .submitLabel(isLast ? .done : .next)
                .focused($focused, equals: field)
                .onSubmit { advance(from: field) }
                .font(.subheadline)
                .foregroundColor(look.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 10).fill(look.inputFill))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(look.inputBorder, lineWidth: 1))
                .accessibilityLabel(look.strings.required(name))
        }
    }

    private func advance(from field: Field) {
        if let index = order.firstIndex(of: field), index + 1 < order.count {
            focused = order[index + 1]
        } else {
            submit()
        }
    }

    private func submit() {
        guard valid else { return }
        focused = nil
        onSubmit(values.contact)
    }
}

enum GiovKeyboardKind {
    case givenName, familyName, email, phone
}

extension View {
    /// The right keyboard, content type and capitalization for a contact field (iOS).
    @ViewBuilder
    func giovKeyboard(for kind: GiovKeyboardKind) -> some View {
        #if os(iOS)
        switch kind {
        case .givenName:
            self.textContentType(.givenName).textInputAutocapitalization(.words)
        case .familyName:
            self.textContentType(.familyName).textInputAutocapitalization(.words)
        case .email:
            self.textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
        case .phone:
            self.textContentType(.telephoneNumber).keyboardType(.phonePad)
        }
        #else
        self
        #endif
    }
}
#endif
