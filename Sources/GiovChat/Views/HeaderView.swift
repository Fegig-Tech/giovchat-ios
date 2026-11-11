#if canImport(SwiftUI) && canImport(ImageIO)
import GiovChatCore
import SwiftUI

/// The header: avatar (photo, GiovBot mark or initial), who is answering, a status line, the menu (privacy policy,
/// as in the web widget) and the close button.
@MainActor
struct GiovHeaderView: View {
    let model: GiovHeaderModel
    let look: GiovLook
    let privacyURL: URL
    let onClose: (() -> Void)?
    @Environment(\.openURL) private var openURL

    init(model: GiovHeaderModel, look: GiovLook, privacyURL: URL, onClose: (() -> Void)?) {
        self.model = model
        self.look = look
        self.privacyURL = privacyURL
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = model.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .opacity(0.78)
                }
            }
            .foregroundColor(look.onHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button {
                    openURL(privacyURL)
                } label: {
                    Label(look.strings.privacyPolicy, systemImage: "lock.shield")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(look.onHeader)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel(look.strings.moreOptions)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(look.onHeader)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(look.strings.closeChat)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .background(look.header.ignoresSafeArea(edges: .top))
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(look.onHeader.opacity(0.22))
            if let url = model.avatarURL {
                GiovRemoteImage(url: url, cacheKey: url, maxPixels: 120) {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fallback: some View {
        if model.kind == .bot {
            GiovBotMark(size: 26)
        } else {
            Text(model.initial)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(look.onHeader)
        }
    }
}
#endif
