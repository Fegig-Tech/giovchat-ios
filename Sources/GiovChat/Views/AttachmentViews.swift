#if canImport(SwiftUI) && canImport(ImageIO)
import GiovChatCore
import SwiftUI

/// A picture from the network: nothing while it loads, `failure` when it cannot be loaded.
@MainActor
struct GiovRemoteImage<Failure: View>: View {
    let url: String
    let cacheKey: String
    let maxPixels: Int
    let failure: () -> Failure

    @State private var image: GiovDecodedImage? = nil
    @State private var failed = false

    init(url: String, cacheKey: String, maxPixels: Int, @ViewBuilder failure: @escaping () -> Failure) {
        self.url = url
        self.cacheKey = cacheKey
        self.maxPixels = maxPixels
        self.failure = failure
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                failure()
            }
        }
        .task(id: cacheKey) {
            let loaded = await GiovImageLoader.shared.load(url: url, cacheKey: cacheKey, maxPixels: maxPixels)
            image = loaded
            failed = loaded == nil
        }
    }
}

/// The compact GiovBot avatar shown beside AI replies and in the header while the bot answers.
@MainActor
struct GiovBotMark: View {
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let mark = GiovDecodedImage.botMark {
                Image(decorative: mark.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Attachments inside a bubble: images in a box of their final shape, other files as rows.
@MainActor
struct GiovAttachmentList: View {
    let attachments: [GiovAttachment]
    let colors: GiovBubbleColors
    let look: GiovLook
    let attachmentURL: (String) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                let url = attachmentURL(attachment.url)
                let name = giovAttachmentName(attachment, strings: look.strings)
                if attachment.isImage {
                    GiovAttachmentImage(attachment: attachment, url: url, name: name, colors: colors, look: look)
                } else {
                    GiovFileRow(url: url, name: name, colors: colors, look: look)
                }
            }
        }
        .padding(.bottom, 4)
    }
}

@MainActor
private func openAttachment(_ url: String, with openURL: OpenURLAction) {
    guard giovIsHTTPURL(url), let target = URL(string: url) else { return }
    openURL(target)
}

@MainActor
struct GiovFileRow: View {
    let url: String
    let name: String
    let colors: GiovBubbleColors
    let look: GiovLook
    @Environment(\.openURL) private var openURL

    init(url: String, name: String, colors: GiovBubbleColors, look: GiovLook) {
        self.url = url
        self.name = name
        self.colors = colors
        self.look = look
    }

    var body: some View {
        Button {
            openAttachment(url, with: openURL)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.body)
                Text(name)
                    .font(.footnote)
                    .underline()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundColor(colors.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .frame(maxWidth: 240, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.accent, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(look.strings.openAttachment(name))
    }
}

@MainActor
struct GiovAttachmentImage: View {
    let attachment: GiovAttachment
    let url: String
    let name: String
    let colors: GiovBubbleColors
    let look: GiovLook
    @Environment(\.openURL) private var openURL
    @State private var image: GiovDecodedImage? = nil
    @State private var failed = false

    init(attachment: GiovAttachment, url: String, name: String, colors: GiovBubbleColors, look: GiovLook) {
        self.attachment = attachment
        self.url = url
        self.name = name
        self.colors = colors
        self.look = look
    }

    var body: some View {
        let box = giovPreviewBoxSize(attachment.preview)
        Button {
            openAttachment(url, with: openURL)
        } label: {
            ZStack {
                colors.imageFill
                // Decoded only until the picture arrives (it would also show through a transparent one).
                if image == nil, let thumb = GiovDecodedImage.placeholder(attachment.preview) {
                    Image(decorative: thumb.cgImage, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 6)
                }
                if let image {
                    Image(decorative: image.cgImage, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if failed {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundColor(look.hint)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(look.strings.openAttachment(name))
        // Keyed by the URL with its credential: a load that failed without a usable token is tried again once the
        // token arrives or is renewed. The loader caches by the stable attachment URL, so a new token costs nothing.
        .task(id: url) {
            let loaded = await GiovImageLoader.shared.load(url: url, cacheKey: attachment.url, maxPixels: 600)
            guard !Task.isCancelled else { return }
            if let loaded {
                if image == nil {
                    withAnimation(look.reduceMotion ? nil : .easeIn(duration: 0.15)) { image = loaded }
                }
                failed = false
            } else if image == nil {
                failed = true
            }
        }
    }
}

/// Files picked and waiting to be sent, with upload progress while they go, and the reason a pick was refused.
@MainActor
struct GiovPendingFiles: View {
    let files: [GiovPickedFile]
    let uploads: [GiovUploadProgress]
    let sending: Bool
    let problem: String?
    let look: GiovLook
    let onRemove: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundColor(look.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                            chip(index: index, file: file)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(look.background)
        .overlay(alignment: .top) { Rectangle().fill(look.divider).frame(height: 0.5) }
    }

    private func chip(index: Int, file: GiovPickedFile) -> some View {
        HStack(spacing: 0) {
            Text(giovChipText(index: index, name: file.name, uploads: uploads, strings: look.strings))
                .font(.caption)
                .foregroundColor(look.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 14)
                .padding(.trailing, sending ? 14 : 0)
            if !sending {
                Button {
                    onRemove(index)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(look.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(look.strings.removeAttachment(file.name))
            }
        }
        .frame(minHeight: 44)
        .frame(maxWidth: 240)
        .background(Capsule().fill(look.inputFill))
    }
}
#endif
